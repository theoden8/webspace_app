import Cocoa
import FlutterMacOS
import UserNotifications

@main
class AppDelegate: FlutterAppDelegate {
  private var pendingShareUrl: String?
  private let shareChannelName = "org.codeberg.theoden8.webspace/share_intent"

  /// Mirrors `macos/ShareExtension/ShareViewController.swift`. macOS
  /// sandboxed app groups require the team-prefixed form
  /// `<TEAMID>.group.<id>`. If you change the DEVELOPMENT_TEAM on
  /// either target, update both this constant and the matching one
  /// in the extension.
  private let appGroupId = "7NGC2P87LM.group.org.codeberg.theoden8.webspace"
  private let pendingUrlKey = "pending_share_url"

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // Same UN delegate requirement as iOS: without this, foreground
    // notifications never reach willPresent and are dropped silently.
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    super.applicationDidFinishLaunching(notification)
    registerShareChannelOnMainWindow()
    // Cold-launch fallback: extensions that wrote to the app group
    // before the host app started are picked up here.
    drainAppGroupPendingUrl()
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return false
  }

  // LIR-004 / LIR-007: webspace://open?url=... and the legacy
  // webspace://share?url=... entry point on macOS. Triggered by
  // `open webspace://...`, NSWorkspace, the macOS Share Extension's
  // NSWorkspace.shared.open call, the Services menu, etc.
  override func application(_ application: NSApplication, open urls: [URL]) {
    NSLog("[WebSpace.macOS] application(_:open:) urls=\(urls.map { $0.absoluteString })")
    for url in urls {
      capturePendingShareUrl(from: url)
    }
    // Also drain the app group: if the share extension wrote to it but
    // the URL-scheme open arrived first, the drain idempotently picks
    // up anything still pending.
    drainAppGroupPendingUrl()
  }

  private func registerShareChannelOnMainWindow() {
    guard
      let window = NSApplication.shared.windows.first,
      let controller = window.contentViewController as? FlutterViewController
    else { return }
    let channel = FlutterMethodChannel(
      name: shareChannelName,
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      switch call.method {
      case "consumeLaunchUrl":
        self.drainAppGroupPendingUrl()
        let url = self.pendingShareUrl
        self.pendingShareUrl = nil
        NSLog("[WebSpace.macOS] consumeLaunchUrl returning: \(url ?? "nil")")
        result(url)
      case "consumeLaunchHtml":
        // Share Extension HTML delivery isn't wired yet on macOS.
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func capturePendingShareUrl(from url: URL) {
    guard url.scheme?.lowercased() == "webspace" else {
      NSLog("[WebSpace.macOS] ignoring non-webspace scheme: \(url.scheme ?? "nil")")
      return
    }
    let host = url.host?.lowercased()
    if host == "open" {
      pendingShareUrl = url.absoluteString
      NSLog("[WebSpace.macOS] captured open URL: \(url.absoluteString)")
    } else if host == "share" {
      // Legacy form, used by the macOS Share Extension's
      // NSWorkspace.shared.open call. Unwraps to the inner http(s)
      // target; matches the iOS AppDelegate path.
      guard
        let inner = URLComponents(url: url, resolvingAgainstBaseURL: false)?
          .queryItems?.first(where: { $0.name == "url" })?.value,
        let httpScheme = URL(string: inner)?.scheme?.lowercased(),
        httpScheme == "http" || httpScheme == "https"
      else {
        NSLog("[WebSpace.macOS] share URL has no valid http(s) inner: \(url.absoluteString)")
        return
      }
      pendingShareUrl = inner
      NSLog("[WebSpace.macOS] captured share inner URL: \(inner)")
    } else if host == "qr" {
      // Pass the original webspace:// URL through; Dart routes it to
      // the QR-apply path by scheme.
      pendingShareUrl = url.absoluteString
      NSLog("[WebSpace.macOS] captured qr URL")
    } else {
      NSLog("[WebSpace.macOS] unrecognized webspace host: \(host ?? "nil")")
    }
  }

  private func drainAppGroupPendingUrl() {
    guard let defaults = UserDefaults(suiteName: appGroupId) else {
      NSLog("[WebSpace.macOS] app group \(appGroupId) unavailable; cannot drain pending URL")
      return
    }
    if let stored = defaults.string(forKey: pendingUrlKey), !stored.isEmpty {
      pendingShareUrl = stored
      defaults.removeObject(forKey: pendingUrlKey)
      NSLog("[WebSpace.macOS] drained pending URL from app group: \(stored)")
    }
  }
}
