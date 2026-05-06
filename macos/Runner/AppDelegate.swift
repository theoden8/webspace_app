import Cocoa
import FlutterMacOS
import UserNotifications

@main
class AppDelegate: FlutterAppDelegate {
  private var pendingShareUrl: String?
  private let shareChannelName = "org.codeberg.theoden8.webspace/share_intent"

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // Same UN delegate requirement as iOS: without this, foreground
    // notifications never reach willPresent and are dropped silently.
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    super.applicationDidFinishLaunching(notification)
    registerShareChannelOnMainWindow()
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return false
  }

  // LIR-004: webspace://open?url=... entry point on macOS. Triggered by
  // `open webspace://...`, NSWorkspace, Services menu, etc. The whole URL
  // is forwarded to Dart, which validates and unwraps via
  // `LinkRoutingService.parseWebspaceUri`.
  override func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      capturePendingShareUrl(from: url)
    }
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
        let url = self.pendingShareUrl
        self.pendingShareUrl = nil
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
    guard url.scheme?.lowercased() == "webspace" else { return }
    let host = url.host?.lowercased()
    if host == "open" || host == "qr" {
      pendingShareUrl = url.absoluteString
    }
  }
}
