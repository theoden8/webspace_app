// Binds the pure [TorEngine] to the native Tor runtime and exposes it as a
// process singleton. Everything policy-shaped (refcount, debounce, isolation
// tags, fail-closed) lives in tor_engine.dart; this file is the platform
// seam and nothing else.
//
// Deliberately free of dart:io so screens that reach a proxy setting still
// compile for the web target (DESIGN-001). Platform detection goes through
// `defaultTargetPlatform`, not `Platform.isIOS`.

import 'dart:async';
import 'package:webspace/settings/site_ids.dart';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;

import 'package:webspace/services/host_storage.dart'
    show
        createExternalTorIdentify,
        createManagedTorRuntime,
        createTorControlConnect,
        createTorCookieRead,
        createTorGeoIpStore,
        createTorSocksProbe;

import 'package:webspace/services/external_tor_control_password_storage.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/services/external_tor_runtime.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/tor_bridge_secure_storage.dart';
import 'package:webspace/services/tor_engine.dart';
import 'package:webspace/services/tor_holders.dart';
import 'package:webspace/services/tor_log.dart';
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
        TorRoute,
        TorRouteUp,
        TorRouteBlocked,
        kTorAppGlobalTag,
        kTorReopenTag,
        TorTag;

const String _kChannel = 'org.codeberg.theoden8.webspace/tor';
const String _kEvents = 'org.codeberg.theoden8.webspace/tor/events';
const String _kLogEvents = 'org.codeberg.theoden8.webspace/tor/logs';

/// Whether this build has the native runtime behind the channels.
///
/// The two Apple platforms ship it; nothing else does (TOR-007), and asking
/// elsewhere must not touch a channel, or `receiveBroadcastStream().listen`
/// throws MissingPluginException.
bool get _hasNativeTor =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS);

