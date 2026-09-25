// One source, both Apple Runners (TOR-021): the macOS project compiles this
// file from here rather than keeping a copy, so what the integration tier
// exercises is the code iOS ships. It lives under ios/ because iOS is the
// shipping target and this is the path its project has always used; only
// the Flutter module differs per platform.
#if canImport(FlutterMacOS)
  import FlutterMacOS
#else
  import Flutter
#endif

import Foundation
import IPtProxy
import Tor

/// How many log lines the plugin keeps for a subscriber that has not
/// attached yet. Dart owns the real ring (`LogService`); this one only has
/// to cover the gap between tor's first line and the Dart side's `listen`.
private let kTorLogRingCapacity = 300

/// Control-port events the plugin subscribes to.
///
/// `STATUS_CLIENT` drives the state machine. tor's log used to come over
/// this connection too; it comes from tor's log file now, because a tor
/// that never opens a control port is precisely the one whose log matters.
private let kTorControlEvents = ["STATUS_CLIENT"]

/// How long a start waits for a previous tor to leave the process, as a
/// poll interval and a count. A client tor exits immediately on SIGNAL
/// HALT, so this is a bound on a pathological case rather than the
/// expected wait.
private let kTorThreadExitPoll = 0.25
private let kTorThreadExitAttempts = 140

/// How often the stop path re-asks a tor that is on its way out to exit,
/// and how many times. It repeats because the control port may not be open
/// yet when the stop lands.
private let kTorHaltRetryDelay = 1.0
private let kTorHaltRetries = 30

/// Where tor writes its own log, inside the run's data directory, and how
/// often the plugin forwards what is new.
///
/// The control port cannot carry tor's log when tor never opens one, which
/// is the failure this exists for: on a device where the port never
/// appeared, every surface in the app was blind and the only thing anyone
/// could report was a spinner. The file is truncated at every start and
/// removed at stop, and `SafeLogging 1` still scrubs it.
private let kTorLogFileName = "tor.log"
private let kTorLogPollInterval = 1.0

/// How long the plugin keeps trying to reach tor's control port, as a poll
/// interval and a count.
///
/// How long tor takes to write its port file and accept a connection is a
/// property of the device, not of this app: a cold start that reads geoip
/// on a busy phone takes seconds. This budget was three attempts inside
/// 1.5 seconds, which is what turned a slow start into "Could not reach the
/// Tor control port" and left behind a tor nobody could talk to.
private let kTorAttachPoll = 0.5
private let kTorAttachAttempts = 60

/// How long one control command may go unanswered, how long the liveness
/// probe may, and how long the whole exit-country change may. A command
/// written to a dead control socket never completes (BUG-018).
private let kTorControlReplyTimeout = 8.0
private let kTorControlProbeTimeout = 3.0
private let kTorExitCountryTimeout = 20.0

/// Lets one of several racing callers through. `open` is read and written
/// only under `lock` (BUG-007).
final class OnceGate {
  private let lock = NSLock()
  private var open = true

  func claim() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard open else { return false }
    open = false
    return true
  }
}

/// A FlutterResult answered once, by whichever of the reply and a deadline
/// comes first. Answering twice is an error; never answering leaves the
/// Dart side waiting forever, which is what BUG-018 was.
final class OneShotResult {
  private let gate = OnceGate()
  private let result: FlutterResult

  init(_ result: @escaping FlutterResult) {
    self.result = result
  }

  func send(_ value: Any?) {
    guard gate.claim() else { return }
    DispatchQueue.main.async { self.result(value) }
  }
}

/// Event-channel side of the Tor log (TOR-018).
///
/// A class of its own rather than a second `FlutterStreamHandler`
/// conformance on the plugin, since one object cannot back two channels.
/// Concurrency (BUG-007): `ring` is owned by `queue`, `sink` by the main
/// thread, and every delivery is scheduled from `queue`, so the replay on
/// subscribe cannot interleave with a live line.
class TorLogRelay: NSObject, FlutterStreamHandler {
  private let queue = DispatchQueue(label: "org.codeberg.theoden8.webspace.tor.log")
  private var ring: [[String: Any]] = []
  private var sink: FlutterEventSink?

  /// `source` separates tor's own log from the plugin's lifecycle notes:
  /// Dart files the first as sensitive (a notice-level line can name the
  /// bridges this device dials, TOR-017) and the second as ordinary.
  func emit(source: String, severity: String, message: String) {
    let payload: [String: Any] = [
      "source": source,
      "severity": severity,
      "message": message,
    ]
    queue.async {
      self.ring.append(payload)
      if self.ring.count > kTorLogRingCapacity {
        self.ring.removeFirst(self.ring.count - kTorLogRingCapacity)
      }
      DispatchQueue.main.async { self.sink?(payload) }
    }
  }

  func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    // The sink is adopted on the main thread *after* the ring is snapshotted
    // on `queue`, so a line emitted mid-handshake is either in the replay
    // (its own delivery finding no sink yet) or after it, never both.
    queue.async {
      let pending = self.ring
      DispatchQueue.main.async {
        self.sink = events
        for payload in pending { events(payload) }
      }
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }
}

/// iOS bridge for [`TorService`](../../lib/services/tor_service.dart).
///
/// Owns a `TorThread` plus the control-port connection that reports its
/// bootstrap progress, and publishes both as a Flutter method channel and an
/// event channel. Everything policy-shaped — when to start, when to stop,
/// which SOCKS credentials a caller gets — lives in Dart
/// (`tor_engine.dart`); this class only starts, stops, observes and reports.
///
/// Concurrency (BUG-007). Four contexts touch this object: the Flutter
/// platform thread (method calls), the `TorThread` itself, the control
/// port's callback queue, and the bootstrap-timeout timer. Every piece of
/// mutable state below is therefore owned by `stateQueue` and touched
/// nowhere else; the event sink is the one exception and is confined to the
/// main thread, because FlutterEventSink is not thread-safe. Partial
/// synchronization here — a lock on start but not on the observer callback —
/// is the exact shape BUG-007 keeps recurring as.
class TorControllerPlugin: NSObject {
  private let channel: FlutterMethodChannel
  private let eventChannel: FlutterEventChannel
  private let logChannel: FlutterEventChannel

  /// Tor's log and the plugin's own lifecycle notes, on their own channel
  /// (TOR-018). Separate from the status channel because the two have
  /// different shapes and different lifetimes: a status is the current
  /// state, a log line is one moment that already passed.
  private let logRelay = TorLogRelay()

  /// Serial queue owning every stored property below this line.
  private let stateQueue = DispatchQueue(label: "org.codeberg.theoden8.webspace.tor")

  /// Where the control-port handshake runs. It retries with sleeps, and
  /// doing that on `stateQueue` would block every status call and the stop
  /// path behind it for up to a second and a half.
  private let attachQueue = DispatchQueue(label: "org.codeberg.theoden8.webspace.tor.attach")

  /// Sole owner of `ptController` and `startedTransports`, and the only
  /// place IPtProxy's blocking Go calls run. Nothing outside
  /// `startTransport`/`stopTransports` reads or writes that pair, so the
  /// pluggable-transport state shares nothing with `stateQueue`'s — the
  /// none-shared half of BUG-007 rather than a second lock over the same
  /// fields.
  private let ptQueue = DispatchQueue(label: "org.codeberg.theoden8.webspace.tor.pt")
  private var ptController: IPtProxyController?
  private var startedTransports: Set<String> = []

  private var thread: TorThread?

  /// A tor asked to exit whose thread has not finished yet. Only one tor
  /// may run per process, so the next start waits on this rather than
  /// spawning beside it.
  private var exitingThread: TorThread?

  /// Whether `tor_run_main` has been entered in this process. One is the
  /// ceiling, for the life of the app -- see launchWhenFreeLocked.
  private var hasLaunched = false

  /// That tor's configuration, kept until its thread is gone: its
  /// control-port file and cookie are the only way left to ask it to quit.
  private var exitingConfiguration: TorConfiguration?

