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

    guard #available(macOS 14.0, *) else {
      result(["ok": false, "detail": "below the proxyConfigurations floor"])
      return
    }
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
    navDelegate = ProbeNavigationDelegate(
      credential: (username != nil && password != nil)
        ? URLCredential(user: username!, password: password!, persistence: .forSession)
        : nil
    ) { detail in
      // Deliberately keeps the WebView, delegate and store alive: an earlier
      // arm staying alive while a later one loads is the whole point.
      if attach {
        view.removeFromSuperview()
      }
      result([
        "ok": true,
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
