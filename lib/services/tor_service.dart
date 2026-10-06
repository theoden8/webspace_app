// Binds the pure [TorEngine] to the native Tor runtime and exposes it as a
// process singleton. Everything policy-shaped (refcount, debounce, isolation
// tags, fail-closed) lives in tor_engine.dart; this file is the platform
// seam and nothing else.
//
// Deliberately free of dart:io so screens that reach a proxy setting still
// compile for the web target (DESIGN-001). Platform detection goes through
// `defaultTargetPlatform`, not `Platform.isIOS`.

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;

import 'package:webspace/platform/host_storage.dart'
    show createExternalTorIdentify, createTorGeoIpStore, createTorSocksProbe;

import 'package:webspace/services/external_tor_runtime.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/tor_bridge_secure_storage.dart';
import 'package:webspace/services/tor_engine.dart';
import 'package:webspace/services/tor_holders.dart';
import 'package:webspace/settings/external_tor.dart';
import 'package:webspace/settings/proxy.dart';

export 'package:webspace/services/tor_holders.dart';
export 'package:webspace/services/tor_engine.dart'
    show
        TorStatus,
        TorStopped,
        TorStarting,
        TorBootstrapping,
        TorUp,
        TorErrored,
        TorGate,
        torGateFor,
        TorFailure,
        TorFailureKind,
        classifyTorFailure,
        kTorAppGlobalTag;

const String _kChannel = 'org.codeberg.theoden8.webspace/tor';
const String _kEvents = 'org.codeberg.theoden8.webspace/tor/events';
const String _kLogEvents = 'org.codeberg.theoden8.webspace/tor/logs';

/// Log tag for the runtime's own lifecycle: state transitions and the
/// plugin's notes about them.
const String kTorLogTag = 'Tor';

/// Log tag for tor's own output, kept apart from [kTorLogTag] so a reader
/// can tell what the app decided from what tor said.
const String kTorDaemonLogTag = 'TorLog';

/// Whether this build has the native runtime behind the channels.
///
/// The two Apple platforms ship it; nothing else does (TOR-007), and asking
/// elsewhere must not touch a channel, or `receiveBroadcastStream().listen`
/// throws MissingPluginException.
bool get _hasNativeTor =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS);

/// Method-channel implementation of [TorRuntime].
///
/// The two Apple platforms ship the plugin (TOR-007). On every other
/// platform [isAvailable] is false and the engine short-circuits, so no
/// channel call is ever made and no `MissingPluginException` can surface.
class MethodChannelTorRuntime implements TorRuntime {
  MethodChannelTorRuntime({
    MethodChannel? channel,
    EventChannel? events,
  })  : _channel = channel ?? const MethodChannel(_kChannel),
        _eventChannel = events ?? const EventChannel(_kEvents);

  final MethodChannel _channel;
  final EventChannel _eventChannel;
  Stream<TorStatus>? _decoded;

  @override
  bool get isAvailable => _hasNativeTor;

  // Every channel touch below is gated on [isAvailable]. Without the gate,
  // simply *asking* whether Tor is available on Android builds the engine,
  // whose constructor subscribes to `events` — and
  // `receiveBroadcastStream()` invokes `listen` eagerly, throwing
  // MissingPluginException on every platform that has no plugin.

  @override
  Future<void> start() async {
    if (!isAvailable) return;
    await _channel.invokeMethod<void>('start');
  }

  @override
  Future<void> stop() async {
    if (!isAvailable) return;
    await _channel.invokeMethod<void>('stop');
  }

  @override
  Future<void> rebuildCircuits() async {
    if (!isAvailable) return;
    await _channel.invokeMethod<void>('rebuildCircuits');
  }

  @override
  Future<void> applyExitCountry(String? exitNodes, {String? geoipFile}) async {
    if (!isAvailable) return;
    try {
      await _channel.invokeMethod<void>('setExitCountry', {
        'exitNodes': exitNodes,
        'geoipFile': geoipFile,
      });
    } on PlatformException catch (e) {
      if (e.code == 'exit_country_empty') {
        throw TorExitCountryEmpty(e.message ?? 'No exit relay in that country.');
      }
      rethrow;
    }
  }

  @override
  Future<int> startTransport(String transport) async {
    if (!isAvailable) return 0;
    // 0 is the "did not start" contract, so a null or non-int reply from a
    // plugin that failed must read as failure rather than crash the start
    // path — the engine turns 0 into "no bridge options" and tor comes up
    // without bridges instead of dialling a dead port.
    final port =
        await _channel.invokeMethod<int>('startTransport', {'transport': transport});
    return port ?? 0;
  }

