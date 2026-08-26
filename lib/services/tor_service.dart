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

import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/tor_engine.dart';
import 'package:webspace/settings/proxy.dart';

export 'package:webspace/services/tor_engine.dart'
    show
        TorStatus,
        TorStopped,
        TorStarting,
        TorBootstrapping,
        TorUp,
        TorErrored,
        kTorAppGlobalTag;

const String _kChannel = 'org.codeberg.theoden8.webspace/tor';
const String _kEvents = 'org.codeberg.theoden8.webspace/tor/events';

/// Method-channel implementation of [TorRuntime].
///
/// Only iOS ships the plugin in this release (TOR-007). On every other
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
  bool get isAvailable => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

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
  Stream<TorStatus> get events => _decoded ??= isAvailable
      ? _eventChannel.receiveBroadcastStream().map(decodeStatus)
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
        return TorBootstrapping(pct is int ? pct : 0);
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

/// Process-wide handle on the embedded Tor runtime.
class TorService {
  TorService._(this._engine);

  static TorService? _instance;

  /// The live singleton, created on first touch.
  static TorService get instance =>
      _instance ??= TorService._(TorEngine(
        runtime: MethodChannelTorRuntime(),
        sessionSecret: newSessionSecret(),
      ));

  /// Swap in an engine backed by a fake runtime. Tests only.
  @visibleForTesting
  static void overrideEngine(TorEngine engine) {
    _instance = TorService._(engine);
  }

  @visibleForTesting
  static Future<void> reset() async {
    await _instance?._engine.dispose();
    _instance = null;
  }

  final TorEngine _engine;

  bool get isAvailable => _engine.isAvailable;
  TorStatus get status => _engine.status;
  Stream<TorStatus> get statusStream => _engine.statusStream;

  /// `host:port` of the live SOCKS5 listener, or null when not up.
  String? get socksEndpoint {
    final s = _engine.status;
    return s is TorUp ? '${s.host}:${s.port}' : null;
  }

  Future<void> maybeStart(String reason) => _engine.acquire(reason);
  void release(String reason) => _engine.release(reason);
  Future<void> syncHolders(Iterable<String> reasons) =>
      _engine.syncHolders(reasons);
  Future<void> rebuildCircuits() => _engine.rebuildCircuits();

  /// SOCKS5 settings for a site (or app-global traffic when [siteId] is
  /// null). Null means "not routable yet" — the caller must fail closed.
  UserProxySettings? socksFor({String? siteId}) =>
      _engine.socksFor(TorEngine.tagFor(siteId));

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
