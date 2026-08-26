import Flutter
import Foundation
import Tor

/// iOS bridge for [`TorService`](../../lib/services/tor_service.dart).
///
/// Owns a `TORThread` plus the control-port connection that reports its
/// bootstrap progress, and publishes both as a Flutter method channel and an
/// event channel. Everything policy-shaped — when to start, when to stop,
/// which SOCKS credentials a caller gets — lives in Dart
/// (`tor_engine.dart`); this class only starts, stops, observes and reports.
///
/// Concurrency (BUG-007). Four contexts touch this object: the Flutter
/// platform thread (method calls), the `TORThread` itself, the control
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

  private var thread: TORThread?
  private var controller: TORController?
  private var configuration: TORConfiguration?
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
  /// two TORThreads in one process fight over the data directory.
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

      let config = TORConfiguration()
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
      // Never 9050: another app on the device (Orbot, Onion Browser) may
      // already own it, and binding a fixed port is how a user's traffic
      // ends up at whatever else answers there.
      //
      // IsolateSOCKSAuth is on by default per tor(1), but written out so
      // the isolation contract is legible here rather than inherited from
      // an upstream default that could change (TOR-003).
      // `options` is an NSMutableDictionary on the ObjC side, so it will
      // not take a Swift dictionary literal directly.
      config.options = NSMutableDictionary(dictionary: [
        "SocksPort": "auto IsolateSOCKSAuth IsolateDestAddr",
        "AvoidDiskWrites": "1",
        "ClientOnly": "1",
      ])
      self.configuration = config

      let thread = TORThread(configuration: config)
      self.thread = thread
      thread.start()

      // tor needs a moment to write its control-port file before the
      // controller can attach.
      self.stateQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
        self?.attachControllerLocked()
      }
    }
  }

  private func attachControllerLocked() {
    guard let config = configuration, let portFile = config.controlPortFile else {
      failLocked("Tor did not publish a control port.")
      return
    }
    guard let cookie = config.cookie else {
      failLocked("Tor control cookie unavailable.")
      return
    }
    let controller = TORController(controlPortFile: portFile)
    self.controller = controller

    do {
      try controller.connect()
    } catch {
      failLocked("Could not connect to the Tor control port: \(error.localizedDescription)")
      return
    }

    controller.authenticate(with: cookie) { [weak self] success, error in
      guard let self = self else { return }
      self.stateQueue.async {
        guard success else {
          self.failLocked(
            "Tor control authentication failed: "
              + (error?.localizedDescription ?? "unknown error"))
          return
        }
        self.observeLocked(controller)
      }
    }
  }

  private func observeLocked(_ controller: TORController) {
    statusObserver = controller.addObserver(forStatusEvents: {
      [weak self] (type, _, action, arguments) -> Bool in
      guard let self = self else { return false }
      guard type == "STATUS_CLIENT", action == "BOOTSTRAP" else { return false }
      let pct = Int(arguments?["PROGRESS"] ?? "") ?? 0
      self.stateQueue.async {
        // Never walk backwards, and never overwrite a terminal state with
        // a stale in-flight event.
        guard self.state == "starting" || self.state == "bootstrapping" else { return }
        self.publishLocked(state: "bootstrapping", pct: max(pct, self.bootstrapPct))
      }
      return false
    })

    circuitObserver = controller.addObserver(forCircuitEstablished: { [weak self] established in
      guard let self = self, established else { return }
      self.stateQueue.async { self.readSocksEndpointLocked(controller) }
    })
  }

  private func readSocksEndpointLocked(_ controller: TORController) {
    controller.getInfo(forKeys: ["net/listeners/socks"]) { [weak self] values in
      guard let self = self else { return }
      self.stateQueue.async {
        // "127.0.0.1:41337", quoted, or "unix:/path" which we never ask for.
        let raw = values.first?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? ""
        let parts = raw.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]), port > 0 else {
          self.failLocked("Tor reported no usable SOCKS listener.")
          return
        }
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