  /// Bumped by every start and every stop. A control-port handshake, a
  /// catch-up read or a timer from an earlier run carries the generation it
  /// began in and does nothing when it no longer matches.
  private var generation = 0

  private var controller: TorController?
  private var configuration: TorConfiguration?
  private var statusObserver: Any?

  /// Last status published, so a late `status()` call and a fresh event
  /// subscription agree with each other.
  /// torrc options queued by Dart for the next start, as flat pairs.
  ///
  /// Not a dictionary: torrc allows a key more than once and `Bridge` is
  /// repeated per line, so keying by name would silently keep only the last
  /// bridge. They are applied at start rather than by SETCONF because
  /// bridges have to be in force before bootstrap begins.
  private var pendingTorrcOptions: [(String, String)] = []
  /// Whether tor also isolates streams by destination address, on top of the
  /// per-site SOCKS credentials (TOR-003). Dart owns the setting; this is the
  /// value the next launch will use.
  ///
  /// `true` here is NOT the user-facing default, which is off. It is what a
  /// launch falls back to when Dart never got to send the preference -- a
  /// failed read leaves isolation stricter rather than weaker.
  private var pendingIsolateDestAddr = true

  private var state: String = "stopped"
  private var bootstrapPct: Int = 0

  /// tor's own name for the phase bootstrap is in (`conn_dir`,
  /// `loading_descriptors`, …) and its one-line summary of it. Held so a
  /// `status()` call and a late subscriber see the same phase the last
  /// event carried, and so Dart can show it rather than a bare percentage.
  private var bootstrapTag: String?
  private var bootstrapSummary: String?

  /// tor's own log file for the current run, and how much of it has been
  /// forwarded already.
  private var logFileURL: URL?
  private var logFileOffset: UInt64 = 0
  private var logPumpRunning = false

  /// The SOCKS endpoint as read at attach, promoted to [socksHost] /
  /// [socksPort] only once bootstrap finishes. Held apart so a status
  /// published mid-bootstrap never carries an endpoint that nothing can
  /// route through yet (TOR-008 fails closed on exactly that).
  private var pendingSocksHost: String?
  private var pendingSocksPort: Int?

  private var socksHost: String?
  private var socksPort: Int?
  private var lastError: String?

  /// Guards against a second `start()` while one is already in flight —
  /// two TorThreads in one process fight over the data directory.
  private var starting = false

  private var sink: FlutterEventSink?

