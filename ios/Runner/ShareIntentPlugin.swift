// One source, both Apple Runners: the macOS project compiles this file from
// here, as it does TorControllerPlugin.swift.
#if canImport(FlutterMacOS)
  import FlutterMacOS
#else
  import Flutter
  import UIKit
#endif

import Foundation

/// The `share_intent` channel: the `webspace://` URL the OS opened the app
/// with, or what the share extension left in the App Group, held until Dart
/// asks for it (LIR-004, LIR-007, LIR-012).
///
/// The app delegate owns it from launch and attaches the channel once there
/// is an engine, because macOS delivers `application(_:open:)` for a launch
/// URL before `applicationDidFinishLaunching`, and iOS starts the engine only
/// when the scene connects.
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
        WebSpaceLog.line("consumeLaunchUrl returning: \(url ?? "nil")", carries: .userData)
        result(url)
      case "consumeLaunchHtml":
        // The share extension writes an HTML document into the group
        // container and wakes the app with `webspace://openhtml`; one read,
        // then delete. Only the iOS extension writes one.
        let payload = self.drainPendingHtml()
        WebSpaceLog.line("consumeLaunchHtml returning: \(payload == nil ? "nil" : "payload")", carries: .userData)
        result(payload)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Takes the URLs the OS opened the app with, then whatever the share
  /// extension left in the App Group, which wins when both are present.
  /// True when one of them was a `webspace://` URL.
  @discardableResult
  func receive(_ urls: [URL]) -> Bool {
    let claimed = urls.map { capture($0) }.contains(true)
    drainPendingUrl()
    return claimed
  }

  /// False for a URL of any other scheme, which is not this plugin's.
  private func capture(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "webspace" else {
      WebSpaceLog.line("ignoring non-webspace scheme: \(url.scheme ?? "nil")", carries: .userData)
      return false
    }
    switch url.host?.lowercased() {
    case "open", "qr":
      // LIR-004: the whole URL goes to Dart, whose
      // `LinkRoutingService.parseWebspaceUri` validates and unwraps the inner
      // http(s) target; a qr URL is routed by its scheme.
      pendingUrl = url.absoluteString
      WebSpaceLog.line("captured \(url.absoluteString)", carries: .userData)
    case "share":
      // The legacy form, still what the share extensions open.
      guard
        let inner = URLComponents(url: url, resolvingAgainstBaseURL: false)?
          .queryItems?.first(where: { $0.name == "url" })?.value,
        let httpScheme = URL(string: inner)?.scheme?.lowercased(),
        httpScheme == "http" || httpScheme == "https"
      else {
        WebSpaceLog.line("share URL has no valid http(s) inner: \(url.absoluteString)", carries: .userData)
        return true
      }
      pendingUrl = inner
      WebSpaceLog.line("captured share inner URL: \(inner)", carries: .userData)
    case "openhtml":
      // Only foregrounds the app: the document rides the group container,
      // and Dart's share poll drains it through consumeLaunchHtml.
      WebSpaceLog.line("received openhtml trigger", carries: .userData)
    case let host:
      WebSpaceLog.line("unrecognized webspace host: \(host ?? "nil")", carries: .userData)
    }
    return true
  }

  private func drainPendingUrl() {
    guard let defaults = AppGroup.defaults else {
      WebSpaceLog.line("app group \(AppGroup.id) unavailable; cannot drain pending URL", carries: .noUserData)
      return
    }
    if let stored = defaults.string(forKey: AppGroup.pendingShareUrlKey), !stored.isEmpty {
      pendingUrl = stored
      defaults.removeObject(forKey: AppGroup.pendingShareUrlKey)
      WebSpaceLog.line("drained pending URL from app group: \(stored)", carries: .userData)
    }
  }

  private func drainPendingHtml() -> [String: Any]? {
    let fm = FileManager.default
    guard let container = fm.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id) else {
      WebSpaceLog.line("app group \(AppGroup.id) unavailable; cannot drain pending HTML", carries: .noUserData)
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
    WebSpaceLog.line("drained pending HTML from app group (\(content.count) chars)", carries: .userData)
    return payload
  }
}

#if !canImport(FlutterMacOS)
  /// Under the scene lifecycle iOS opens a URL on the scene and never through
  /// the app delegate: a launch URL comes in the connection options, a later
  /// one through `openURLContexts`. Claiming a `webspace://` URL also keeps it
  /// from Flutter's deep linking, which has no route for one.
  extension ShareIntentPlugin: FlutterSceneLifeCycleDelegate {
    func scene(
      _ scene: UIScene,
      willConnectTo session: UISceneSession,
      options connectionOptions: UIScene.ConnectionOptions?
    ) -> Bool {
      receive(connectionOptions?.urlContexts.map(\.url) ?? [])
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
      receive(URLContexts.map(\.url))
    }
  }
#endif

