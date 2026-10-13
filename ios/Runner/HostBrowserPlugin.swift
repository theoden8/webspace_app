// One source, both Apple Runners: the macOS project compiles this file from
// here, as it does ShareIntentPlugin.swift.
#if canImport(FlutterMacOS)
  import FlutterMacOS
#else
  import Flutter
#endif

import Foundation

/// The `host_browser` channel: what Dart needs to send the user agent of the
/// Mac's Safari, which a WKWebView's own does not name (UAID-005).
enum HostBrowserPlugin {
  static func attach(to messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "org.codeberg.theoden8.webspace/host_browser",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "describe":
        var reply: [String: Any] = [
          "iosAppOnMac": ProcessInfo.processInfo.isiOSAppOnMac
        ]
        if let version = safariVersion() {
          reply["safariVersion"] = version
        }
        result(reply)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// The installed Safari's version. A Mac has one at this path; an iPhone
  /// or iPad does not, and a sandbox that hides it reads as nil too.
  private static func safariVersion() -> String? {
    Bundle(path: "/Applications/Safari.app")?
      .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
  }
}
