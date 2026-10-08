// One source, both Apple Runners: the macOS project compiles this file from
// here, as it does TorControllerPlugin.swift.
#if canImport(FlutterMacOS)
  import FlutterMacOS
#else
  import Flutter
#endif

import Foundation

/// The `share_intent` channel: the `webspace://` URL the OS opened the app
/// with, or what the share extension left in the App Group, held until Dart
/// asks for it (LIR-004, LIR-007, LIR-012).
///
/// The app delegate owns it from launch and attaches the channel once there
/// is an engine, because macOS delivers `application(_:open:)` for a launch
/// URL before `applicationDidFinishLaunching`.
final class ShareIntentPlugin: NSObject {
  private var pendingUrl: String?

  func attach(to messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "org.codeberg.theoden8.webspace/share_intent",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      switch call.method {
      case "consumeLaunchUrl":
        self.drainPendingUrl()
        let url = self.pendingUrl
        self.pendingUrl = nil
        trace("consumeLaunchUrl returning: \(url ?? "nil")")
        result(url)
      case "consumeLaunchHtml":
        // The share extension writes an HTML document into the group
        // container and wakes the app with `webspace://openhtml`; one read,
        // then delete. Only the iOS extension writes one.
        let payload = self.drainPendingHtml()
        trace("consumeLaunchHtml returning: \(payload == nil ? "nil" : "payload")")
        result(payload)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Takes the URLs the OS opened the app with, then whatever the share
  /// extension left in the App Group, which wins when both are present.
  func receive(_ urls: [URL]) {
    for url in urls {
      capture(url)
    }
    drainPendingUrl()
  }

  private func capture(_ url: URL) {
    guard url.scheme?.lowercased() == "webspace" else {
      trace("ignoring non-webspace scheme: \(url.scheme ?? "nil")")
      return
    }
    switch url.host?.lowercased() {
    case "open", "qr":
      // LIR-004: the whole URL goes to Dart, whose
      // `LinkRoutingService.parseWebspaceUri` validates and unwraps the inner
      // http(s) target; a qr URL is routed by its scheme.
      pendingUrl = url.absoluteString
      trace("captured \(url.absoluteString)")
    case "share":
      // The legacy form, still what the share extensions open.
      guard
        let inner = URLComponents(url: url, resolvingAgainstBaseURL: false)?
          .queryItems?.first(where: { $0.name == "url" })?.value,
        let httpScheme = URL(string: inner)?.scheme?.lowercased(),
        httpScheme == "http" || httpScheme == "https"
      else {
        trace("share URL has no valid http(s) inner: \(url.absoluteString)")
        return
      }
      pendingUrl = inner
      trace("captured share inner URL: \(inner)")
    case "openhtml":
      // Only foregrounds the app: the document rides the group container,
      // and Dart's share poll drains it through consumeLaunchHtml.
      trace("received openhtml trigger")
    case let host:
      trace("unrecognized webspace host: \(host ?? "nil")")
    }
  }

  private func drainPendingUrl() {
    guard let defaults = AppGroup.defaults else {
      NSLog("[WebSpace] app group \(AppGroup.id) unavailable; cannot drain pending URL")
      return
    }
    if let stored = defaults.string(forKey: AppGroup.pendingShareUrlKey), !stored.isEmpty {
      pendingUrl = stored
      defaults.removeObject(forKey: AppGroup.pendingShareUrlKey)
      trace("drained pending URL from app group: \(stored)")
    }
  }

  private func drainPendingHtml() -> [String: Any]? {
    let fm = FileManager.default
    guard let container = fm.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id) else {
      NSLog("[WebSpace] app group \(AppGroup.id) unavailable; cannot drain pending HTML")
      return nil
    }
    let fileURL = container.appendingPathComponent(AppGroup.pendingShareHtmlFile)
    guard let data = try? Data(contentsOf: fileURL),
          let content = String(data: data, encoding: .utf8),
          !content.isEmpty else {
      return nil
    }
    var payload: [String: Any] = ["content": content]
    if let defaults = AppGroup.defaults {
      if let title = defaults.string(forKey: AppGroup.pendingShareHtmlTitleKey), !title.isEmpty {
        payload["title"] = title
      }
      if let source = defaults.string(forKey: AppGroup.pendingShareHtmlSourceKey), !source.isEmpty {
        payload["sourceUri"] = source
      }
      defaults.removeObject(forKey: AppGroup.pendingShareHtmlTitleKey)
      defaults.removeObject(forKey: AppGroup.pendingShareHtmlSourceKey)
    }
    try? fm.removeItem(at: fileURL)
    trace("drained pending HTML from app group (\(content.count) chars)")
    return payload
  }
}

/// URLs and hosts a user opened; kept out of release logs.
private func trace(_ message: @autoclosure () -> String) {
  #if DEBUG
    NSLog("[WebSpace] \(message())")
  #endif
}
