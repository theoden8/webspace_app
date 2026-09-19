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
class ProxyProbePlugin: NSObject {
  static let channelName = "webspace/proxy_probe"

  private let channel: FlutterMethodChannel

  /// Held for the life of the probe: a `WKWebView` that goes out of scope
  /// mid-load reports nothing at all, which reads exactly like a proxy that
  /// was never used.
  private var webView: WKWebView?
  private var delegate: ProbeNavigationDelegate?

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
    // The app's WebViews live in the window; this one never did. That is one
    // of the few structural differences left between the shape that proxies
    // and the shape that does not, so it is a knob rather than an assumption.
    let attach = (args["attach"] as? Bool) ?? false

    guard #available(macOS 14.0, *) else {
      result(["ok": false, "detail": "below the proxyConfigurations floor"])
      return
    }
    guard let endpoint = socksEndpoint(host: socksHost, port: socksPort) else {
      result(["ok": false, "detail": "bad socks endpoint"])
      return
    }

    let store: WKWebsiteDataStore
    if identified, let identifier = identifier {
      store = WKWebsiteDataStore(forIdentifier: identifier)
    } else {
      store = WKWebsiteDataStore.nonPersistent()
    }
    store.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: endpoint)]

    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = store
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 200),
                         configuration: configuration)
    if attach, let contentView = NSApplication.shared.keyWindow?.contentView {
      contentView.addSubview(view)
    }
    let navDelegate = ProbeNavigationDelegate { [weak self] detail in
      if attach {
        self?.webView?.removeFromSuperview()
      }
      self?.webView = nil
      self?.delegate = nil
      result([
        "ok": true,
        "identified": identified,
        "attached": attach,
        "configured": store.proxyConfigurations.count,
        "detail": detail,
      ])
    }
    view.navigationDelegate = navDelegate
    webView = view
    delegate = navDelegate
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

  init(onSettled: @escaping (String) -> Void) {
    report = onSettled
    super.init()
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
