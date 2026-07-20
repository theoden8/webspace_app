import BackgroundTasks
import Flutter
import UIKit

/// iOS bridge for [`BackgroundTaskService`](../../lib/services/background_task_service.dart),
/// implementing NOTIF-005-I (iOS Background Strategy):
///
/// 1. `beginBackgroundTask` — when the app enters background, the Dart side
///    calls `beginGracePeriod` to extend execution by ~30 seconds so JS
///    timers in notification-enabled webviews can finish firing scheduled
///    notifications before iOS suspends the process.
///
/// 2. `BGAppRefreshTask` — registered at app launch under the identifier
///    `org.codeberg.theoden8.webspace.notification-refresh`. iOS schedules
///    these opportunistically (typically every 15-30 minutes). The handler
///    fires the `onBackgroundRefresh` callback into Dart, which reloads
///    every notification site so its page JS can poll for new content and
///    fire any pending notifications.
///
/// The schedule is best-effort: iOS decides when (and whether) to run a
/// refresh. We re-submit on every refresh so the cycle continues; if the
/// user kills the app, the schedule is dropped until next launch.
class BackgroundTaskPlugin: NSObject {
  private let channel: FlutterMethodChannel
  private static let refreshIdentifier =
    "org.codeberg.theoden8.webspace.notification-refresh"
  private static let refreshMinDelaySeconds: TimeInterval = 15 * 60

  /// Tracks the currently in-flight `beginBackgroundTask` so a stray second
  /// call doesn't leak a task identifier.
  private var graceTaskId: UIBackgroundTaskIdentifier = .invalid

  /// Pending BGAppRefreshTask, held while we wait for Dart to report
  /// completion via `bgRefreshDidComplete`. iOS expects exactly one call to
  /// `setTaskCompleted(success:)` per task.
  private var pendingRefreshTask: BGAppRefreshTask?

  init(messenger: FlutterBinaryMessenger) {
    self.channel = FlutterMethodChannel(
      name: "org.codeberg.theoden8.webspace/background_task",
      binaryMessenger: messenger
    )
    super.init()
    self.channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
  }

  /// Registers the BGAppRefreshTask handler. Must be called from
  /// `application(_:didFinishLaunchingWithOptions:)` BEFORE the app
  /// finishes launching, per `BGTaskScheduler` requirements.
  static func registerLaunchHandler(
    _ handler: @escaping (BGAppRefreshTask) -> Void
  ) {
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: refreshIdentifier,
      using: nil
    ) { task in
      guard let refresh = task as? BGAppRefreshTask else {
        task.setTaskCompleted(success: false)
        return
      }
      handler(refresh)
    }
  }

  /// Called by AppDelegate when iOS hands us a refresh task. Forwards to
  /// Dart and re-schedules the next refresh.
  ///
  /// `pendingRefreshTask` is touched from three threads: this handler (the
  /// `BGTaskScheduler` launch queue, off-main), the `expirationHandler`
  /// (iOS's own thread), and `bgRefreshDidComplete` (the Flutter platform /
  /// main thread). `BGTask.setTaskCompleted` must fire exactly once per
  /// task; an unsynchronised double-call crashes the process and a lost
  /// write leaks the completion (iOS then throttles future scheduling). So
  /// every access to the pending slot is funnelled onto the main queue and
  /// completion is made idempotent per task via [completeTask].
  func handleRefreshTask(_ task: BGAppRefreshTask) {
    task.expirationHandler = { [weak self, weak task] in
      guard let self = self, let task = task else { return }
      DispatchQueue.main.async { self.completeTask(task, success: false) }
    }

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      // A previous task that never reported completion loses its slot to
      // this one — complete it (once) before taking over.
      if let previous = self.pendingRefreshTask {
        self.completeTask(previous, success: false)
      }
      self.pendingRefreshTask = task
      // Dart calls back via `bgRefreshDidComplete`; don't mark the task
      // complete from the channel result or it races the Dart-side reload.
      self.channel.invokeMethod("onBackgroundRefresh", arguments: nil, result: nil)
      self.scheduleNextRefresh()
    }
  }

  /// Complete [task] exactly once. Must run on the main queue. The identity
  /// guard makes a second call (e.g. expiration firing after Dart already
  /// reported completion, or vice versa) a no-op, and prevents a stale
  /// expiration handler from completing a newer task.
  private func completeTask(_ task: BGAppRefreshTask, success: Bool) {
    guard pendingRefreshTask === task else { return }
    pendingRefreshTask = nil
    task.setTaskCompleted(success: success)
  }

  /// Submits a new BGAppRefreshTaskRequest. Idempotent: BGTaskScheduler
  /// replaces any existing pending request for the same identifier.
  func scheduleNextRefresh() {
    let request = BGAppRefreshTaskRequest(identifier: BackgroundTaskPlugin.refreshIdentifier)
    request.earliestBeginDate = Date(
      timeIntervalSinceNow: BackgroundTaskPlugin.refreshMinDelaySeconds)
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      NSLog("BackgroundTaskPlugin: failed to schedule refresh: \(error)")
    }
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "beginGracePeriod":
      beginGracePeriod()
      result(nil)
    case "endGracePeriod":
      endGracePeriod()
      result(nil)
    case "scheduleRefresh":
      scheduleNextRefresh()
      result(nil)
    case "cancelScheduledRefreshes":
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundTaskPlugin.refreshIdentifier)
      result(nil)
    case "bgRefreshDidComplete":
      let success: Bool
      if let args = call.arguments as? [String: Any], let s = args["success"] as? Bool {
        success = s
      } else {
        success = true
      }
      // Runs on the Flutter platform (main) thread, the same queue the
      // pending slot is confined to. Complete via the funnel so a racing
      // expiration handler can't also complete the task.
      if let task = pendingRefreshTask {
        completeTask(task, success: success)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func beginGracePeriod() {
    if graceTaskId != .invalid {
      // Already running — extend the deadline by re-arming. UIKit only
      // allows one named task here; calling begin again starts a new one
      // and the old one ends naturally.
      let stale = graceTaskId
      graceTaskId = .invalid
      UIApplication.shared.endBackgroundTask(stale)
    }
    graceTaskId = UIApplication.shared.beginBackgroundTask(withName: "WebspaceNotificationGrace") {
      [weak self] in
      // Expiration handler — iOS warns we're about to be suspended.
      guard let self = self else { return }
      self.endGracePeriod()
    }
  }

  private func endGracePeriod() {
    let id = graceTaskId
    if id == .invalid { return }
    graceTaskId = .invalid
    UIApplication.shared.endBackgroundTask(id)
  }
}