/// Whether [platform] offers a built-in Tor: the Apple plugin's, or on Linux
/// a tor the app starts, while the Built-in Tor experiment [linuxExperiment]
/// is on (TOR-027, DEVTOOLS-011).
bool builtInTorOffered(
        {required TargetPlatform platform, required bool linuxExperiment}) =>
    switch (platform) {
      TargetPlatform.iOS || TargetPlatform.macOS => true,
      TargetPlatform.linux => linuxExperiment,
      TargetPlatform.android ||
      TargetPlatform.fuchsia ||
      TargetPlatform.windows =>
        false,
    };

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

  @override
  bool get retriesFreely => false;

  // Every channel touch below is gated on [isAvailable]. Without the gate,
  // simply *asking* whether Tor is available on Android builds the engine,
  // whose constructor subscribes to `events` — and
  // `receiveBroadcastStream()` invokes `listen` eagerly, throwing
  // MissingPluginException on every platform that has no plugin.

  /// [method] on the plugin's channel. The plugin refusing it, or no plugin
  /// answering, is the runtime's failure.
  Future<T?> _invoke<T>(String method, {Object? arguments}) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (e) {
      throw TorRuntimeFailure('$e');
    } on MissingPluginException catch (e) {
      throw TorRuntimeFailure('$e');
    }
  }

  @override
  Future<void> start() async {
    if (!isAvailable) return;
    await _invoke<void>('start');
  }

  @override
  Future<void> stop() async {
    if (!isAvailable) return;
    await _invoke<void>('stop');
  }

  @override
  Future<void> rebuildCircuits() async {
    if (!isAvailable) return;
    await _invoke<void>('rebuildCircuits');
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
      throw TorRuntimeFailure('$e');
    } on MissingPluginException catch (e) {
      throw TorRuntimeFailure('$e');
    }
  }

  @override
  Future<int> startTransport(String transport) async {
    if (!isAvailable) return 0;
    // 0 is the "did not start" contract, so a null or non-int reply from a
    // plugin that failed must read as failure rather than crash the start
    // path — the engine turns 0 into "no bridge options" and tor comes up
    // without bridges instead of dialling a dead port.
    final port = await _invoke<Object?>('startTransport',
        arguments: {'transport': transport});
    return port is int ? port : 0;
  }

  @override
  Future<int> restartTransport(String transport) async {
    if (!isAvailable) return 0;
    final port = await _invoke<Object?>('restartTransport',
        arguments: {'transport': transport});
    return port is int ? port : 0;
  }

  @override
  Future<void> setTorrcOptions(List<(String, String)> options) async {
    if (!isAvailable) return;
    await _invoke<void>('setTorrcOptions',
        arguments: {'options': _pairs(options)});
  }

  // A flat list of pairs rather than a map: torrc allows the same key more
  // than once, and `Bridge` in particular is repeated per line, so a map
  // would silently keep only the last bridge.
  static List<List<String>> _pairs(List<(String, String)> options) => [
        for (final (key, value) in options) [key, value],
      ];

  @override
  Future<void> reopenListeners(
      {required List<(String, String)> bridgeOptions}) async {
    if (!isAvailable) return;
    await _invoke<void>('reopenListeners',
        arguments: {'bridgeOptions': _pairs(bridgeOptions)});
  }

  @override
  Future<bool> circuitEstablished() async {
    if (!isAvailable) return false;
    return await _invoke<bool>('circuitEstablished') ?? false;
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
        return TorUp(host, port: port);
      case 'error':
        final msg = raw['lastError'];
        return TorErrored(msg is String ? msg : 'Tor failed.');
      default:
        return TorErrored('Unknown Tor state: $state');
    }
  }
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
        if (line != null) logTorLine(line);
      },
      // An error on the channel must not tear the subscription down: this
      // is the surface that explains a failing bootstrap, and losing it
      // exactly when tor is unhappy is the case it exists for.
      onError: (Object error) => LogTag.tor.warning(
          'Log channel error: $error'),
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
    this.builtInOffered = false,
  })  : assert(embedded != null || external != null),
        _embedded = embedded,
        _externalEngine = external,
        _externalRuntime = externalRuntime {
    _externalActive = _resolveExternal();
    _logs.start();
    for (final engine in [embedded, external].nonNulls) {
      _engineSubs.add(engine.statusStream.listen((s) {
        if (identical(engine, _engine)) _forward(s);
      }));
    }
  }

  static TorService? _instance;

  static TorService get instance => _instance ??= _production();

  /// Whether the external tor is wanted (TOR-025). Installed at startup from
  /// the Tor (external) switch, and read again by [runtimeChoiceChanged].
  static bool Function() wantsExternal = _never;

  static bool _never() => false;

  static TorService _production() {
    // Once, at launch: the Linux experiment's switch takes effect the next
    // time the app starts, as Texture page rendering's does.
    final offered = !kIsWeb &&
        builtInTorOffered(
          platform: defaultTargetPlatform,
          linuxExperiment: ExperimentalFeaturesService.instance
              .isEnabled(ExperimentalFeature.linuxTor),
        );
    final externalRuntime = externalTorRunsHere
        ? ExternalTorRuntime(
            address: () => ExternalTorSettings.address,
            identify: createExternalTorIdentify() ??
                (_, {required port}) async => ExternalTorAnswer.unreachable,
            control: _externalControlAccess(),
          )
        : null;
    final service = TorService._(
      embedded: TorEngine(
        runtime: _builtInRuntime(offered: offered),
        sessionSecret: newSessionSecret(),
        // The engine reads bridges itself rather than waiting for a startup
        // call to push them: nothing on a cold start opens the bridge
        // screen, so a pushed-only configuration was simply absent on every
        // relaunch (TOR-016).
        bridgeLoader: () => TorBridgeSecureStorage().loadIfReadable(),
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
      builtInOffered: offered,
    );
    // Here rather than in a screen, so every way back into the foreground
    // reaches it, whatever is on screen (TOR-024).
    WidgetsBinding.instance.addObserver(_TorResumeWatch(service));
    return service;
  }

  /// The built-in Tor: Tor.framework behind the Apple plugin's channels, or
  /// on Linux a tor the app starts as a child process (TOR-027). Linux with
  /// the experiment off, or with no tor to start, gets the channel runtime,
  /// which is not available there, so Tor is not offered (TOR-007).
  static TorRuntime _builtInRuntime({required bool offered}) =>
      (offered && !_hasNativeTor ? createManagedTorRuntime() : null) ??
      MethodChannelTorRuntime();

  /// How the external runtime reaches its tor's control port, where one
  /// can be named (TOR-026).
  static ExternalTorControlAccess? _externalControlAccess() {
    final connect = createTorControlConnect();
    final readCookie = createTorCookieRead();
    if (!externalTorControlRunsHere || connect == null || readCookie == null) {
      return null;
    }
    return ExternalTorControlAccess(
      endpoint: () => ExternalTorSettings.control,
      password: () => ExternalTorControlPasswordStorage().load(),
      connect: connect,
      readCookie: readCookie,
    );
  }

  /// Swap in an engine backed by a fake runtime. Tests only. Pass
  /// [external] when the engine's runtime is an [ExternalTorRuntime].
  @visibleForTesting
  static void overrideEngine(TorEngine engine,
      {ExternalTorRuntime? external, bool builtInOffered = false}) {
    _instance?._cancelSubs();
    _instance = external == null
        ? TorService._(embedded: engine, builtInOffered: builtInOffered)
        : TorService._(external: engine, externalRuntime: external);
  }

  /// Both engines, with [wantsExternal] choosing between them. Tests only.
  @visibleForTesting
  static void overrideEngines({
    required TorEngine embedded,
    required TorEngine external,
    required ExternalTorRuntime externalRuntime,
  }) {
    _instance?._cancelSubs();
    _instance = TorService._(
      embedded: embedded,
      external: external,
      externalRuntime: externalRuntime,
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

  /// Whether this platform offers a built-in Tor, as decided at launch
  /// ([builtInTorOffered]). Offered and not [isAvailable] is a Linux machine
  /// with no tor to start.
  final bool builtInOffered;

  final TorEngine? _embedded;
  final TorEngine? _externalEngine;
  final ExternalTorRuntime? _externalRuntime;
  final TorLogBridge _logs = TorLogBridge();
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
      unawaited(sub.cancel());
    }
    _engineSubs.clear();
  }

  // Every transition, in the app log. The runtime is a black box to the user
  // otherwise: "Starting" with no percentage and no phase is what a
  // bootstrap looks like from outside, whether it is 3 seconds in or 60
  // (TOR-018).
  void _forward(TorStatus s) {
    LogService.instance.log(
      LogTag.tor,
      message: 'State: $s',
      level: s is TorErrored ? LogLevel.error : LogLevel.info,
    );
    if (!_statuses.isClosed) _statuses.add(s);
  }

  /// Whether Tor here is an external tor rather than the embedded one
  /// (TOR-025). Bridges are the embedded tor's alone, so screens hide them
  /// when this is true.
  bool get isExternal => _externalActive;

  /// Whether exit countries and New circuits can be asked of the tor in
  /// use: the embedded one, or an external one the app holds a control
  /// channel to (TOR-026). Screens offer them only when this is true.
  bool get hasControlPort =>
      !_externalActive || externalControl is TorControlAttached;

  /// The app's control channel to the external tor (TOR-026).
  ExternalTorControlState get externalControl =>
      _externalRuntime?.controlState ?? const TorControlIdle();

  Stream<ExternalTorControlState> get externalControlStream =>
      _externalRuntime?.controlStates ??
      const Stream<ExternalTorControlState>.empty();

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
        await _switchTo(external: _resolveExternal());
      } while (_switchAgain);
    } finally {
      _switching = false;
    }
  }

  bool _switching = false;
  bool _switchAgain = false;

  Future<void> _switchTo({required bool external}) async {
    if (external == _externalActive) return;
    final from = _engine;
    final holders = from.holders.toSet();
    _externalActive = external;
    LogTag.tor.debug(
        'Switched to the ${external ? 'external' : 'built-in'} tor');
    _forward(_engine.status);
    await from.syncHolders(const <TorHolder>[]);
    // An external tor left behind gets back whatever exit pin the app put
    // in it (TOR-026). Stopping it costs a probe on the way back; the
    // embedded one is never stopped (TOR-020).
    if (identical(from, _externalEngine)) await _externalRuntime?.stop();
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

  /// Ask the external tor again after its address or its control port
  /// changed. Nothing to ask while nothing has used it: the next start
  /// reads both anyway.
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

  /// Run [use] with Tor held for [holder], after giving the runtime up to
  /// [within] to come up or fail. A connection test of a Tor route the user
  /// has not saved has nothing else holding Tor (PROXY-019).
  Future<T> whileHeld<T>(
    TorHolder holder, {
    required Duration within,
    required Future<T> Function() use,
  }) async {
    await maybeStart(holder);
    try {
      if (isAvailable) await _engine.settled(within: within);
      return await use();
    } finally {
      release(holder);
    }
  }

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

  /// What a site (or app-global traffic when [siteId] is null) dials through
  /// Tor, or why it may not — the caller must fail closed.
  ///
  /// Blocked on a platform with no runtime, which is the fail-closed answer:
  /// a site carrying `ProxyType.TOR` imported from an Apple device is
  /// blocked, never quietly sent out over the device IP.
  TorRoute routeFor({SiteId? siteId}) => isAvailable
      ? _engine.routeFor(TorEngine.tagFor(siteId))
      : const TorRouteBlocked(
          'This build has no Tor of its own, and no external tor is chosen.');

  /// [routeFor]'s settings, or null when Tor is not routable.
  UserProxySettings? socksFor({SiteId? siteId}) =>
      switch (routeFor(siteId: siteId)) {
        TorRouteUp(:final socks) => socks,
        TorRouteBlocked() => null,
      };

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
