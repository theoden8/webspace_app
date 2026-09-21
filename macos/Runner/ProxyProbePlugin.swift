import Cocoa
import FlutterMacOS
import Network
import WebKit

/// Asks WebKit the per-store proxy question with nothing else in the way
/// (BUG-014).
///
/// Everything up to attempt 54 measured the same thing: Dart sends a
/// per-site proxy, the plugin assigns it once and never clears it, the
/// store still reports it when the load starts, and the traffic goes
/// direct anyway. A fixture that carries the app's machinery cannot say
/// whether WebKit or that machinery is at fault. This carries none of it:
/// one data store, one proxy, one `WKWebView`, one load, no containers
/// plumbing, no settings parser, no Flutter webview widget.
///
/// `identified` picks which store shape to ask about, so one run separates
/// two claims that have been stuck together all along:
///   false — `WKWebsiteDataStore.nonPersistent()`, which is what WebKit's
///           own `TEST(WebKit, SOCKS5API)` proxies successfully.
///   true  — `WKWebsiteDataStore(forIdentifier:)`, which is what the app
///           uses for per-site containers and what no upstream test covers.
/// A split between them is the answer; agreement moves the question to
/// `_WKWebsiteDataStoreConfiguration`'s CFNetwork path, which is the
/// follow-up and needs SPI.
///
/// `proxy` exists because attempt 58 showed only the first WebView in a
/// process is proxied, and could not say what "first" keys on: the first
/// WebView, the first load, or the first store handed a proxy. An arm that
/// builds and loads a WebView with no proxy at all separates them in one
/// run -- if a later proxied arm still binds, an unproxied first load is
/// harmless and the slot belongs to the first *assignment*.
class ProxyProbePlugin: NSObject {
  static let channelName = "webspace/proxy_probe"

  private let channel: FlutterMethodChannel

  /// Held for the life of the PLUGIN, not of one probe.
  ///
  /// These were single properties, and each arm overwrote the previous one.
  /// The delegate's closure is the only strong reference to that arm's
  /// `WKWebsiteDataStore`, so starting arm 2 deallocated arm 1's WebView and
  /// its store. Every "a second store is not proxied" reading taken through
  /// this probe was therefore taken with the first store already gone, which
  /// is sequential use rather than the coexistence the app actually has.
  ///
  /// Arrays now, with stores retained explicitly, so every store a run
  /// creates is still alive while later arms load.
  private var webViews: [WKWebView] = []
  private var delegates: [ProbeNavigationDelegate] = []
  private var stores: [WKWebsiteDataStore] = []

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: ProxyProbePlugin.channelName,
                                   binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "urlSessionSequential" {
      handleURLSessionSequential(call, result: result)
      return
    }
    if call.method == "urlSessionPerSession" {
      handleURLSessionPerSession(call, result: result)
      return
    }
    guard call.method == "probe" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let args = call.arguments as? [String: Any],
          let socksHost = args["socksHost"] as? String,
          let socksPort = args["socksPort"] as? Int,
          let urlString = args["url"] as? String,
          let url = URL(string: urlString) else {
      result(["ok": false, "detail": "bad arguments"])
      return
    }
    let identified = (args["identified"] as? Bool) ?? false
    let identifier = (args["identifier"] as? String).flatMap { UUID(uuidString: $0) }
    let wantsProxy = (args["proxy"] as? Bool) ?? true
    // `connect` asks WebKit for an HTTP CONNECT proxy with a credential,
    // which is what the LocalProxyRelay route needs and what WebKit bug
    // 264309 reports broken. The question this arm settles is narrower than
    // that bug: not whether Proxy-Authorization is sent, but whether the 407
    // reaches the navigation delegate as an auth challenge at all.
    let kind = (args["kind"] as? String) ?? "socks5"
    let username = args["username"] as? String
    let password = args["password"] as? String
    // The app's WebViews live in the window; this one never did. That is one
    // of the few structural differences left between the shape that proxies
    // and the shape that does not, so it is a knob rather than an assumption.
    let attach = (args["attach"] as? Bool) ?? false
    // A second navigation on the SAME store and WebView, and whether to
    // re-assign `proxyConfigurations` before issuing it.
    //
    // `WebsiteDataStore::setProxyConfigData` sets `m_proxyConfigData` to
    // nullopt, calls the network process, and only restores the value
    // afterwards, while `parameters()` builds a session's configuration from
    // that same member. Anything that reads it inside that window sees no
    // proxy. If that is what closes the window, assigning again once the
    // process is certainly up should reopen it, and the second navigation
    // proxies. If it stays direct, the clear-then-restore window is not the
    // mechanism (BUG-014).
    let secondUrl = (args["secondUrl"] as? String).flatMap { URL(string: $0) }
    let reassign = (args["reassign"] as? Bool) ?? false

