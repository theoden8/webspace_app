import Cocoa
import FlutterMacOS
import UserNotifications

@main
class AppDelegate: FlutterAppDelegate {
  private var shortcutsPlugin: ShortcutsPlugin?
  private let shareIntent = ShareIntentPlugin()

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // Same UN delegate requirement as iOS: without this, foreground
    // notifications never reach willPresent and are dropped silently.
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    super.applicationDidFinishLaunching(notification)
    if let controller = NSApplication.shared.windows.first?.contentViewController
      as? FlutterViewController
    {
      shortcutsPlugin = ShortcutsPlugin(messenger: controller.engine.binaryMessenger)
      shareIntent.attach(to: controller.engine.binaryMessenger)
    }
    // Cold-launch fallback: an extension that wrote to the app group before
    // the app started is picked up here.
    shareIntent.receive([])
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
    shareIntent.receive(urls)
  }
}
