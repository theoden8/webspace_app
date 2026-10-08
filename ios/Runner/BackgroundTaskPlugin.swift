import AVFoundation
import BackgroundTasks
import Flutter
import UIKit
import UserNotifications

/// Native half of the background log (DEVTOOLS-011): JSON lines under
/// Application Support, written by this plugin and the app delegate and
/// appended to from Dart. The file exists only while developer mode is on, and
/// its existence is the switch, so a launch iOS makes for a refresh task
/// records exactly then.
///
/// Nothing written here names a site: the native side has no site data, and
/// Dart sends only its non-sensitive lines.
///
/// Single owner (BUG-007): every read, append, compaction and delete runs on
/// `queue`. The refresh-task queue, the expiration handlers and the platform
/// thread only enqueue.
final class BackgroundLogFile {
  static let shared = BackgroundLogFile()

  private static let maxLines = 1000
  private static let compactAtBytes: UInt64 = 192 * 1024

  private let queue = DispatchQueue(label: "org.codeberg.theoden8.webspace.background-log")
  private let url: URL? = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
    .appendingPathComponent("background_log.jsonl")

  func record(_ message: String, level: String = "info") {
    append(
      t: Int64(Date().timeIntervalSince1970 * 1000), level: level, tag: "iOS",
      message: message)
  }

  func append(t: Int64, level: String, tag: String, message: String) {
    let object: [String: Any] = ["t": t, "l": level, "g": tag, "m": message]
    guard let url = url,
      let json = try? JSONSerialization.data(withJSONObject: object)
    else { return }
    let line = json + Data([0x0a])
    queue.async {
      guard FileManager.default.fileExists(atPath: url.path) else { return }
      do {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        try handle.write(contentsOf: line)
        if end + UInt64(line.count) > BackgroundLogFile.compactAtBytes {
          try BackgroundLogFile.compact(url)
        }
      } catch {
        NSLog("BackgroundLogFile: append failed: \(error)")
      }
    }
  }

  /// The launch line, after a note when the previous process ended inside its
  /// grace period: the log's last word on that window is its start, with no
  /// expiry, resume or termination after it. Nothing else records such an
  /// ending, so without the note it reads as a gap.
  func recordLaunch(_ message: String) {
    let t = Int64(Date().timeIntervalSince1970 * 1000)
    queue.async {
      guard let url = self.url, FileManager.default.fileExists(atPath: url.path) else { return }
      do {
        let text = try String(contentsOf: url, encoding: .utf8)
        if BackgroundLogFile.endedInGrace(text) {
          self.append(
            t: t, level: "warning", tag: "iOS",
            message: "the previous process ended inside its grace period, "
              + "without an expiry or a termination notice")
        }
      } catch {
        NSLog("BackgroundLogFile: launch read failed: \(error)")
      }
      self.append(t: t, level: "info", tag: "iOS", message: message)
    }
  }

  private static func endedInGrace(_ text: String) -> Bool {
    for line in text.split(separator: "\n").reversed() {
      guard let data = line.data(using: .utf8),
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        let message = object["m"] as? String
      else { continue }
      if message.hasPrefix("grace period started") { return true }
      if message.hasPrefix("grace period") || message.hasPrefix("process launched")
        || message.hasPrefix("process terminating") || message.hasPrefix("App resumed")
      {
        return false
      }
    }
    return false
  }

  /// Waits for every append queued so far. For `willTerminate`, after which
  /// the process may not get to run the queue.
  func flush() {
    queue.sync {}
  }

  /// Keeps the newest `maxLines`; the atomic write leaves the old file whole
  /// if the process dies mid-write.
  private static func compact(_ url: URL) throws {
    let text = try String(contentsOf: url, encoding: .utf8)
    let keep = text.split(separator: "\n").suffix(maxLines)
    try (keep.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
  }

  func setEnabled(_ enabled: Bool) {
    guard let url = url else { return }
    queue.async {
      let fm = FileManager.default
      do {
        if enabled {
          if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(
              at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = fm.createFile(atPath: url.path, contents: nil)
          }
        } else if fm.fileExists(atPath: url.path) {
          try fm.removeItem(at: url)
        }
      } catch {
        NSLog("BackgroundLogFile: setEnabled(\(enabled)) failed: \(error)")
      }
    }
  }

  func clear() {
    guard let url = url else { return }
    queue.async {
      guard FileManager.default.fileExists(atPath: url.path) else { return }
      do {
        try Data().write(to: url, options: .atomic)
      } catch {
        NSLog("BackgroundLogFile: clear failed: \(error)")
      }
    }
  }

  /// `done` runs on the main queue with the lines, or nil when the file could
  /// not be read.
  func read(_ done: @escaping ([String]?) -> Void) {
    queue.async {
      var lines: [String]? = []
      if let url = self.url, FileManager.default.fileExists(atPath: url.path) {
        do {
          lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        } catch {
          NSLog("BackgroundLogFile: read failed: \(error)")
          lines = nil
        }
      }
      let result = lines
      DispatchQueue.main.async { done(result) }
    }
  }
}

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

  private var observers: [NSObjectProtocol] = []