  @override
  Future<void> setTorrcOptions(List<(String, String)> options) async {
    if (!isAvailable) return;
    // Sent as a flat list of pairs rather than a map: torrc allows the same
    // key more than once, and `Bridge` in particular is repeated per line,
    // so a map would silently keep only the last bridge.
    await _channel.invokeMethod<void>('setTorrcOptions', {
      'options': [
        for (final (key, value) in options) [key, value],
      ],
    });
  }

  @override
  Future<void> reopenListeners() async {
    if (!isAvailable) return;
    await _channel.invokeMethod<void>('reopenListeners');
  }

  @override
  Stream<TorStatus> get events => _decoded ??= isAvailable
      ? _eventChannel.receiveBroadcastStream().transform(
          StreamTransformer<Object?, TorStatus>.fromHandlers(
            handleData: (raw, sink) => sink.add(decodeStatus(raw)),
            // A channel error is a state, not the end of the stream. A
            // plugin that failed to register answers this way, and letting
            // the MissingPluginException through would be an unhandled
            // async error at startup rather than something the UI can say
            // out loud.
            handleError: (error, stack, sink) =>
                sink.add(TorErrored('No Tor runtime in this build: $error')),
          ),
        )
      : const Stream<TorStatus>.empty();

  /// Decode one native status payload. Unknown shapes degrade to an error
  /// rather than throwing into the event stream, which would tear down the
  /// subscription and leave the engine deaf for the rest of the session.
  @visibleForTesting
  static TorStatus decodeStatus(Object? raw) {
    if (raw is! Map) return TorErrored('Malformed Tor status: $raw');
    final state = raw['state'];
    switch (state) {
      case 'stopped':
        return const TorStopped();
      case 'starting':
        return const TorStarting();
      case 'bootstrapping':
        final pct = raw['bootstrapPct'];
        final tag = raw['bootstrapTag'];
        final summary = raw['bootstrapSummary'];
        return TorBootstrapping(
          pct is int ? pct : 0,
          tag: tag is String && tag.isNotEmpty ? tag : null,
          summary: summary is String && summary.isNotEmpty ? summary : null,
        );
      case 'up':
        final host = raw['socksHost'];
        final port = raw['socksPort'];
        if (host is! String || port is! int) {
          return TorErrored('Tor reported up without a SOCKS endpoint.');
        }
        return TorUp(host, port);
      case 'error':
        final msg = raw['lastError'];
        return TorErrored(msg is String ? msg : 'Tor failed.');
      default:
        return TorErrored('Unknown Tor state: $state');
    }
  }
}

/// One line of tor's own log, or one of the plugin's lifecycle notes.
class TorLogLine {
  const TorLogLine({
    required this.fromTor,
    required this.level,
    required this.message,
  });

  /// Whether tor wrote this. The plugin's own notes cover the window tor
  /// cannot describe — before its control port answers, and after it goes.
  final bool fromTor;
  final LogLevel level;
  final String message;
}

/// Pipes the native Tor log channel into [LogService] (TOR-018).
///
/// Deliberately not part of [TorRuntime]: nothing here is a decision, so
/// the engine has no use for it, and adding it to that interface would make
/// every test fake implement a stream it never reads.
class TorLogBridge {
  TorLogBridge({EventChannel? events})
      : _channel = events ?? const EventChannel(_kLogEvents);

  final EventChannel _channel;
  StreamSubscription<Object?>? _sub;

  void start() {
    if (_sub != null || !_hasNativeTor) return;
    _sub = _channel.receiveBroadcastStream().listen(
      (raw) {
        final line = decodeLogLine(raw);
        if (line == null) return;
        LogService.instance.log(
          line.fromTor ? kTorDaemonLogTag : kTorLogTag,
          line.message,
          level: line.level,
          // tor's own output is sensitive and the plugin's notes are not.
          // A notice-level line can name the bridges this device dials
          // (TOR-017) and the relays it picked, so it belongs in the
          // memory-only ring that Dev Tools only shows on request; the
          // plugin's notes carry nothing but its own state machine.
          sensitivity:
              line.fromTor ? LogSensitivity.sensitive : LogSensitivity.normal,
        );
      },
      // An error on the channel must not tear the subscription down: this
      // is the surface that explains a failing bootstrap, and losing it
      // exactly when tor is unhappy is the case it exists for.
      onError: (Object error) => LogService.instance.log(
        kTorLogTag,
        'Log channel error: $error',
        level: LogLevel.warning,
      ),
      cancelOnError: false,
    );
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
  }

