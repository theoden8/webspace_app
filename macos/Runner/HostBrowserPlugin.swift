import FlutterMacOS
import Foundation

/// The `host_browser` channel: the installed Safari's version, so Dart can
/// send Safari's user agent, which a WKWebView's own does not name (UAID-005).
enum HostBrowserPlugin {
  static func attach(to messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "org.codeberg.theoden8.webspace/host_browser",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "safariVersion":
        result(safariVersion())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Nil when a sandbox hides Safari's bundle.
  private static func safariVersion() -> String? {
    Bundle(path: "/Applications/Safari.app")?
      .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
  }
}