  init(messenger: FlutterBinaryMessenger) {
    self.channel = FlutterMethodChannel(
      name: "org.codeberg.theoden8.webspace/background_task",
      binaryMessenger: messenger
    )
    super.init()
    self.channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    observeSystemEvents()
  }

  /// DEVTOOLS-011: what decides whether a page or a refresh task gets to run
  /// and that no lifecycle line shows. Flutter reports leaving the screen as
  /// memory pressure too (PAUSE-034), so a real warning is told apart here.
  private func observeSystemEvents() {
    let center = NotificationCenter.default
    observers = [
      center.addObserver(
        forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
      ) { _ in
        BackgroundLogFile.shared.record(
          "iOS memory warning (applicationState: "
            + "\(BackgroundTaskPlugin.describe(UIApplication.shared.applicationState)))",
          level: "warning")
      },
      center.addObserver(
        forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
      ) { _ in
        BackgroundTaskPlugin.recordLowPowerMode(changed: true)
      },
      center.addObserver(
        forName: UIApplication.willTerminateNotification, object: nil, queue: .main
      ) { _ in
        BackgroundLogFile.shared.record("process terminating (willTerminate)")
        BackgroundLogFile.shared.flush()
      },
    ]
  }

  static func recordLowPowerMode(changed: Bool) {
    if ProcessInfo.processInfo.isLowPowerModeEnabled {
      BackgroundLogFile.shared.record(
        "Low Power Mode on: iOS turns off Background App Refresh while it lasts",
        level: "warning")
    } else if changed {
      BackgroundLogFile.shared.record("Low Power Mode off")
    }
  }

  static func describe(_ state: UIApplication.State) -> String {
    switch state {
    case .active: return "active"
    case .inactive: return "inactive"
    case .background: return "background"
    @unknown default: return "unknown"
    }
  }

