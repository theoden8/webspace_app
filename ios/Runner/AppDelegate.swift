import BackgroundTasks
import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var locationPlugin: LocationPlugin?
  private var backgroundTaskPlugin: BackgroundTaskPlugin?

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
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