    guard #available(macOS 14.0, *) else {
      result(["ok": false, "detail": "below the proxyConfigurations floor"])
      return
    }
    var appliedConfigs: [ProxyConfiguration] = []
    var endpoint: NWEndpoint?
    if wantsProxy {
      guard let resolved = socksEndpoint(host: socksHost, port: socksPort) else {
        result(["ok": false, "detail": "bad socks endpoint"])
        return
      }
      endpoint = resolved
    }

    let store: WKWebsiteDataStore
    if identified, let identifier = identifier {
      store = WKWebsiteDataStore(forIdentifier: identifier)
    } else {
      store = WKWebsiteDataStore.nonPersistent()
    }
    if let endpoint = endpoint {
      // `var` deliberately: applyCredential mutates, and ProxyConfiguration
      // being a value type would make it unavailable on a `let`.
      var config = ProxyConfiguration(socksv5Proxy: endpoint)
      if kind == "connect" {
        config = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)
        if let username = username, let password = password {
          config.applyCredential(username: username, password: password)
        }
      }
      store.proxyConfigurations = [config]
      appliedConfigs = [config]
    }

    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = store
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 200),
                         configuration: configuration)
    if attach, let contentView = NSApplication.shared.keyWindow?.contentView {
      contentView.addSubview(view)
    }
    // Read before the closure runs, so the reply reports how many stores were
    // alive when THIS arm loaded, not at reply time.
    let liveStores = stores.count + 1
    var navDelegate: ProbeNavigationDelegate?
    // Phase 0 is the mount-turn navigation. Phase 1 exists only when the
    // caller asked for a second one; the delegate fires per navigation, so
    // the closure has to say which it is looking at.
    var phase = 0
    var firstDetail = ""
    navDelegate = ProbeNavigationDelegate(
      credential: (username != nil && password != nil)
        ? URLCredential(user: username!, password: password!, persistence: .forSession)
        : nil
    ) { detail in
      if phase == 0, let secondUrl = secondUrl {
        phase = 1
        firstDetail = detail
        if reassign && !appliedConfigs.isEmpty {
          store.proxyConfigurations = appliedConfigs
        }
        view.load(URLRequest(url: secondUrl))
        return
      }
      // Deliberately keeps the WebView, delegate and store alive: an earlier
      // arm staying alive while a later one loads is the whole point.
      if attach {
        view.removeFromSuperview()
      }
      result([
        "ok": true,
        "reassigned": reassign && phase == 1,
        "secondDetail": phase == 1 ? detail : "",
        "detail1": phase == 1 ? firstDetail : detail,
        "identified": identified,
        "attached": attach,
        "proxy": wantsProxy,
        "kind": kind,
        "configured": store.proxyConfigurations.count,
        "liveStores": liveStores,
        "detail": detail,
        "challenges": navDelegate?.challenges ?? 0,
        "proxyChallenges": navDelegate?.proxyChallenges ?? 0,
        "challengeMethods": navDelegate?.challengeMethods.joined(separator: ",") ?? "",
      ])
    }
    view.navigationDelegate = navDelegate
    webViews.append(view)
    if let navDelegate = navDelegate { delegates.append(navDelegate) }
    stores.append(store)
    view.load(URLRequest(url: url))
  }

  /// The same `ProxyConfiguration` value, handed to `URLSession` instead of
  /// `WKWebsiteDataStore`, loading N URLs in sequence on one session.
  ///
  /// This is the arm that separates WebKit from the layer underneath it.
  /// `proxyConfigurations` is the same Network.framework type on
  /// `URLSessionConfiguration` as on `WKWebsiteDataStore`, but a `URLSession`
  /// runs in THIS process, so every step can be traced instead of inferred
  /// from whether a fixture saw a CONNECT. If both loads reach the fixture
  /// here while a `WKWebView` only ever sends the first, the defect is
  /// WebKit's. If the second is direct here too, it belongs to
  /// `ProxyConfiguration` and WebKit is blameless.
  private func handleURLSessionSequential(_ call: FlutterMethodCall,
                                          result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let socksHost = args["socksHost"] as? String,
          let socksPort = args["socksPort"] as? Int,
          let urlStrings = args["urls"] as? [String] else {
      result(["ok": false, "detail": "bad arguments"])
      return
    }
    let urls = urlStrings.compactMap { URL(string: $0) }
    guard urls.count == urlStrings.count, !urls.isEmpty else {
      result(["ok": false, "detail": "bad urls"])
      return
    }
    guard #available(macOS 14.0, *) else {
      result(["ok": false, "detail": "below the proxyConfigurations floor"])
      return
    }
    guard let endpoint = socksEndpoint(host: socksHost, port: socksPort) else {
      result(["ok": false, "detail": "bad socks endpoint"])
      return
    }

    let proxy = ProxyConfiguration(socksv5Proxy: endpoint)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.proxyConfigurations = [proxy]
    // Off, or a repeated GET to one URL can be answered without a connection
    // and read as a proxy that was skipped.
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.urlCache = nil
    let session = URLSession(configuration: configuration)
    NSLog("[proxy-probe] urlsession configured proxies=\(configuration.proxyConfigurations.count) urls=\(urls.count)")

    runSequential(session: session, urls: urls, index: 0, outcomes: []) { outcomes in
      NSLog("[proxy-probe] urlsession done outcomes=\(outcomes.joined(separator: " "))")
      // Read back after the loads, so a configuration that was emptied
      // somewhere along the way is visible rather than assumed intact.
      result([
        "ok": true,
        "configuredBefore": 1,
        "configuredAfter": configuration.proxyConfigurations.count,
        "outcomes": outcomes,
      ])
      session.invalidateAndCancel()
    }
  }

  /// One load each on three `URLSession`s: the first two share a single
  /// `ProxyConfiguration` instance, the third mints its own for the same
  /// endpoint.
  ///
  /// `NetworkSessionCocoa::applyProxyConfigurationToSessionConfiguration`
  /// puts the SAME `nw_proxy_config_t` instances from `m_nwProxyConfigs` into
  /// every session configuration it touches, so "the object is consumed by
  /// its first user" is a shape the source permits. Sessions 1 and 2 test
  /// exactly that; session 3 is the control that separates a consumed object
  /// from something process-wide, and all three run where the code can be
  /// traced.
  ///
  /// | reading | meaning |
  /// |---|---|
  /// | 1 proxied, 2 direct, 3 proxied | the config object is single-use |
  /// | 1 proxied, 2 and 3 direct | one proxied session per process |
  /// | all three proxied | the layer under WebKit is sound for this too |
  private func handleURLSessionPerSession(_ call: FlutterMethodCall,
                                          result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let socksHost = args["socksHost"] as? String,
          let socksPort = args["socksPort"] as? Int,
          let urlString = args["url"] as? String,
          let url = URL(string: urlString) else {
      result(["ok": false, "detail": "bad arguments"])
      return
    }
    guard #available(macOS 14.0, *) else {
      result(["ok": false, "detail": "below the proxyConfigurations floor"])
      return
    }
    guard let endpoint = socksEndpoint(host: socksHost, port: socksPort) else {
      result(["ok": false, "detail": "bad socks endpoint"])
      return
    }

    let shared = ProxyConfiguration(socksv5Proxy: endpoint)
    let arms: [(String, ProxyConfiguration)] = [
      ("s1-shared-object", shared),
      ("s2-shared-object", shared),
      ("s3-fresh-object", ProxyConfiguration(socksv5Proxy: endpoint)),
    ]
    var sessions: [URLSession] = []
    for (label, proxy) in arms {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.proxyConfigurations = [proxy]
      configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
      configuration.urlCache = nil
      sessions.append(URLSession(configuration: configuration))
      NSLog("[proxy-probe] persession \(label) proxies=\(configuration.proxyConfigurations.count)")
    }

    runOnEach(sessions: sessions,
              labels: arms.map { $0.0 },
              url: url,
              index: 0,
              outcomes: []) { outcomes in
      NSLog("[proxy-probe] persession done outcomes=\(outcomes.joined(separator: " "))")
      result([
        "ok": true,
        "labels": arms.map { $0.0 },
        "outcomes": outcomes,
      ])
      for session in sessions {
        session.invalidateAndCancel()
      }
    }
  }

  private func runOnEach(sessions: [URLSession],
                         labels: [String],
                         url: URL,
                         index: Int,
                         outcomes: [String],
                         done: @escaping ([String]) -> Void) {
    if index >= sessions.count {
      done(outcomes)
      return
    }
    let started = Date()
    NSLog("[proxy-probe] persession load \(labels[index]) -> \(url.absoluteString)")
    let task = sessions[index].dataTask(with: url) { [weak self] _, response, error in
      var outcome = "none"
      if let http = response as? HTTPURLResponse {
        outcome = "http\(http.statusCode)"
      } else if let error = error {
        outcome = "error\((error as NSError).code)"
      }
      let ms = Int(Date().timeIntervalSince(started) * 1000)
      NSLog("[proxy-probe] persession load \(labels[index]) settled \(outcome) in \(ms)ms")
      let next = outcomes + ["\(labels[index]):\(outcome)"]
      guard let self = self else {
        done(next)
        return
      }
      self.runOnEach(sessions: sessions,
                     labels: labels,
                     url: url,
                     index: index + 1,
                     outcomes: next,
                     done: done)
    }
    task.resume()
  }

  private func runSequential(session: URLSession,
                             urls: [URL],
                             index: Int,
                             outcomes: [String],
                             done: @escaping ([String]) -> Void) {
    if index >= urls.count {
      done(outcomes)
      return
    }
    let started = Date()
    NSLog("[proxy-probe] urlsession load \(index) -> \(urls[index].absoluteString)")
    let task = session.dataTask(with: urls[index]) { [weak self] _, response, error in
      var outcome = "none"
      if let http = response as? HTTPURLResponse {
        outcome = "http\(http.statusCode)"
      } else if let error = error {
        outcome = "error\((error as NSError).code)"
      }
      let ms = Int(Date().timeIntervalSince(started) * 1000)
      NSLog("[proxy-probe] urlsession load \(index) settled \(outcome) in \(ms)ms")
      guard let self = self else {
        done(outcomes + ["\(index):\(outcome)"])
        return
      }
      self.runSequential(session: session,
                         urls: urls,
                         index: index + 1,
                         outcomes: outcomes + ["\(index):\(outcome)"],
                         done: done)
    }
    task.resume()
  }

  private func socksEndpoint(host: String, port: Int) -> NWEndpoint? {
    guard port > 0, port <= Int(UInt16.max),
          let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
    var nwHost = NWEndpoint.Host(host)
    if let ipv4 = IPv4Address(host) {
      nwHost = .ipv4(ipv4)
    }
    return NWEndpoint.hostPort(host: nwHost, port: nwPort)
  }
}