  /// Decode one native log payload. Anything malformed is dropped rather
  /// than logged as itself, which would turn a shape mismatch into noise
  /// at whatever rate tor happens to be talking.
  @visibleForTesting
  static TorLogLine? decodeLogLine(Object? raw) {
    if (raw is! Map) return null;
    final message = raw['message'];
    if (message is! String || message.isEmpty) return null;
    return TorLogLine(
      fromTor: raw['source'] == 'tor',
      level: switch (raw['severity']) {
        'err' => LogLevel.error,
        'warn' => LogLevel.warning,
        _ => LogLevel.info,
      },
      message: message,
    );
  }
}

/// Process-wide handle on Tor: the embedded runtime, or an external tor
/// reached over SOCKS (TOR-025), whichever [wantsExternal] names now.
///
/// One engine per runtime, so the choice can move without a relaunch. Only
/// the one named carries traffic, and only its status reaches [statusStream].
/// The other is never stopped: the embedded tor runs at most once per
/// process (TOR-020), so one that has run is left idle for the way back.
class TorService {
  TorService._({
    TorEngine? embedded,
    TorEngine? external,
    ExternalTorRuntime? externalRuntime,
    TorLogBridge? logs,
  })  : assert(embedded != null || external != null),
        _embedded = embedded,
        _externalEngine = external,
        _externalRuntime = externalRuntime,
        _logs = logs ?? TorLogBridge() {
    _externalActive = _resolveExternal();
    _logs.start();
    for (final engine in [embedded, external].nonNulls) {
      _engineSubs.add(engine.statusStream.listen((s) {
        if (identical(engine, _engine)) _forward(s);
      }));
    }
  }

  static TorService? _instance;

  /// The live singleton, created on first touch.
  static TorService get instance => _instance ??= _production();

  /// Whether the external tor is wanted (TOR-025). Installed at startup from
  /// the Experimental switch, and read again by [runtimeChoiceChanged].
  static bool Function() wantsExternal = _never;

  static bool _never() => false;

  static TorService _production() {
    final externalRuntime = externalTorRunsHere
        ? ExternalTorRuntime(
            address: () => ExternalTorSettings.address,
            identify: createExternalTorIdentify() ??
                (_, _) async => ExternalTorAnswer.unreachable,
          )
        : null;
    final service = TorService._(
      embedded: TorEngine(
        runtime: MethodChannelTorRuntime(),
        sessionSecret: newSessionSecret(),
        // The engine reads bridges itself rather than waiting for a startup
        // call to push them: nothing on a cold start opens the bridge
        // screen, so a pushed-only configuration was simply absent on every
        // relaunch (TOR-016).
        bridgeLoader: () => TorBridgeSecureStorage().load(),
        // Downloaded on the device, never shipped (LICENSE-002).
        geoIpStore: createTorGeoIpStore(),
        socksProbe: createTorSocksProbe(),
      ),
      // No bridge loader and no GeoIP store: an external tor keeps its own
      // bridges and exits, and a pin it cannot take must not first download
      // a GeoIP table through it (TOR-025).
      external: externalRuntime == null
          ? null
          : TorEngine(
              runtime: externalRuntime,
              sessionSecret: newSessionSecret(),
              socksProbe: createTorSocksProbe(),
            ),
      externalRuntime: externalRuntime,
    );
    // Here rather than in a screen, so every way back into the foreground
    // reaches it, whatever is on screen (TOR-024). A unit test touching the
    // singleton with no binding has no lifecycle to watch.
    try {
      WidgetsBinding.instance.addObserver(_TorResumeWatch(service));
    } catch (_) {}
    return service;
  }

  /// Swap in an engine backed by a fake runtime. Tests only. Pass
  /// [external] when the engine's runtime is an [ExternalTorRuntime].
  @visibleForTesting
  static void overrideEngine(TorEngine engine,
      {TorLogBridge? logs, ExternalTorRuntime? external}) {
    _instance?._cancelSubs();
    _instance = external == null
        ? TorService._(embedded: engine, logs: logs)
        : TorService._(external: engine, externalRuntime: external, logs: logs);
  }