  /// Registers the BGAppRefreshTask handler. Must be called from
  /// `application(_:didFinishLaunchingWithOptions:)` BEFORE the app
  /// finishes launching, per `BGTaskScheduler` requirements.
  static func registerLaunchHandler(
    _ handler: @escaping (BGAppRefreshTask) -> Void
  ) {
    let registered = BGTaskScheduler.shared.register(
      forTaskWithIdentifier: refreshIdentifier,
      using: nil
    ) { task in
      guard let refresh = task as? BGAppRefreshTask else {
        task.setTaskCompleted(success: false)
        return
      }
      handler(refresh)
    }
    if !registered {
      BackgroundLogFile.shared.record(
        "BGTaskScheduler refused to register \(refreshIdentifier); no refresh task can run",
        level: "error")
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
    NSLog("BackgroundTaskPlugin: BGAppRefreshTask received — forwarding to Dart")
    BackgroundLogFile.shared.record("BGAppRefreshTask received; forwarding to Dart")
    task.expirationHandler = { [weak self, weak task] in
      guard let self = self, let task = task else { return }
      NSLog("BackgroundTaskPlugin: refresh task expired before Dart completed")
      BackgroundLogFile.shared.record(
        "refresh task expired before Dart completed", level: "warning")
      DispatchQueue.main.async { self.completeTask(task, success: false) }
    }

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      // A previous task that never reported completion loses its slot to
      // this one — complete it (once) before taking over.
      if let previous = self.pendingRefreshTask {
        BackgroundLogFile.shared.record(
          "a previous refresh task never completed; superseded", level: "warning")
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
    BackgroundLogFile.shared.record("refresh task completed (success: \(success))")
  }

  /// Submits a new BGAppRefreshTaskRequest. Idempotent: BGTaskScheduler
  /// replaces any existing pending request for the same identifier.
  func scheduleNextRefresh() {
    let request = BGAppRefreshTaskRequest(identifier: BackgroundTaskPlugin.refreshIdentifier)
    request.earliestBeginDate = Date(
      timeIntervalSinceNow: BackgroundTaskPlugin.refreshMinDelaySeconds)
    let delay = Int(BackgroundTaskPlugin.refreshMinDelaySeconds)
    do {
      try BGTaskScheduler.shared.submit(request)
      NSLog("BackgroundTaskPlugin: scheduled next refresh in >= \(delay)s")
      BackgroundLogFile.shared.record("refresh request submitted (earliest in \(delay)s)")
    } catch let error as BGTaskScheduler.Error {
      NSLog("BackgroundTaskPlugin: failed to schedule refresh: \(error)")
      let code: String
      switch error.code {
      case .unavailable: code = "unavailable"
      case .tooManyPendingTaskRequests: code = "tooManyPendingTaskRequests"
      case .notPermitted: code = "notPermitted"
      @unknown default: code = "code \(error.code.rawValue)"
      }
      BackgroundLogFile.shared.record(
        "refresh request rejected by BGTaskScheduler: \(code)", level: "error")
    } catch {
      NSLog("BackgroundTaskPlugin: failed to schedule refresh: \(error)")
      BackgroundLogFile.shared.record(
        "refresh request rejected: \(error.localizedDescription)", level: "error")
    }
  }

  /// DEVTOOLS-011: the OS gates a refresh task and a notification depend on,
  /// as ordered (name, value) rows. Runs on the main queue.
  private func systemState(_ result: @escaping FlutterResult) {
    var rows: [[String]] = []
    let refresh: String
    switch UIApplication.shared.backgroundRefreshStatus {
    case .available: refresh = "available"
    case .denied: refresh = "denied"
    case .restricted: refresh = "restricted"
    @unknown default: refresh = "unknown"
    }
    rows.append(["ios.backgroundRefreshStatus", refresh])
    rows.append(["ios.lowPowerMode", "\(ProcessInfo.processInfo.isLowPowerModeEnabled)"])
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      let auth: String
      switch settings.authorizationStatus {
      case .notDetermined: auth = "notDetermined"
      case .denied: auth = "denied"
      case .authorized: auth = "authorized"
      case .provisional: auth = "provisional"
      case .ephemeral: auth = "ephemeral"
      @unknown default: auth = "unknown"
      }
      let alert: String
      switch settings.alertSetting {
      case .notSupported: alert = "notSupported"
      case .disabled: alert = "disabled"
      case .enabled: alert = "enabled"
      @unknown default: alert = "unknown"
      }
      BGTaskScheduler.shared.getPendingTaskRequests { requests in
        let mine = requests.filter {
          $0.identifier == BackgroundTaskPlugin.refreshIdentifier
        }
        let earliest = mine.compactMap { $0.earliestBeginDate }.min()
        DispatchQueue.main.async {
          rows.append(["ios.notificationAuthorization", auth])
          rows.append(["ios.notificationAlerts", alert])
          rows.append(["ios.pendingRefreshRequests", "\(mine.count)"])
          if let earliest = earliest {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            rows.append(["ios.pendingRefreshEarliest", formatter.string(from: earliest)])
          }
          result(rows)
        }
      }
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
      NSLog("BackgroundTaskPlugin: cancelling scheduled refreshes")
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundTaskPlugin.refreshIdentifier)
      BackgroundLogFile.shared.record("pending refresh requests cancelled")
      result(nil)
    case "setBackgroundAudioActive":
      let active = (call.arguments as? [String: Any])?["active"] as? Bool ?? false
      setBackgroundAudioActive(active)
      result(nil)
    case "bgRefreshDidComplete":
      let success: Bool
      if let args = call.arguments as? [String: Any], let s = args["success"] as? Bool {
        success = s
      } else {
        success = true
      }
      NSLog("BackgroundTaskPlugin: Dart reported refresh complete (success: \(success))")
      // Runs on the Flutter platform (main) thread, the same queue the
      // pending slot is confined to. Complete via the funnel so a racing
      // expiration handler can't also complete the task.
      if let task = pendingRefreshTask {
        completeTask(task, success: success)
      } else {
        BackgroundLogFile.shared.record(
          "Dart reported completion with no refresh task pending")
      }
      result(nil)
    case "setBackgroundLogEnabled":
      let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
      BackgroundLogFile.shared.setEnabled(enabled)
      result(nil)
    case "appendBackgroundLog":
      if let args = call.arguments as? [String: Any],
        let t = (args["t"] as? NSNumber)?.int64Value,
        let message = args["message"] as? String
      {
        BackgroundLogFile.shared.append(
          t: t, level: args["level"] as? String ?? "info",
          tag: args["tag"] as? String ?? "Dart", message: message)
      }
      result(nil)
    case "readBackgroundLog":
      BackgroundLogFile.shared.read { lines in
        if let lines = lines {
          result(lines)
        } else {
          result(
            FlutterError(code: "READ_FAILED", message: "background log unreadable", details: nil))
        }
      }
    case "clearBackgroundLog":
      BackgroundLogFile.shared.clear()
      result(nil)
    case "backgroundSystemState":
      systemState(result)
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
      BackgroundLogFile.shared.record(
        "grace period expired; iOS suspends the app now", level: "warning")
      self.endGracePeriod()
    }
    if graceTaskId == .invalid {
      BackgroundLogFile.shared.record(
        "grace period refused by iOS (no background time left)", level: "warning")
    } else {
      BackgroundLogFile.shared.record("grace period started (~30s before suspension)")
    }
  }

  /// BGAUDIO-003: `.playback` (with the `audio` UIBackgroundModes entry)
  /// lets WKWebView media keep running after the app is backgrounded;
  /// `.ambient` restores the respect-the-silent-switch default when no
  /// background-audio site is loaded. Category selection alone is enough —
  /// the media stack activates the session when playback actually starts,
  /// so we don't call setActive(true) here and steal audio focus from
  /// other apps while nothing is playing.
  private func setBackgroundAudioActive(_ active: Bool) {
    let session = AVAudioSession.sharedInstance()
    do {
      if active {
        try session.setCategory(.playback, mode: .default)
      } else {
        try session.setCategory(.ambient, mode: .default)
      }
    } catch {
      NSLog("BackgroundTaskPlugin: audio session category change failed: \(error)")
    }
  }

  private func endGracePeriod() {
    let id = graceTaskId
    if id == .invalid { return }
    graceTaskId = .invalid
    UIApplication.shared.endBackgroundTask(id)
  }
}
