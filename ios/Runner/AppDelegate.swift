import BackgroundTasks
import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var locationPlugin: LocationPlugin?
  private var backgroundTaskPlugin: BackgroundTaskPlugin?
  private var shortcutsPlugin: ShortcutsPlugin?
  private var pendingShareUrl: String?

  private let shareChannelName = "org.codeberg.theoden8.webspace/share_intent"
  private let appGroupId = "group.org.codeberg.theoden8.webspace"
  private let pendingUrlKey = "pending_share_url"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // BGTaskScheduler.register MUST run before the app finishes launching,
    // otherwise iOS throws an exception when a scheduled task fires. We
    // register the launch handler here and forward to the plugin instance
    // once it's wired up below.
    BackgroundTaskPlugin.registerLaunchHandler { [weak self] task in
      self?.backgroundTaskPlugin?.handleRefreshTask(task)
    }
    // Without this, iOS drops local notifications posted while the app
    // is foregrounded: the plugin's presentBanner/Alert/Sound options
    // never run because the willPresent delegate method isn't called.
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      locationPlugin = LocationPlugin(messenger: controller.binaryMessenger)
      backgroundTaskPlugin = BackgroundTaskPlugin(messenger: controller.binaryMessenger)
      shortcutsPlugin = ShortcutsPlugin(messenger: controller.binaryMessenger)
      registerShareChannel(controller.binaryMessenger)
    }
    if let url = launchOptions?[.url] as? URL {
      capturePendingShareUrl(from: url)
    }
    drainAppGroupPendingUrl()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    #if DEBUG
    NSLog("[WebSpace] application(_:open:) url=\(url.absoluteString)")
    #endif
    capturePendingShareUrl(from: url)
    drainAppGroupPendingUrl()
    return super.application(app, open: url, options: options)
  }

  private func registerShareChannel(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: shareChannelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      switch call.method {
      case "consumeLaunchUrl":
        self.drainAppGroupPendingUrl()
        let url = self.pendingShareUrl
        self.pendingShareUrl = nil
        #if DEBUG
        NSLog("[WebSpace] consumeLaunchUrl returning: \(url ?? "nil")")
        #endif
        result(url)
      case "consumeLaunchHtml":
        // LIR-012: iOS Share Extension HTML delivery isn't wired yet
        // (depends on the Share Extension target work in tasks 5.1 / 5.5).
        // Return null so the Dart side falls through to the URL channel
        // without raising MissingPluginException.
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func capturePendingShareUrl(from url: URL) {
    guard url.scheme?.lowercased() == "webspace" else {
      #if DEBUG
      NSLog("[WebSpace] ignoring non-webspace scheme: \(url.scheme ?? "nil")")
      #endif
      return
    }
    let host = url.host?.lowercased()
    // LIR-004: webspace://open?url=<encoded http(s)> is the canonical form
    // for "Open in WebSpace" links from external apps. Pass the WHOLE URL
    // through to Dart — `LinkRoutingService.parseWebspaceUri` validates and
    // unwraps the inner http(s) target. The legacy `webspace://share?url=`
    // form is preserved below for back-compat.
    if host == "open" {
      pendingShareUrl = url.absoluteString
      #if DEBUG
      NSLog("[WebSpace] captured open URL: \(url.absoluteString)")
      #endif
    } else if host == "share" {
      guard
        let inner = URLComponents(url: url, resolvingAgainstBaseURL: false)?
          .queryItems?.first(where: { $0.name == "url" })?.value,
        let httpScheme = URL(string: inner)?.scheme?.lowercased(),
        httpScheme == "http" || httpScheme == "https"
      else {
        #if DEBUG
        NSLog("[WebSpace] share URL has no valid http(s) inner: \(url.absoluteString)")
        #endif
        return
      }
      pendingShareUrl = inner
      #if DEBUG
      NSLog("[WebSpace] captured share inner URL: \(inner)")
      #endif
    } else if host == "shortcut" {
      // HS-011: a Home Screen Web Clip fires webspace://shortcut?siteId=...
      // Funnel the siteId into the same App Group key the App Intents path
      // writes (pending_shortcut_site_id) so getLaunchSiteId drains it on the
      // next cold/warm launch and the existing reset-to-initUrl plumbing runs.
      if let siteId = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "siteId" })?.value,
        !siteId.isEmpty,
        let defaults = UserDefaults(suiteName: appGroupId)
      {
        defaults.set(siteId, forKey: "pending_shortcut_site_id")
        #if DEBUG
        NSLog("[WebSpace] captured web clip siteId: \(siteId)")
        #endif
      }
    } else if host == "qr" {
      // Pass the original webspace:// URL through; Dart routes it to the
      // QR-apply path by scheme.
      pendingShareUrl = url.absoluteString
      #if DEBUG
      NSLog("[WebSpace] captured qr URL")
      #endif
    } else {
      #if DEBUG
      NSLog("[WebSpace] unrecognized webspace host: \(host ?? "nil")")
      #endif
    }
  }

  private func drainAppGroupPendingUrl() {
    guard let defaults = UserDefaults(suiteName: appGroupId) else {
      NSLog("[WebSpace] app group \(appGroupId) unavailable; cannot drain pending URL")
      return
    }
    if let stored = defaults.string(forKey: pendingUrlKey), !stored.isEmpty {
      pendingShareUrl = stored
      defaults.removeObject(forKey: pendingUrlKey)
      #if DEBUG
      NSLog("[WebSpace] drained pending URL from app group: \(stored)")
      #endif
    }
  }
}