  init(messenger: FlutterBinaryMessenger) {
    self.channel = FlutterMethodChannel(
      name: "org.codeberg.theoden8.webspace/tor",
      binaryMessenger: messenger
    )
    self.eventChannel = FlutterEventChannel(
      name: "org.codeberg.theoden8.webspace/tor/events",
      binaryMessenger: messenger
    )
    self.logChannel = FlutterEventChannel(
      name: "org.codeberg.theoden8.webspace/tor/logs",
      binaryMessenger: messenger
    )
    super.init()
    self.channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    self.eventChannel.setStreamHandler(self)
    self.logChannel.setStreamHandler(self.logRelay)
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      start()
      result(nil)
    case "stop":
      stop()
      result(nil)
    case "status":
      stateQueue.async { [weak self] in
        guard let self = self else { result(nil); return }
        let snapshot = self.snapshotLocked()
        DispatchQueue.main.async { result(snapshot) }
      }
    case "rebuildCircuits":
      rebuildCircuits()
      result(nil)
    case "setTorrcOptions":
      let args = call.arguments as? [String: Any]
      // [[key, value], ...]. Anything that is not a two-element pair of
      // strings is dropped rather than crashing the start path.
      let pairs = (args?["options"] as? [[String]] ?? []).compactMap {
        $0.count == 2 ? ($0[0], $0[1]) : nil
      }
      stateQueue.async { [weak self] in
        self?.pendingTorrcOptions = pairs
        DispatchQueue.main.async { result(nil) }
      }
    case "setSocksIsolation":
      let isolate =
        (call.arguments as? [String: Any])?["isolateDestAddr"] as? Bool ?? true
      setSocksIsolation(isolate, result: result)
    case "startTransport":
      let name = (call.arguments as? [String: Any])?["transport"] as? String ?? ""
      startTransport(name, result: result)
    case "setExitCountry":
      let args = call.arguments as? [String: Any]
      setExitCountry(
        args?["exitNodes"] as? String,
        geoipFile: args?["geoipFile"] as? String,
        result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Lifecycle

  private func start() {
    stateQueue.async { [weak self] in
      guard let self = self else { return }
      guard !self.starting, self.thread == nil else { return }
      self.starting = true
      self.lastError = nil
      self.generation += 1
      self.publishLocked(state: "starting", pct: 0)
      self.note("Starting tor.")
      self.launchWhenFreeLocked(generation: self.generation, attempt: 0)
    }
  }

  /// Wait for a previous tor to be gone, then launch.
  ///
  /// tor runs at most once per process. `TORThread` asserts a single
  /// instance outright, and two `tor_run_main`s in one address space fight
  /// over the data-directory lock — which tor resolves by exiting the
  /// process it is linked into, taking the app with it. `stop()` asks tor
  /// to exit over the control port, but the thread keeps running until
  /// tor's own main loop returns, so a restart has to wait for that rather
  /// than race it. Retry, the idle stop, and a bootstrap timeout all put a
  /// start and a stop within seconds of each other.
  private func launchWhenFreeLocked(generation: Int, attempt: Int) {
    guard starting, generation == self.generation else { return }
    if let exiting = exitingThread, !exiting.isFinished {
      guard attempt < kTorThreadExitAttempts else {
        // Every shutdown request went unanswered, so this process cannot
        // run another tor. A named failure with the one remedy left,
        // rather than the crash that starting a second one would be. The
        // wording keeps "control port" so it classifies as a control-
        // channel failure rather than as tor having stopped.
        failLocked(
          "The previous Tor is still running: its control port did not answer a "
            + "shutdown request, so a new one cannot start. Restarting the app clears it.")
        return
      }
      if attempt == 0 { note("Waiting for the previous tor to exit.") }
      stateQueue.asyncAfter(deadline: .now() + kTorThreadExitPoll) { [weak self] in
        self?.launchWhenFreeLocked(generation: generation, attempt: attempt + 1)
      }
      return
    }
    exitingThread = nil
    exitingConfiguration = nil
    // Once per process, and once only. A previous tor that has exited frees
    // the slot Tor.framework guards, but not tor's own global state: the
    // second `tor_run_main` reaches `threadpool_new` with the pool already
    // built, hits its BUG() and logs "Can't create worker thread pool", and
    // the bootstrap that follows never progresses. Before this check that
    // was a three-minute wait ending in `bootstrapTimeout`, which reads as
    // "Tor could not reach the network" -- a failure the user would retry,
    // burning the same dead path again.
    guard !hasLaunched else {
      failLocked(
        "Tor has already run once in this app session and cannot be started "
          + "again: tor keeps state that only exits with the process. "
          + "Restarting the app makes Tor available again.")
      return
    }
    launchLocked(generation: generation)
  }

  /// Hand the running tor to the exit watch and start asking it to quit.
  ///
  /// Shared by the stop path and by a failure that leaves the runtime
  /// unusable: a tor nobody can talk to must not keep sitting in the
  /// process's one slot (TOR-020). Bumps the generation, so a handshake
  /// still in flight for that run cannot adopt it afterwards.
  private func retireRunningLocked() {
    generation += 1
    guard let thread = thread else {
      configuration = nil
      return
    }
    exitingThread = thread
    exitingConfiguration = configuration
    self.thread = nil
    configuration = nil
    haltExitingLocked(attempt: 0)
  }

  /// Keep asking the tor that is on its way out to quit, until its thread
  /// is gone.
  ///
  /// The `disconnect()` on the stop path only reaches a tor whose control
  /// port we adopted, and often we have none: a runtime stopped before the
  /// handshake landed, or one whose handshake failed, never had a
  /// controller, and nothing else in the process can ask that tor to quit.
  /// It then runs until the app is killed, and because only one tor may run
  /// per process every later start refuses (TOR-020) — which is what the
  /// Retry button turned into for a user whose first bootstrap failed. A
  /// fresh control connection works in both cases, and repeats because the
  /// control port may not be open yet when the stop lands.
  private func haltExitingLocked(attempt: Int) {
    guard let thread = exitingThread, let config = exitingConfiguration else { return }
    guard !thread.isFinished else {
      exitingConfiguration = nil
      return
    }
    guard attempt < kTorHaltRetries else {
      note("The previous tor has not exited after \(attempt) shutdown requests.")
      return
    }
    attachQueue.async { [weak self] in self?.halt(config) }
    stateQueue.asyncAfter(deadline: .now() + kTorHaltRetryDelay) { [weak self] in
      self?.haltExitingLocked(attempt: attempt + 1)
    }
  }

  /// A live control connection to [portFile], or nil if there is none.
  ///
  /// `TORController(controlPortFile:)` opens the connection inside its own
  /// initializer, and `connect()` answers an already-connected controller
  /// with a bare NO and no error written — which Swift raises as
  /// "The operation couldn't be completed. (Foundation._GenericObjCError
  /// error 0.)", the same thing it raises for a port file that does not
  /// parse. So connecting a second time turns every success into that
  /// error, and the two cases cannot be told apart from the throw. Ask
  /// `isConnected`, which means what it says (BUG-013).
  /// `host:port` from tor's control-port file, or nil while it is absent,
  /// empty or half-written.
  ///
  /// Mirrors the framework's own parse (split on `=`, then on `:`) so that
  /// anything this accepts, its initializer also accepts.
  static func parseControlPortFile(_ portFile: URL) -> (host: String, port: UInt16)? {
    guard let content = try? String(contentsOf: portFile, encoding: .utf8) else {
      return nil
    }
    let value = content.components(separatedBy: "=").last?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let parts = value.components(separatedBy: ":")
    guard parts.count == 2, !parts[0].isEmpty,
          let port = UInt16(parts[1]), port > 0
    else { return nil }
    return (parts[0], port)
  }

  private static func connectedController(to portFile: URL) -> TorController? {
    // Read the file ourselves first. `TORController(controlPortFile:)` reads
    // it inside its initializer and `NSAssert`s on one that is missing or
    // does not parse. A release build compiles those out and hands back a
    // controller with a nil host; a debug build -- which is every
    // integration run -- raises and the process aborts. tor writes this file
    // when its listener is up, so every attach before that would abort.
    guard parseControlPortFile(portFile) != nil else { return nil }
    let controller = TorController(controlPortFile: portFile)
    if controller.isConnected { return controller }
    try? controller.connect()
    return controller.isConnected ? controller : nil
  }

  /// Connect to [config]'s control port and ask tor to quit.
  ///
  /// Best effort on every step, and every step says why it failed: an
  /// orphan that will not die is the difference between Retry working and
  /// Retry being dead for the rest of the process, and "it did not work"
  /// is not something a bug report can act on.
  ///
  /// HALT (SIGTERM) rather than SHUTDOWN (SIGINT): SHUTDOWN waits
  /// `ShutdownWaitLength` when tor believes it is a server, HALT never
  /// does. The `disconnect()` after it sends SHUTDOWN as well, which covers
  /// a tor that does not recognise HALT.
  private func halt(_ config: TorConfiguration) {
    guard let portFile = config.controlPortFile else {
      note("The previous tor published no control port; it cannot be asked to quit.")
      return
    }
    guard let controller = Self.connectedController(to: portFile) else {
      note("The previous tor's control port is not answering yet.")
      return
    }
    guard let cookie = config.cookie else {
      note("The previous tor's control cookie is unreadable; it cannot be asked to quit.")
      controller.disconnect()
      return
    }
    controller.authenticate(with: cookie) { [weak self] success, error in
      guard success else {
        self?.note(
          "The previous tor refused the control cookie: "
            + (error?.localizedDescription ?? "no reason given"))
        controller.disconnect()
        return
      }
      controller.sendCommand("SIGNAL", arguments: ["HALT"], data: nil) { _, _, stop in
        stop.pointee = true
        self?.note("Asked the previous tor to quit.")
        controller.disconnect()
        return true
      }
    }
  }

  private func launchLocked(generation: Int) {
    hasLaunched = true
    let config = TorConfiguration()
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Tor", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    config.dataDirectory = base
    config.cookieAuthentication = true
    config.autoControlPort = true
    // Client only: this app is never a relay, a bridge, or a hidden
    // service host, and saying so keeps tor from opening anything it
    // does not need.
    config.clientOnly = true
    config.avoidDiskWrites = true
    config.ignoreMissingTorrc = true
    config.options = [
      "SocksPort": Self.socksPortValue(isolateDestAddr: pendingIsolateDestAddr),
      "SafeLogging": "1",
    ]
    // tor's own log, which `TORConfiguration` turns into
    // `--Log notice file <path>`. It goes to a file rather than to the
    // control port because a tor that never opens a control port is exactly
    // the case that needs explaining (TOR-018). Truncated here and removed
    // on stop, so it never outlives the run that wrote it.
    let logFile = base.appendingPathComponent(kTorLogFileName)
    try? FileManager.default.removeItem(at: logFile)
    config.logfile = logFile
    logFileURL = logFile
    logFileOffset = 0
    // Bridges go through `arguments`, not `options`: TORConfiguration
    // compiles `options` from a dictionary, so a repeated `Bridge` key
    // would collapse to whichever line hashed last. `arguments` is
    // appended verbatim, which is what a repeatable torrc key needs.
    //
    // Wrapped rather than assigned: `arguments` is typed NSMutableArray,
    // which takes an array *literal* but not a `[String]` value, so the
    // flatMap result has to be boxed explicitly.
    config.arguments = NSMutableArray(
      array: pendingTorrcOptions.flatMap { ["--\($0.0)", $0.1] })
    configuration = config

    let thread = TorThread(configuration: config)
    self.thread = thread
    thread.start()
    note(
      pendingTorrcOptions.isEmpty
        ? "Tor thread started with no bridges configured."
        : "Tor thread started with \(pendingTorrcOptions.count) extra torrc option(s).")
    startLogPumpLocked()

    attachLocked(config, thread: thread, generation: generation, attempt: 0)
  }

  /// One attempt to reach tor's control port, scheduled from the state
  /// queue and carried out on `attachQueue`.
  ///
  /// A loop of short attempts rather than one blocking retry run: tor opens
  /// its control port when the device lets it, and the previous budget
  /// (three tries inside 1.5 seconds) failed runs that would have been fine
  /// a second later. Each attempt re-checks the run it belongs to, so a
  /// stop during the wait costs nothing and a later run is never queued
  /// behind an abandoned one.
  ///
  /// [thread] is passed rather than read off the shared property: it is the
  /// one piece of the run this queue may look at, and `isFinished` on an
  /// NSThread is safe from any thread (BUG-007).
  private func attachLocked(
    _ config: TorConfiguration, thread: TorThread, generation: Int, attempt: Int
  ) {
    guard starting, generation == self.generation else { return }
    guard !thread.isFinished else {
      // A tor that is already gone did not refuse the connection, it
      // rejected its own configuration and exited — which it does before
      // the control port exists, so its reason is not on any surface this
      // app can read. Naming the difference is the only diagnosis
      // available, and a bad bridge line is what usually causes it.
      failLocked(
        "Tor exited before opening its control port: it rejected its configuration. "
          + "A bridge line is the usual cause.",
        generation: generation)
      return
    }
    let waited = Double(attempt) * kTorAttachPoll
    guard let portFile = config.controlPortFile else {
      failLocked("Tor did not publish a control port.", generation: generation)
      return
    }
    // Which side of the line we are on: tor has not written its port file
    // (so it never reached its listeners), or it has and the port will not
    // accept us. The framework cannot tell these apart — a missing file
    // fails its connect the same opaque way — and they are different bugs.
    let published = FileManager.default.fileExists(atPath: portFile.path)
    guard attempt < kTorAttachAttempts else {
      failLocked(
        "Could not reach the Tor control port after \(Int(waited)) seconds "
          + "(tor \(published ? "published one" : "never wrote its port file")).",
        generation: generation)
      return
    }
    if attempt > 0, attempt % 10 == 0 {
      note(
        "Still waiting for tor's control port (\(Int(waited))s); port file "
          + "\(published ? "written" : "not written yet"), thread "
          + "\(thread.isExecuting ? "running" : "not running").")
    }

    attachQueue.async { [weak self] in
      guard let self = self else { return }
      let retry = {
        self.stateQueue.asyncAfter(deadline: .now() + kTorAttachPoll) {
          self.attachLocked(
            config, thread: thread, generation: generation, attempt: attempt + 1)
        }
      }
      // Not a failure when this comes back nil: the port file may not be
      // written yet, or the listener may not be accepting. Both resolve
      // themselves.
      guard let controller = Self.connectedController(to: portFile) else {
        retry()
        return
      }
      // The cookie lands with the port, not before it, so an unreadable one
      // here is the same timing artifact as a refused connection.
      guard let cookie = config.cookie else {
        controller.disconnect()
        retry()
        return
      }
      self.note("Control port answered after \(Int(waited))s; authenticating.")
      controller.authenticate(with: cookie) { [weak self] _, error in
        guard let self = self else { return }
        self.stateQueue.async {
          // A stop() may have landed while this handshake was in flight. Its
          // teardown already ran, so adopting this controller now would leave
          // a live control connection attached to a runtime nobody is
          // tracking — the resurrection half of BUG-007.
          //
          // Disconnecting rather than merely dropping it: `disconnect()`
          // sends SIGNAL SHUTDOWN, and for a tor that was stopped before its
          // control port answered, this handshake is the only thing that can
          // still ask it to exit.
          guard self.starting, generation == self.generation else {
            controller.disconnect()
            return
          }
          // Publishing the controller happens here, on the queue that owns it.
          self.controller = controller
          if let error = error {
            self.failLocked(
              "Tor control authentication failed: \(error.localizedDescription)",
              generation: generation)
            return
          }
          self.note("Control port authenticated.")
          self.observeLocked(controller, generation: generation)
        }
      }
    }
  }

  /// Read what this run needs, then subscribe to events — in that order.
  ///
  /// Every reply and every asynchronous event share one observer list in
  /// Tor.framework, and its `GETINFO` observer answers the first line it is
  /// handed, an unrelated event included, reporting that back as an empty
  /// result. With events already flowing, a bootstrap notice landing in the
  /// same window is what made `net/listeners/socks` come back empty and a
  /// finished bootstrap report "no usable SOCKS listener" — or, worse, made
  /// the framework drop its own circuit-established observer, so the app
  /// sat on the interstitial through a bootstrap that had already
  /// succeeded. Reading on a quiet connection removes the window.
  private func observeLocked(_ controller: TorController, generation: Int) {
    Task { [weak self] in
      guard let self = self else { return }
      var listeners = await controller.info(forKeys: ["net/listeners/socks"])
      if TorControllerPlugin.parseSocksEndpoint(listeners.first) == nil {
        // tor opens its listeners before it writes the control-port file,
        // so an empty read here is a timing artifact; one retry covers it.
        try? await Task.sleep(nanoseconds: 250_000_000)
        listeners = await controller.info(forKeys: ["net/listeners/socks"])
      }
      let endpoint = TorControllerPlugin.parseSocksEndpoint(listeners.first)
      let phase = await controller.info(forKeys: ["status/bootstrap-phase"])
      let bootstrap = phase.first.flatMap(TorControllerPlugin.parseBootstrapPhase)

      self.stateQueue.async {
        guard self.starting, generation == self.generation else { return }
        if let endpoint = endpoint {
          self.pendingSocksHost = endpoint.host
          self.pendingSocksPort = endpoint.port
        } else {
          self.note("Tor has not opened a SOCKS listener yet.")
        }
        self.subscribeLocked(controller)

        // Whatever happened before the control port was reachable. tor can
        // be several phases in by the time the handshake lands — or already
        // done, in which case no further event is coming and only this says
        // so.
        guard let bootstrap = bootstrap else { return }
        self.note("Bootstrap was at \(bootstrap.pct)% when the control port attached.")
        if bootstrap.pct >= self.bootstrapPct {
          self.publishLocked(
            state: "bootstrapping", pct: bootstrap.pct,
            tag: bootstrap.tag, summary: bootstrap.summary)
        }
        if bootstrap.pct >= 100 { self.finishLocked() }
      }
    }
  }

  private func subscribeLocked(_ controller: TorController) {
    // `addObserver(forCircuitEstablished:)` is deliberately not used: it
    // sends its own SETEVENTS and follows it with a GETINFO that an
    // asynchronous event can answer first, after which it removes itself
    // and CIRCUIT_ESTABLISHED is never delivered again (TOR-019). The
    // status observer below handles that action instead.
    controller.listen(forEvents: kTorControlEvents) { _, _ in }

    statusObserver = controller.addObserver(forStatusEvents: {
      [weak self] (type, _, action, arguments) -> Bool in
      guard let self = self else { return false }
      guard type == "STATUS_CLIENT" else { return false }
      // The Bool is "I handled this event", not "stop observing".
      switch action {
      case "BOOTSTRAP":
        let pct = Int(arguments?["PROGRESS"] ?? "") ?? 0
        let tag = arguments?["TAG"]
        let summary = arguments?["SUMMARY"]
        self.stateQueue.async {
          // Never walk backwards, and never overwrite a terminal state with
          // a stale in-flight event.
          guard self.state == "starting" || self.state == "bootstrapping" else { return }
          guard pct >= self.bootstrapPct else { return }
          self.publishLocked(
            state: "bootstrapping", pct: pct, tag: tag, summary: summary)
          // tor's own "done". Belt to CIRCUIT_ESTABLISHED's braces: the two
          // fire within a moment of each other and either one is enough.
          if pct >= 100 { self.finishLocked() }
        }
        return true
      case "CIRCUIT_ESTABLISHED":
        self.stateQueue.async { self.finishLocked() }
        return true
      default:
        return false
      }
    })
  }

  /// Bootstrap is done: publish the endpoint read at attach.
  ///
  /// Idempotent, because both CIRCUIT_ESTABLISHED and `BOOTSTRAP
  /// PROGRESS=100` lead here, as does a catch-up read that finds tor
  /// already finished.
  private func finishLocked() {
    guard state == "starting" || state == "bootstrapping" else { return }
    guard let host = pendingSocksHost, let port = pendingSocksPort else {
      failLocked("Tor reported no usable SOCKS listener.")
      return
    }
    // Bootstrap is over; the status observer has nothing left to say, and
    // the subscription goes with it (TOR-019). That makes the connection
    // quiet again, which is what lets an exit-country change read from it
    // later: with events flowing, one can land in a GETINFO's reply slot.
    // tor's log comes from its file, so nothing else rides the events.
    if let observer = statusObserver { controller?.removeObserver(observer) }
    statusObserver = nil
    controller?.listen(forEvents: []) { _, _ in }

    socksHost = host
    socksPort = port
    starting = false
    publishLocked(state: "up", pct: 100)
    note("Connected. SOCKS listener on \(host):\(port).")
  }

  /// `"127.0.0.1:41337"`, sometimes quoted. A `unix:/path` form can only
  /// appear if someone sets `socksURL`, which we never do.
  static func parseSocksEndpoint(_ raw: String?) -> (host: String, port: Int)? {
    let trimmed = raw?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? ""
    let parts = trimmed.split(separator: ":")
    guard parts.count == 2, let port = Int(parts[1]), port > 0 else { return nil }
    return (String(parts[0]), port)
  }

  /// Split a control-port async event line into a log severity and its
  /// message, or nil when it is not a log event. A `STATUS_*` line is one
  /// such: it belongs to the status observer, not the log.
  static func parseLogEvent(_ line: String) -> (severity: String, message: String)? {
    for severity in ["NOTICE", "WARN", "ERR"] {
      guard line.hasPrefix(severity) else { continue }
      let rest = line.dropFirst(severity.count)
      if rest.isEmpty { return (severity.lowercased(), "") }
      guard rest.hasPrefix(" ") else { continue }
      return (severity.lowercased(), String(rest.dropFirst()))
    }
    return nil
  }

  /// Parse `NOTICE BOOTSTRAP PROGRESS=45 TAG=loading_descriptors
  /// SUMMARY="Loading relay descriptors"`, the form `GETINFO
  /// status/bootstrap-phase` answers with.
  static func parseBootstrapPhase(_ line: String)
    -> (pct: Int, tag: String?, summary: String?)?
  {
    guard line.contains("BOOTSTRAP") else { return nil }
    let fields = parseKeyValues(line)
    guard let progress = fields["PROGRESS"], let pct = Int(progress) else { return nil }
    return (pct, fields["TAG"], fields["SUMMARY"])
  }

  /// `KEY=value KEY="quoted value"` pairs off one control-port line. Bare
  /// words are skipped. Quoted so a `SUMMARY` keeps its spaces, which is
  /// the whole reason this is not a `split(separator: " ")`.
  static func parseKeyValues(_ line: String) -> [String: String] {
    var fields: [String: String] = [:]
    var key = ""
    var value = ""
    var readingKey = true
    var quoted = false
    var escaped = false

    func flush() {
      if !readingKey, !key.isEmpty { fields[key] = value }
      key = ""
      value = ""
      readingKey = true
      quoted = false
    }

    for character in line {
      if readingKey {
        switch character {
        case "=": readingKey = false
        case " ": key = ""
        default: key.append(character)
        }
        continue
      }
      if escaped {
        value.append(character)
        escaped = false
        continue
      }
      switch character {
      case "\\" where quoted:
        escaped = true
      case "\"":
        if quoted {
          flush()
        } else if value.isEmpty {
          quoted = true
        }
      case " " where !quoted:
        flush()
      default:
        value.append(character)
      }
    }
    flush()
    return fields
  }

  /// Forward whatever tor has written to its log since the last poll.
  ///
  /// A poll rather than a file-system event source: the file is written by
  /// a thread in this process, a second is fine for reading a log a human
  /// looks at, and there is nothing to leak if the run dies mid-line.
  private func startLogPumpLocked() {
    guard !logPumpRunning else { return }
    logPumpRunning = true
    pumpLogLocked()
  }

  private func pumpLogLocked() {
    if let url = logFileURL, let handle = try? FileHandle(forReadingFrom: url) {
      defer { try? handle.close() }
      try? handle.seek(toOffset: logFileOffset)
      if let data = try? handle.readToEnd(), !data.isEmpty {
        logFileOffset += UInt64(data.count)
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n") where !line.isEmpty {
          let entry = TorControllerPlugin.parseTorLogLine(String(line))
          logRelay.emit(source: "tor", severity: entry.severity, message: entry.message)
        }
      }
    }
    guard state != "stopped" else {
      logPumpRunning = false
      return
    }
    stateQueue.asyncAfter(deadline: .now() + kTorLogPollInterval) { [weak self] in
      self?.pumpLogLocked()
    }
  }

  /// Split one of tor's log lines into a severity and its message.
  ///
  /// `Sep 15 16:29:42.123 [notice] Opening Socks listener on 127.0.0.1:0`.
  /// The timestamp goes: every entry in the app log already carries one.
  static func parseTorLogLine(_ line: String) -> (severity: String, message: String) {
    guard let open = line.firstIndex(of: "["),
      let close = line[open...].firstIndex(of: "]")
    else { return ("notice", line) }
    let level = String(line[line.index(after: open)..<close])
    let rest = String(line[line.index(after: close)...])
      .trimmingCharacters(in: .whitespaces)
    let message = rest.isEmpty ? line : rest
    switch level {
    case "err": return ("err", message)
    case "warn": return ("warn", message)
    default: return ("notice", message)
    }
  }

  /// One line of the plugin's own lifecycle, for the window tor's log
  /// cannot describe: before the control port answers, and after it goes.
  private func note(_ message: String) {
    logRelay.emit(source: "plugin", severity: "notice", message: message)
  }

  private func stop() {
    // Outside the stateQueue hop: the transports are owned by ptQueue and
    // nothing on the tor teardown path reads them. A restart's stop and the
    // startTransport that follows it land on that one serial queue in the
    // order they were issued, which is what makes the transport come back
    // on a fresh port rather than a stale one.
    stopTransports()
    stateQueue.async { [weak self] in
      guard let self = self else { return }
      // Idempotent: a stop racing the idle-stop timer must not double-free
      // the controller or hand the same thread to the exit watch twice
      // (BUG-007).
      if let observer = self.statusObserver { self.controller?.removeObserver(observer) }
      self.statusObserver = nil
      if self.thread != nil {
        self.note(
          self.controller == nil
            ? "Stopping tor; its control port never answered, so the shutdown goes over a fresh connection."
            : "Stopping tor.")
      }
      // `disconnect()` sends SIGNAL SHUTDOWN over the controller we
      // adopted, which for a client makes tor exit immediately. That is not
      // the whole stop, because we often have no controller to send it
      // over — see haltExitingLocked. `cancel()` is not part of it at all:
      // on an NSThread it only sets a flag that tor's main loop never
      // reads, so the thread is handed to `exitingThread` and the next
      // start waits for it rather than spawning a second tor.
      self.controller?.disconnect()
      self.controller = nil
      self.retireRunningLocked()
      self.pendingSocksHost = nil
      self.pendingSocksPort = nil
      self.socksHost = nil
      self.socksPort = nil
      self.starting = false
      self.publishLocked(state: "stopped", pct: 0)
      // After the last pump, so nothing tor wrote on its way out is lost.
      self.pumpLogLocked()
      if let url = self.logFileURL { try? FileManager.default.removeItem(at: url) }
      self.logFileURL = nil
      self.logFileOffset = 0
    }
  }

  // MARK: - Pluggable transports

  /// Start `name` and answer with the loopback port its SOCKS listener
  /// bound to, or 0.
  ///
  /// 0 rather than an error on every failure path, because Dart's contract
  /// is "0 means no transport": the engine turns that into an empty option
  /// list and tor comes up without bridges, which on an uncensored network
  /// still works. Throwing here would instead abort the whole start.
  private func startTransport(_ name: String, result: @escaping FlutterResult) {
    guard !name.isEmpty else { result(0); return }
    ptQueue.async { [weak self] in
      guard let self = self else {
        DispatchQueue.main.async { result(0) }
        return
      }
      let answer: (Int) -> Void = { port in
        DispatchQueue.main.async { result(port) }
      }

      if self.ptController == nil {
        // Not the Tor data directory: IPtProxy writes transport state and
        // its own log here, and pointing it at tor's would put two
        // processes' state in one place.
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
          .appendingPathComponent("PluggableTransports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Logging off and the address scrubber on: the transport log would
        // otherwise record which bridges this device dials, in the clear,
        // in the app container.
        self.ptController = IPtProxyController(
          dir.path, enableLogging: false, unsafeLogging: false,
          logLevel: "ERROR", transportEvents: nil)
      }
      guard let controller = self.ptController else { answer(0); return }

      // Idempotent: acquire and restart both apply the bridge config, and
      // starting a running transport throws rather than returning the port
      // it already has.
      if !self.startedTransports.contains(name) {
        do {
          // No proxy: an upstream proxy in front of the transport is a
          // configuration this app does not offer, and snowflake and dnstt
          // reject one outright.
          try controller.start(name, proxy: nil)
          self.startedTransports.insert(name)
        } catch {
          self.note("Pluggable transport \(name) failed to start; continuing without bridges.")
          answer(0)
          return
        }
      }
      let port = controller.port(name)
      self.note("Pluggable transport \(name) listening on port \(port).")
      answer(port)
    }
  }

  private func stopTransports() {
    ptQueue.async { [weak self] in
      guard let self = self else { return }
      for name in self.startedTransports {
        self.ptController?.stop(name)
      }
      self.startedTransports.removeAll()
    }
  }

  // MARK: - Exit country

  /// tor's `SocksPort` line for [isolateDestAddr].
  ///
  /// `auto` lets tor pick a free loopback port and report it back. Never
  /// 9050: another tor-embedding app (Onion Browser) may already own it,
  /// and binding a fixed port is how a user's traffic ends up at whatever
  /// else answers there.
  ///
  /// IsolateSOCKSAuth is on by default per tor(1), but written out so the
  /// isolation contract is legible here rather than inherited from an
  /// upstream default that could change (TOR-003).
  ///
  /// IsolateDestAddr splits circuits per destination *address* as well, so
  /// one site loading from two hosts exits from two relays. That is more
  /// isolation than per-site, and it shows: a page whose own API lives on a
  /// second host reports two different addresses while it loads, and a
  /// session that checks its client IP across hosts breaks. It also costs a
  /// circuit build per host, which a page pulling from a dozen of them pays
  /// on first load.
  ///
  /// Off by default. Per-site isolation is the contract and IsolateSOCKSAuth
  /// alone delivers it; this extra split buys only that no single exit sees a
  /// whole page load, and it hid BUG-014's dropped credential by keeping some
  /// isolation alive when the per-site key was gone.
  static func socksPortValue(isolateDestAddr: Bool) -> String {
    isolateDestAddr
      ? "auto IsolateSOCKSAuth IsolateDestAddr" : "auto IsolateSOCKSAuth"
  }

  /// Record the isolation the user chose. It reaches tor at the next start.
  ///
  /// Not a live `SETCONF`, and not a restart, because neither works:
  ///
  ///  * A restart is impossible. tor keeps process-global state its own
  ///    `tor_run_main` does not reset, so a second launch dies in
  ///    `threadpool_new` ("Can't create worker thread pool") and never
  ///    bootstraps. Tor.framework says the same thing from the other side:
  ///    `TORThread` asserts there can only be one per process.
  ///  * `SETCONF SocksPort="auto ..."` is accepted and changes nothing. On a
  ///    config transition tor runs `retry_listener_ports`, which treats a
  ///    `CFG_AUTO_PORT` request as matching any existing listener on that
  ///    address and keeps it ("This listener is already running"). The
  ///    isolation flags live on the listener's `entry_cfg`, copied once in
  ///    `connection_listener_new`, so a kept listener keeps the old flags
  ///    and tor still answers 250 OK.
  ///
  /// So the honest contract is the next start, and the UI says so.
  private func setSocksIsolation(
    _ isolateDestAddr: Bool, result: @escaping FlutterResult
  ) {
    stateQueue.async { [weak self] in
      self?.pendingIsolateDestAddr = isolateDestAddr
      DispatchQueue.main.async { result(nil) }
    }
  }

  /// Apply or clear the `ExitNodes` pin (TOR-014).
  ///
  /// Failure is reported to Dart rather than swallowed: the engine treats a
  /// throw as "the pin did not land", and a pin silently not in force would
  /// have the user believe traffic leaves from a country it does not.
  ///
  /// A country pin needs GeoIP, which this app does not ship (LICENSE-002):
  /// Dart downloads it and hands over [geoipFile]. tor resolves `{cc}` only
  /// against a loaded GeoIP table, and without one the pin matches no relay
  /// at all. So the file goes in first, and the pin only once tor reports
  /// the table loaded; tor's `ExitNodes` is never a country it cannot read.
  ///
  /// Always answers, and exactly once (BUG-018). Tor.framework registers a
  /// command's reply observer only after a clean write, so a command written
  /// to a dead control socket never completes, and the Dart side used to
  /// wait on it for good. Every step here is bounded, the whole call has a
  /// deadline, and a control connection that stopped answering is replaced
  /// before the change is attempted.
  private func setExitCountry(
    _ exitNodes: String?, geoipFile: String?, result: @escaping FlutterResult
  ) {
    let answer = OneShotResult(result)
    DispatchQueue.global().asyncAfter(deadline: .now() + kTorExitCountryTimeout) {
      answer.send(FlutterError(
        code: "control_timeout",
        message: "Tor's control port did not answer the exit-country change within "
          + "\(Int(kTorExitCountryTimeout)) seconds, so it is not in force.",
        details: nil))
    }
    stateQueue.async { [weak self] in
      guard let self = self else {
        answer.send(FlutterError(code: "tor_not_up", message: "Tor is gone.", details: nil))
        return
      }
      guard let controller = self.controller, self.state == "up" else {
        answer.send(FlutterError(
          code: "tor_not_up",
          message: "Tor is not connected, so the exit-country pin was not applied.",
          details: nil))
        return
      }
      let generation = self.generation
      Task {
        guard let live = await self.liveController(controller, generation: generation) else {
          answer.send(FlutterError(
            code: "control_unreachable",
            message: "Tor's control port stopped answering and could not be re-attached, "
              + "so the exit-country change is not in force.",
            details: nil))
          return
        }
        answer.send(await self.applyExitCountry(
          exitNodes, geoipFile: geoipFile, controller: live))
      }
    }
  }

  /// A controller that answers: [controller] if it does, otherwise a fresh
  /// connection that replaces it. Nil when neither will.
  ///
  /// `isConnected` cannot say. TORController drops its channel only when the
  /// channel is closed, and nothing closes it when the socket dies, so a
  /// socket iOS reclaimed while the app was suspended still reads as
  /// connected. Asking is the only test. The old controller is dropped,
  /// never `disconnect()`ed: that sends SIGNAL SHUTDOWN, and a socket that
  /// was only slow would carry it to tor. tor takes no ownership from its
  /// control connections, so losing one leaves it running.
  ///
  /// The swap happens on `stateQueue` and only for the run that asked, and
  /// only if nothing replaced the controller first (BUG-007).
  private func liveController(
    _ controller: TorController, generation: Int
  ) async -> TorController? {
    if await Self.controlRead(controller, ["version"], within: kTorControlProbeTimeout) != nil {
      return controller
    }
    note("Tor's control port stopped answering; re-attaching.")
    let config: TorConfiguration? = await withCheckedContinuation { done in
      stateQueue.async {
        done.resume(returning: generation == self.generation ? self.configuration : nil)
      }
    }
    guard let portFile = config?.controlPortFile, let cookie = config?.cookie else {
      return nil
    }
    let fresh: TorController? = await withCheckedContinuation { done in
      attachQueue.async { done.resume(returning: Self.connectedController(to: portFile)) }
    }
    guard let fresh = fresh else {
      note("Tor's control port did not accept a new connection.")
      return nil
    }
    let authenticated = await Self.reply(within: kTorControlReplyTimeout) {
      (answer: @escaping (Bool) -> Void) in
      fresh.authenticate(with: cookie) { success, _ in answer(success) }
    }
    guard authenticated == true else {
      note("Tor refused the control cookie on re-attach.")
      return nil
    }
    return await withCheckedContinuation { done in
      stateQueue.async {
        guard generation == self.generation, self.state == "up" else {
          done.resume(returning: nil)
          return
        }
        if self.controller === controller {
          self.controller = fresh
          self.note("Re-attached to Tor's control port.")
        }
        done.resume(returning: self.controller)
      }
    }
  }

  /// The pin itself, as one sequence. Nil on success.
  private func applyExitCountry(
    _ exitNodes: String?, geoipFile: String?, controller: TorController
  ) async -> FlutterError? {
    func check(_ outcome: (Bool, Error?)?) -> FlutterError? {
      guard let outcome = outcome else {
        return FlutterError(
          code: "control_timeout",
          message: "Tor's control port did not answer a command of the exit-country "
            + "change, so it is not in force.",
          details: nil)
      }
      let (success, error) = outcome
      if success { return nil }
      return FlutterError(
        code: "setconf_failed",
        message: error?.localizedDescription ?? "Tor refused the exit-country pin.",
        details: nil)
    }

    guard let exitNodes = exitNodes, !exitNodes.isEmpty else {
      // Clearing takes two commands: RESETCONF puts ExitNodes back to no
      // pin at all, and StrictNodes has to be turned off separately or
      // tor keeps enforcing an empty set. Conflux goes back to tor's own
      // default with it.
      //
      // StrictNodes goes through setConfs rather than the single-key
      // setter: `setConfForKey:withValue:` starts with `set`, so Swift
      // imports it whole rather than splitting off `forKey:`, and the
      // split spelling does not exist. setConfs needs no such guess.
      if let failed = check(await Self.resetConf(controller, key: "ExitNodes")) {
        return failed
      }
      if let failed = check(await Self.setConfs(controller, Self.exitPinClearConfigs)) {
        return failed
      }
      await closeExitCircuits(controller)
      return nil
    }

    // Loading is tor's own: a SETCONF to a path it has not read yet makes
    // it parse the file and re-resolve every relay's country. A path it
    // already read is not re-read, which is why Dart names each download
    // afresh rather than overwriting one file.
    if let geoipFile = geoipFile, !geoipFile.isEmpty,
       let failed = check(
         await Self.setConfs(controller, [["key": "GeoIPFile", "value": geoipFile]]))
    {
      return failed
    }
    guard await Self.geoipAvailable(controller) else {
      return FlutterError(
        code: "geoip_unavailable",
        message: "Tor has no GeoIP data loaded, so the exit-country pin cannot "
          + "resolve a country. The pin was not applied.",
        details: nil)
    }

    if let failed = check(await Self.setConfs(controller, Self.exitPinConfigs(exitNodes))) {
      return failed
    }
    await closeExitCircuits(controller)
    // A country with no exit takes the pin without complaint, and then tor
    // builds no circuit at all: its path check finds 0% of exit bandwidth
    // and it stops treating its directory as usable. Nothing on the control
    // port says so until a stream times out, so count. The pin stays in
    // force either way; the answer is what the user sees.
    if let countries = Self.pinnedCountries(exitNodes) {
      switch await Self.exitCount(in: countries, controller: controller) {
      case .some(0):
        let names = countries.sorted().map { $0.uppercased() }.joined(separator: ", ")
        return FlutterError(
          code: "exit_country_empty",
          message: "tor's consensus lists no exit relay in \(names), so no circuit can be "
            + "built under this exit-country pin. The pin stays in force: nothing leaves "
            + "from another country instead.",
          details: nil)
      case .none:
        note("Could not count the exits in the pinned country; the pin is in force.")
      case .some:
        break
      }
    }
    // tor also wants an IPv6 table once a country pin is in force, and warns
    // on every config change that it has none. Exit countries are decided by
    // a relay's IPv4 address alone (`node_set_country`), so the IPv4 table
    // is all a pin needs; the warning is noise, and this line says so where
    // the warning lands.
    note("Exit-country pin applied. tor's missing-geoip6 warning is expected: "
      + "exit countries are matched by IPv4.")
    return nil
  }

  /// Close every circuit that can carry exit traffic.
  ///
  /// A change to `ExitNodes` stops tor attaching *new* streams to circuits
  /// built before it, and that is all it does: a stream already open stays
  /// on its old circuit for as long as the client keeps the connection. The
  /// webview's network layer pools its connections per data store, not per
  /// WKWebView, so a site recreated for its new pin went straight back out
  /// through the connection it had before, from the old exit. Closing the
  /// circuits ends those streams, and whatever the client opens next is
  /// built under the pin now in force.
  ///
  /// Onion-service and other internal circuits are left alone; the pin says
  /// nothing about them.
  private func closeExitCircuits(_ controller: TorController) async {
    var status = await Self.controlRead(
      controller, ["circuit-status"], within: kTorControlReplyTimeout)
    // An empty answer, as opposed to an empty value, is Tor.framework's
    // reply observer having been handed an unrelated event first.
    if status?.isEmpty == true {
      status = await Self.controlRead(
        controller, ["circuit-status"], within: kTorControlReplyTimeout)
    }
    guard let raw = status?.first else {
      note("Could not read tor's circuits after an exit-country change.")
      return
    }
    let ids = Self.exitCircuitIds(fromCircuitStatus: raw)
    guard !ids.isEmpty else { return }
    let closed = await Self.reply(within: kTorControlReplyTimeout) {
      (answer: @escaping (Bool) -> Void) in
      controller.closeCircuits(byIds: ids) { success in answer(success) }
    }
    note(
      closed == true
        ? "Closed \(ids.count) circuit(s) opened before the exit-country change."
        : "Some of \(ids.count) circuit(s) opened before the exit-country change "
          + "were already gone.")
  }

  /// Circuit purposes that carry streams out through an exit. Conflux legs
  /// are exit circuits too, joined for throughput.
  static let exitCapablePurposes: Set<String> = [
    "GENERAL", "CONFLUX_LINKED", "CONFLUX_UNLINKED",
  ]

  /// The SETCONF that puts a country pin in force.
  ///
  /// StrictNodes 1: without it tor treats ExitNodes as a preference and
  /// silently leaves through another country when the pinned one has no
  /// usable exit.
  ///
  /// ConfluxEnabled 0, in the same command: a conflux set outlives the pin.
  /// When one of its legs closes, whether by tor's own cleanup of an
  /// ExitNodes change or by `closeExitCircuits`, tor launches a recovery leg
  /// with the exit the surviving legs already use (`get_exit_for_nonce`),
  /// and a stream takes any linked set whose exit is not *excluded*
  /// (`conflux_get_circ_for_conn`), which a pre-pin exit never is. With
  /// conflux off no leg can link, so those recovery legs never carry a
  /// stream and every stream goes out on a circuit built under the pin.
  static func exitPinConfigs(_ exitNodes: String) -> [[AnyHashable: Any]] {
    [
      ["key": "ExitNodes", "value": exitNodes],
      ["key": "StrictNodes", "value": "1"],
      ["key": "ConfluxEnabled", "value": "0"],
    ]
  }

  /// What clearing a pin sets back, alongside RESETCONF ExitNodes.
  static let exitPinClearConfigs: [[AnyHashable: Any]] = [
    ["key": "StrictNodes", "value": "0"],
    ["key": "ConfluxEnabled", "value": "auto"],
  ]

  /// IDs of the circuits a `GETINFO circuit-status` value lists as able to
  /// carry exit traffic: one circuit per line, `ID STATUS [PATH] KEY=value…`.
  /// A line with no `PURPOSE` is kept, since an old tor that omits it is
  /// describing a general circuit. Closed and failed circuits are skipped.
  static func exitCircuitIds(fromCircuitStatus raw: String) -> [String] {
    raw.components(separatedBy: .newlines).compactMap { line in
      let words = line.split(separator: " ").map(String.init)
      guard words.count >= 2,
            words[0].allSatisfy({ $0.isLetter || $0.isNumber }),
            words[1] != "CLOSED", words[1] != "FAILED"
      else { return nil }
      if let purpose = parseKeyValues(line)["PURPOSE"],
         !exitCapablePurposes.contains(purpose) {
        return nil
      }
      return words[0]
    }
  }

  /// The country codes an `ExitNodes` value names, lowercased. Nil when it
  /// names anything but countries, since a count by country cannot speak
  /// for a fingerprint or a nickname.
  static func pinnedCountries(_ exitNodes: String) -> Set<String>? {
    var out = Set<String>()
    for item in exitNodes.split(separator: ",") {
      let code = item.trimmingCharacters(in: .whitespaces)
      guard code.count == 4, code.hasPrefix("{"), code.hasSuffix("}") else { return nil }
      out.insert(code.dropFirst().dropLast().lowercased())
    }
    return out.isEmpty ? nil : out
  }

  /// IPv4 address of every relay a `GETINFO ns/all` value lists with the
  /// Exit flag and without BadExit, which is what tor draws an exit from.
  /// An `r` line ends `IP ORPort DirPort` in every flavour tor prints.
  static func exitAddresses(fromNetworkStatus raw: String) -> [String] {
    var out: [String] = []
    var address: String?
    for line in raw.components(separatedBy: .newlines) {
      if line.hasPrefix("r ") {
        let words = line.split(separator: " ")
        let candidate = words.count >= 8 ? String(words[words.count - 3]) : ""
        address = candidate.split(separator: ".").count == 4 ? candidate : nil
      } else if line.hasPrefix("s "), let current = address {
        let flags = Set(line.split(separator: " ").map(String.init))
        if flags.contains("Exit") && !flags.contains("BadExit") {
          out.append(current)
        }
        address = nil
      }
    }
    return out
  }

  /// How many exits the consensus has in [countries], by tor's own GeoIP
  /// table; at least 1 when there are some, as the count stops at the first.
  /// Nil when tor did not answer well enough to count.
  private static func exitCount(
    in countries: Set<String>, controller: TorController
  ) async -> Int? {
    guard let raw = await readTwice(controller, ["ns/all"])?.first else { return nil }
    let addresses = Array(Set(exitAddresses(fromNetworkStatus: raw)))
    guard !addresses.isEmpty else { return nil }
    for start in stride(from: 0, to: addresses.count, by: 256) {
      let batch = Array(addresses[start..<min(start + 256, addresses.count)])
      guard let codes = await readTwice(controller, batch.map { "ip-to-country/\($0)" }),
            codes.count == batch.count
      else { return nil }
      let found = codes.filter { countries.contains($0.lowercased()) }.count
      if found > 0 { return found }
    }
    return 0
  }

  /// [controlRead], asked again once when the answer came back empty, which
  /// is Tor.framework handing the reply observer an unrelated event first.
  /// A timeout is not asked again: the whole change has one deadline.
  private static func readTwice(
    _ controller: TorController, _ keys: [String]
  ) async -> [String]? {
    guard let first = await controlRead(controller, keys, within: kTorControlReplyTimeout)
    else { return nil }
    if !first.isEmpty { return first }
    return await controlRead(controller, keys, within: kTorControlReplyTimeout)
  }

  /// Whether tor has an IPv4 GeoIP table loaded. Asked twice at most, for
  /// the same unrelated-event reason as [closeExitCircuits]; anything but a
  /// clear "1" reads as no, since the pin is refused on a no.
  private static func geoipAvailable(_ controller: TorController) async -> Bool {
    for _ in 0..<2 {
      let answer = await controlRead(
        controller, ["ip-to-country/ipv4-available"], within: kTorControlReplyTimeout)
      guard let answer = answer else { return false }
      if let value = answer.first { return value == "1" }
    }
    return false
  }

  /// `GETINFO [keys]`, or nil when tor has not answered within [seconds].
  ///
  /// The one place the plugin reads the control port after bootstrap, and
  /// it only runs once `finishLocked` has dropped the event subscription
  /// (TOR-019). The framework's async `info(forKeys:)` has no end of its
  /// own; the read it starts is abandoned at the deadline, not cancelled.
  private static func controlRead(
    _ controller: TorController, _ keys: [String], within seconds: Double
  ) async -> [String]? {
    await reply(within: seconds) { (answer: @escaping ([String]) -> Void) in
      Task { answer(await controller.info(forKeys: keys)) }
    }
  }

  private static func setConfs(
    _ controller: TorController, _ confs: [[AnyHashable: Any]]
  ) async -> (Bool, Error?)? {
    await reply(within: kTorControlReplyTimeout) {
      (answer: @escaping ((Bool, Error?)) -> Void) in
      controller.setConfs(confs) { success, error in answer((success, error)) }
    }
  }

  private static func resetConf(
    _ controller: TorController, key: String
  ) async -> (Bool, Error?)? {
    await reply(within: kTorControlReplyTimeout) {
      (answer: @escaping ((Bool, Error?)) -> Void) in
      controller.resetConf(forKey: key) { success, error in answer((success, error)) }
    }
  }

  /// Whatever [send]'s completion delivers, or nil at [seconds], whichever
  /// comes first. Tor.framework drops a command's completion when the write
  /// fails, so no wait on it may be open-ended (BUG-018).
  private static func reply<T>(
    within seconds: Double, _ send: (@escaping (T) -> Void) -> Void
  ) async -> T? {
    await withCheckedContinuation { (done: CheckedContinuation<T?, Never>) in
      let gate = OnceGate()
      DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
        if gate.claim() { done.resume(returning: nil) }
      }
      send { value in
        if gate.claim() { done.resume(returning: value) }
      }
    }
  }

  private func rebuildCircuits() {
    stateQueue.async { [weak self] in
      guard let self = self, let controller = self.controller, self.state == "up" else { return }
      // SIGNAL RELOAD followed by SIGNAL NEWNYM.
      controller.resetConnection(nil)
    }
  }

  // MARK: - Publishing

  /// [generation] guards a failure raised by an earlier run's handshake:
  /// without it, a control-port error from a tor that was already stopped
  /// paints an error over a runtime that has since moved on.
  private func failLocked(_ message: String, generation: Int? = nil) {
    if let generation = generation, generation != self.generation { return }
    lastError = message
    starting = false
    logRelay.emit(source: "plugin", severity: "err", message: message)
    // A run that failed is a run nobody can use, and leaving it alive costs
    // the next start the whole process (TOR-020). Retry then gets a fresh
    // tor rather than the "still running" dead end.
    if let controller = controller {
      if let observer = statusObserver { controller.removeObserver(observer) }
      statusObserver = nil
      controller.disconnect()
      self.controller = nil
    }
    retireRunningLocked()
    publishLocked(state: "error", pct: bootstrapPct, tag: bootstrapTag, summary: bootstrapSummary)
  }

  private func snapshotLocked() -> [String: Any] {
    var payload: [String: Any] = ["state": state, "bootstrapPct": bootstrapPct]
    if let tag = bootstrapTag { payload["bootstrapTag"] = tag }
    if let summary = bootstrapSummary { payload["bootstrapSummary"] = summary }
    if let host = socksHost { payload["socksHost"] = host }
    if let port = socksPort { payload["socksPort"] = port }
    if let error = lastError { payload["lastError"] = error }
    return payload
  }

  /// [tag] and [summary] are tor's own words for the phase and are cleared
  /// by every publish that does not carry them, so a stale phase cannot
  /// outlive the bootstrap it described.
  private func publishLocked(
    state: String, pct: Int, tag: String? = nil, summary: String? = nil
  ) {
    self.state = state
    self.bootstrapPct = pct
    self.bootstrapTag = tag
    self.bootstrapSummary = summary
    let payload = snapshotLocked()
    // FlutterEventSink is main-thread-only; hopping here keeps the sink out
    // of stateQueue's ownership and off every callback thread.
    DispatchQueue.main.async { [weak self] in
      self?.sink?(payload)
    }
  }
}

extension TorControllerPlugin: FlutterStreamHandler {
  func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    sink = events
    // Replay the current state so a subscriber attaching mid-bootstrap is
    // not left staring at nothing until the next event happens to fire.
    stateQueue.async { [weak self] in
      guard let self = self else { return }
      let payload = self.snapshotLocked()
      DispatchQueue.main.async { self.sink?(payload) }
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }
}
