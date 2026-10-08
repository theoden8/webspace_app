import BackgroundTasks
import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var locationPlugin: LocationPlugin?
  private var backgroundTaskPlugin: BackgroundTaskPlugin?
  private var shortcutsPlugin: ShortcutsPlugin?
  private var mediaSessionPlugin: MediaSessionPlugin?
  private var torControllerPlugin: TorControllerPlugin?
  private let shareIntent = ShareIntentPlugin()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // A launch iOS makes for a refresh task arrives in the background state;
    // the background log needs that to tell it from one the user made.
    BackgroundLogFile.shared.recordLaunch(
      "process launched (applicationState: "
        + "\(BackgroundTaskPlugin.describe(application.applicationState)))")
    BackgroundTaskPlugin.recordLowPowerMode(changed: false)
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
      mediaSessionPlugin = MediaSessionPlugin(messenger: controller.binaryMessenger)
      torControllerPlugin = TorControllerPlugin(messenger: controller.binaryMessenger)
      if let registrar = self.registrar(forPlugin: "WebSpaceShortcutsLink") {
        registrar.register(
          ShortcutsLinkViewFactory(messenger: controller.binaryMessenger),
          withId: ShortcutsLinkViewFactory.viewType
        )
      }
      shareIntent.attach(to: controller.binaryMessenger)
    }
    shareIntent.receive([launchOptions?[.url] as? URL].compactMap { $0 })
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    shareIntent.receive([url])
    return super.application(app, open: url, options: options)
  }
}