  /// Both engines, with [wantsExternal] choosing between them. Tests only.
  @visibleForTesting
  static void overrideEngines({
    required TorEngine embedded,
    required TorEngine external,
    required ExternalTorRuntime externalRuntime,
    TorLogBridge? logs,
  }) {
    _instance?._cancelSubs();
    _instance = TorService._(
      embedded: embedded,
      external: external,
      externalRuntime: externalRuntime,
      logs: logs,
    );
  }

  @visibleForTesting
  static Future<void> reset() async {
    final service = _instance;
    _instance = null;
    wantsExternal = _never;
    if (service == null) return;
    service._cancelSubs();
    await service._logs.dispose();
    await service._embedded?.dispose();
    await service._externalEngine?.dispose();
    await service._statuses.close();
  }

  final TorEngine? _embedded;
  final TorEngine? _externalEngine;
  final ExternalTorRuntime? _externalRuntime;
  final TorLogBridge _logs;
  final List<StreamSubscription<TorStatus>> _engineSubs = [];
  final StreamController<TorStatus> _statuses =
      StreamController<TorStatus>.broadcast();
  late bool _externalActive;

  /// The last exit pin asked for, re-issued to an engine switched to.
  (String?, bool)? _exitRequest;

  TorEngine get _engine => _externalActive ? _externalEngine! : _embedded!;

  bool _resolveExternal() {
    if (_embedded == null) return true;
    if (_externalEngine == null) return false;
    return wantsExternal();
  }

  void _cancelSubs() {
    for (final sub in _engineSubs) {
      sub.cancel();
    }
    _engineSubs.clear();
  }

  // Every transition, in the app log. The runtime is a black box to the user
  // otherwise: "Starting" with no percentage and no phase is what a
  // bootstrap looks like from outside, whether it is 3 seconds in or 60
  // (TOR-018).
  void _forward(TorStatus s) {
    LogService.instance.log(
      kTorLogTag,
      'State: $s',
      level: s is TorErrored ? LogLevel.error : LogLevel.info,
    );
    if (!_statuses.isClosed) _statuses.add(s);
  }

  /// Whether Tor here is an external tor rather than the embedded one
  /// (TOR-025). Exit countries, bridges and New circuits need the embedded
  /// runtime's control port, so screens hide them when this is true.
  bool get isExternal => _externalActive;

  /// Move to the tor [wantsExternal] names now, without a relaunch
  /// (TOR-025). The holders move with it and the last exit pin is asked of
  /// it again; the engine left behind keeps running with nothing on it.
  /// Its status, published first, is what rebinds every Tor-bound site.
  ///
  /// One move at a time: a call made during one is folded into a re-read
  /// once it lands, so the last flip wins and no two moves split the
  /// holders between engines.
  Future<void> runtimeChoiceChanged() async {
    if (_switching) {
      _switchAgain = true;
      return;
    }
    _switching = true;
    try {
      do {
        _switchAgain = false;
        await _switchTo(_resolveExternal());
      } while (_switchAgain);
    } finally {
      _switching = false;
    }
  }

  bool _switching = false;
  bool _switchAgain = false;

  Future<void> _switchTo(bool external) async {
    if (external == _externalActive) return;
    final from = _engine;
    final holders = from.holders.toSet();
    _externalActive = external;
    LogService.instance.log(kTorLogTag,
        'Switched to the ${external ? 'external' : 'built-in'} tor');
    _forward(_engine.status);
    await from.syncHolders(const <TorHolder>[]);
    if (!_engine.isAvailable) return;
    final pin = _exitRequest;
    if (pin != null) {
      unawaited(_engine.setExitCountry(pin.$1, mayFetchGeoIp: pin.$2));
    }
    await _engine.syncHolders(holders);
    // An engine that was up before it was left may be up on a listener that
    // has since gone (a tor quit, a suspension): asked as on a resume.
    await _engine.revive();
  }

  /// Ask the external tor again after its address changed. Nothing to ask
  /// while nothing has used it: the next start reads the address anyway.
  Future<void> externalAddressChanged() async {
    final runtime = _externalRuntime;
    final engine = _externalEngine;
    if (runtime == null || engine == null || engine.status is TorStopped) {
      return;
    }
    await runtime.reconnect();
  }

  /// Whether anything may offer or start Tor: this build has the runtime
  /// (TOR-007), or the external tor is chosen (TOR-025). Every start path
  /// below re-checks it, so the answer does not depend on the caller having
  /// asked first.
  bool get isAvailable => _engine.isAvailable;

