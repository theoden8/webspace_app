import Flutter
import Foundation
import Tor

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

  /// Serial queue owning every stored property below this line.
  private let stateQueue = DispatchQueue(label: "org.codeberg.theoden8.webspace.tor")

  /// Where the control-port handshake runs. It retries with sleeps, and
  /// doing that on `stateQueue` would block every status call and the stop
  /// path behind it for up to a second and a half.
  private let attachQueue = DispatchQueue(label: "org.codeberg.theoden8.webspace.tor.attach")

  private var thread: TorThread?
  private var controller: TorController?
  private var configuration: TorConfiguration?
  private var statusObserver: Any?
  private var circuitObserver: Any?

  /// Last status published, so a late `status()` call and a fresh event
  /// subscription agree with each other.
  private var state: String = "stopped"
  private var bootstrapPct: Int = 0
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
    super.init()
    self.channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    self.eventChannel.setStreamHandler(self)
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
      self.publishLocked(state: "starting", pct: 0)

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
      // `auto` lets tor pick a free loopback port and report it back.
      // Never 9050: another tor-embedding app (Onion Browser) may already
      // own it, and binding a fixed port is how a user's traffic ends up at
      // whatever else answers there.
      //
      // IsolateSOCKSAuth is on by default per tor(1), but written out so
      // the isolation contract is legible here rather than inherited from
      // an upstream default that could change (TOR-003).
      config.options = [
        "SocksPort": "auto IsolateSOCKSAuth IsolateDestAddr",
        "Log": "err file /dev/null",
        "SafeLogging": "1",
      ]
      self.configuration = config

      let thread = TorThread(configuration: config)
      self.thread = thread
      thread.start()

      // tor needs a moment to write its control-port file before the
      // controller can attach.
      self.attachQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
        self?.attachController(config)
      }
    }
  }

  /// Runs on `attachQueue`, never on `stateQueue`: it sleeps between
  /// retries. `config` is passed in rather than read back off the shared
  /// property so this function touches no state it does not own.
  private func attachController(_ config: TorConfiguration) {
    guard let portFile = config.controlPortFile else {
      stateQueue.async { self.failLocked("Tor did not publish a control port.") }
      return
    }
    let controller = TorController(controlPortFile: portFile)

    // Both of the next two steps are racy against a tor that has only just
    // started: the control port refuses connections and the auth cookie
    // reads back nil for a beat after the port file appears. Retry rather
    // than fail the whole bootstrap on a timing artifact.
    var connectError: Error?
    for _ in 0..<3 {
      do {
        connectError = nil
        try controller.connect()
        break
      } catch {
        connectError = error
        Thread.sleep(forTimeInterval: 0.25)
      }
    }
    if let error = connectError {
      stateQueue.async {
        self.failLocked("Could not reach the Tor control port: \(error.localizedDescription)")
      }
      return
    }

    var cookie: Data?
    for _ in 0..<3 {
      cookie = config.cookie
      if cookie != nil { break }
      Thread.sleep(forTimeInterval: 0.25)
    }
    guard let cookie = cookie else {
      stateQueue.async { self.failLocked("Tor control cookie unreadable.") }
      return
    }

    controller.authenticate(with: cookie) { [weak self] _, error in
      guard let self = self else { return }
      self.stateQueue.async {
        // A stop() may have landed while this handshake was in flight. Its
        // teardown already ran, so adopting this controller now would leave
        // a live control connection attached to a runtime nobody is
        // tracking — the resurrection half of BUG-007. Drop it instead.
        guard self.starting, self.thread != nil else {
          controller.disconnect()
          return
        }
        // Publishing the controller happens here, on the queue that owns it.
        self.controller = controller
        if let error = error {
          self.failLocked("Tor control authentication failed: \(error.localizedDescription)")
          return
        }
        self.observeLocked(controller)
      }
    }
  }

  private func observeLocked(_ controller: TorController) {
    statusObserver = controller.addObserver(forStatusEvents: {
      [weak self] (type, _, action, arguments) -> Bool in
      guard let self = self else { return false }
      guard type == "STATUS_CLIENT", action == "BOOTSTRAP" else { return false }
      // The Bool is "I handled this event", not "stop observing".
      let pct = Int(arguments?["PROGRESS"] ?? "") ?? 0
      self.stateQueue.async {
        // Never walk backwards, and never overwrite a terminal state with
        // a stale in-flight event.
        guard self.state == "starting" || self.state == "bootstrapping" else { return }
        self.publishLocked(state: "bootstrapping", pct: max(pct, self.bootstrapPct))
      }
      return true
    })

    circuitObserver = controller.addObserver(forCircuitEstablished: { [weak self] established in
      guard let self = self, established else { return }
      self.stateQueue.async { self.readSocksEndpointLocked(controller) }
    })
  }

  private func readSocksEndpointLocked(_ controller: TorController) {
    // `getInfoForKeys:completion:` imports as the async `info(forKeys:)`.
    Task { [weak self] in
      guard let self = self else { return }
      let values = await controller.info(forKeys: ["net/listeners/socks"])
      self.stateQueue.async {
        // "127.0.0.1:41337", sometimes quoted. A "unix:/path" form can only
        // appear if someone sets socksURL, which we never do.
        let raw = values.first?
          .trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? ""
        let parts = raw.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]), port > 0 else {
          self.failLocked("Tor reported no usable SOCKS listener.")
          return
        }
        // Bootstrap is done; these observers have nothing left to say.
        if let observer = self.statusObserver { controller.removeObserver(observer) }
        if let observer = self.circuitObserver { controller.removeObserver(observer) }
        self.statusObserver = nil
        self.circuitObserver = nil

        self.socksHost = String(parts[0])
        self.socksPort = port
        self.starting = false
        self.publishLocked(state: "up", pct: 100)
      }
    }
  }

  private func stop() {
    stateQueue.async { [weak self] in
      guard let self = self else { return }
      // Idempotent: a stop racing the idle-stop timer must not double-free
      // the controller or cancel a thread twice (BUG-007).
      if let observer = self.statusObserver { self.controller?.removeObserver(observer) }
      if let observer = self.circuitObserver { self.controller?.removeObserver(observer) }
      self.statusObserver = nil
      self.circuitObserver = nil
      self.controller?.disconnect()
      self.controller = nil
      self.thread?.cancel()
      self.thread = nil
      self.configuration = nil
      self.socksHost = nil
      self.socksPort = nil
      self.starting = false
      self.publishLocked(state: "stopped", pct: 0)
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

  private func failLocked(_ message: String) {
    lastError = message
    starting = false
    publishLocked(state: "error", pct: bootstrapPct)
  }

  private func snapshotLocked() -> [String: Any] {
    var payload: [String: Any] = ["state": state, "bootstrapPct": bootstrapPct]
    if let host = socksHost { payload["socksHost"] = host }
    if let port = socksPort { payload["socksPort"] = port }
    if let error = lastError { payload["lastError"] = error }
    return payload
  }

  private func publishLocked(state: String, pct: Int) {
    self.state = state
    self.bootstrapPct = pct
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
