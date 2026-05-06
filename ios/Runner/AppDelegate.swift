import BackgroundTasks
import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var locationPlugin: LocationPlugin?
  private var backgroundTaskPlugin: BackgroundTaskPlugin?
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
    guard url.scheme?.lowercased() == "webspace" else { return }
    let host = url.host?.lowercased()
    // LIR-004: webspace://open?url=<encoded http(s)> is the canonical form
    // for "Open in WebSpace" links from external apps. Pass the WHOLE URL
    // through to Dart — `LinkRoutingService.parseWebspaceUri` validates and
    // unwraps the inner http(s) target. The legacy `webspace://share?url=`
    // form is preserved below for back-compat.
    if host == "open" {
      pendingShareUrl = url.absoluteString
    } else if host == "share" {
      guard
        let inner = URLComponents(url: url, resolvingAgainstBaseURL: false)?
          .queryItems?.first(where: { $0.name == "url" })?.value,
        let httpScheme = URL(string: inner)?.scheme?.lowercased(),
        httpScheme == "http" || httpScheme == "https"
      else { return }
      pendingShareUrl = inner
    } else if host == "qr" {
      // Pass the original webspace:// URL through; Dart routes it to the
      // QR-apply path by scheme.
      pendingShareUrl = url.absoluteString
    }
  }

  private func drainAppGroupPendingUrl() {
    guard let defaults = UserDefaults(suiteName: appGroupId) else { return }
    if let stored = defaults.string(forKey: pendingUrlKey), !stored.isEmpty {
      pendingShareUrl = stored
      defaults.removeObject(forKey: pendingUrlKey)
    }
  }
}