  TorStatus get status => _engine.status;

  /// What holds the runtime up.
  Set<TorHolder> get holders => _engine.holders;
  Stream<TorStatus> get statusStream => _statuses.stream;

  /// `host:port` of the live SOCKS5 listener, or null when not up.
  String? get socksEndpoint {
    final s = _engine.status;
    return s is TorUp ? '${s.host}:${s.port}' : null;
  }

  Future<void> maybeStart(TorHolder holder) async {
    if (!isAvailable) return;
    await _engine.acquire(holder);
  }

  void release(TorHolder holder) => _engine.release(holder);

  Future<void> syncHolders(Iterable<TorHolder> holders) async {
    if (!isAvailable) return;
    await _engine.syncHolders(holders);
  }

  Future<void> rebuildCircuits() => _engine.rebuildCircuits();

  /// Check that tor still carries traffic after the app was away, and
  /// reopen its SOCKS listener when a suspension killed it (TOR-024).
  Future<void> revive() async {
    if (!isAvailable) return;
    await _engine.revive();
  }

  /// The embedded tor's bridge configuration, in force or queued for its
  /// next start. Bridges are only ever the embedded tor's: an external one
  /// keeps its own.
  TorBridgeConfig get bridges => (_embedded ?? _engine).bridges;

  /// Set the bridge configuration, returning whether a [restart] is needed
  /// for it to apply. Not gated on [isAvailable]: the user can configure
  /// bridges before anything has started Tor, and refusing the write would
  /// silently discard what they typed.
  bool setBridges(TorBridgeConfig config) =>
      (_embedded ?? _engine).setBridges(config);

  /// Stop and re-start the runtime, keeping the holder set. Backs the Retry
  /// offered on a failure: [maybeStart] cannot serve that, because acquire
  /// short-circuits whenever a holder is already registered — which it
  /// always is for a site pinned to TOR.
  Future<void> restart() async {
    if (!isAvailable) return;
    await _engine.restart();
  }

  /// Pin every circuit to a country (tor `ExitNodes` syntax) or clear it.
  /// Global to the runtime — see TOR-014 for why that makes per-site pins
  /// mutually exclusive.
  Future<void> setExitCountry(String? exitNodes,
      {bool mayFetchGeoIp = true}) async {
    _exitRequest = (exitNodes, mayFetchGeoIp);
    if (!isAvailable) return;
    await _engine.setExitCountry(exitNodes, mayFetchGeoIp: mayFetchGeoIp);
  }

  String? get exitNodes => _engine.exitNodes;

  /// SOCKS5 settings for a site (or app-global traffic when [siteId] is
  /// null). Null means "not routable yet" — the caller must fail closed.
  ///
  /// Returns null on a platform with no runtime, which is the fail-closed
  /// answer: a site carrying `ProxyType.TOR` imported from an Apple device is
  /// blocked, never quietly sent out over the device IP.
  UserProxySettings? socksFor({String? siteId}) =>
      isAvailable ? _engine.socksFor(TorEngine.tagFor(siteId)) : null;

  /// Per-launch SOCKS password. Not a secret Tor verifies — it only has to
  /// be unguessable and stable within a launch so a site keeps one circuit,
  /// and different across launches so circuits don't outlive the process
  /// (TOR-003). Never persisted, never serialized (TOR-009).
  @visibleForTesting
  static String newSessionSecret() {
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

class _TorResumeWatch with WidgetsBindingObserver {
  _TorResumeWatch(this._service);

  final TorService _service;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_service.revive());
  }
}

/// Resolve [settings] into something dialable, expanding [ProxyType.TOR]
/// into the live SOCKS5 endpoint tagged for [siteId].
///
/// Three outcomes, and callers must distinguish them:
/// - non-TOR input is returned unchanged,
/// - TOR with the runtime up returns SOCKS5 settings,
/// - TOR with the runtime not up returns null, meaning *block*, never
///   "fall back to direct" (TOR-008).
UserProxySettings? materializeTorProxy(
  UserProxySettings settings, {
  String? siteId,
}) {
  if (settings.type != ProxyType.TOR) return settings;
  final resolved = TorService.instance.socksFor(siteId: siteId);
  if (resolved == null) {
    LogService.instance.log(
      'Tor',
      'Blocked an outbound request: proxy is TOR but the runtime is '
          '${TorService.instance.status}.',
    );
  }
  return resolved;
}