/// Reports the first terminal outcome once. Answering a `FlutterResult`
/// twice kills the engine, and a probe sees both a failure and a finish
/// often enough to matter.
class ProbeNavigationDelegate: NSObject, WKNavigationDelegate {
  private var report: ((String) -> Void)?
  private let credential: URLCredential?

  /// Every auth challenge this load saw, and how many named a proxy
  /// protection space. A proxy 407 that never reaches here is the finding
  /// (BUG-014 route 2), so absence has to be recorded as carefully as
  /// presence.
  private(set) var challenges = 0
  private(set) var proxyChallenges = 0
  private(set) var challengeMethods: [String] = []

  init(credential: URLCredential? = nil,
       onSettled: @escaping (String) -> Void) {
    self.credential = credential
    report = onSettled
    super.init()
  }

  func webView(_ webView: WKWebView,
               didReceive challenge: URLAuthenticationChallenge,
               completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    challenges += 1
    let space = challenge.protectionSpace
    challengeMethods.append(space.authenticationMethod)
    if space.isProxy() { proxyChallenges += 1 }
    if space.isProxy(), let credential = credential {
      completionHandler(.useCredential, credential)
      return
    }
    completionHandler(.performDefaultHandling, nil)
  }

  private func settle(_ detail: String) {
    guard let report = report else { return }
    self.report = nil
    report(detail)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    settle("didFinish")
  }

  func webView(_ webView: WKWebView,
               didFail navigation: WKNavigation!,
               withError error: Error) {
    settle("didFail: \(error.localizedDescription)")
  }

  func webView(_ webView: WKWebView,
               didFailProvisionalNavigation navigation: WKNavigation!,
               withError error: Error) {
    settle("didFailProvisional: \(error.localizedDescription)")
  }
}
