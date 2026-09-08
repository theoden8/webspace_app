// Lifecycle and stream-isolation rules for the embedded Tor runtime, with no
// platform channel, no Flutter and no dart:io in sight. The native binding
// lives in tor_service.dart; everything decidable without a running tor is
// decided here so it can be tested against a fake runtime.
//
// Spec: openspec/specs/tor-proxy/spec.md (TOR-002 lifecycle, TOR-003 stream
// isolation, TOR-008 fail-closed).

import 'dart:async';

import 'package:webspace/services/tor_failure.dart';
import 'package:webspace/settings/proxy.dart';

export 'package:webspace/services/tor_failure.dart'
    show TorFailure, TorFailureKind, classifyTorFailure;

/// Reserved SOCKS5 username for app-global Dart-side traffic (blocklist
/// downloads, filter lists, map tiles). Never a real `siteId`, so app-global
/// fetches can't be correlated with any site's circuit (TOR-003).
const String kTorAppGlobalTag = '__webspace_app_global__';

/// How long the runtime stays up after the last client releases it. Long
/// enough to cover a webspace switch or a quick toggle-off-toggle-on without
/// paying another 10-30s bootstrap.
const Duration kTorIdleDebounce = Duration(seconds: 60);

/// How long `bootstrapping` may last before the engine gives up. Past this
/// the network is censored, broken, or the directory authorities are
/// unreachable; an unbounded wait would read to the user (and to App Review)
/// as a frozen feature. See TOR-013.
const Duration kTorBootstrapTimeout = Duration(seconds: 90);

/// Observable state of the runtime.
sealed class TorStatus {
  const TorStatus();

  /// Whether the SOCKS5 endpoint can carry traffic right now.
  bool get isUp => this is TorUp;
}

class TorStopped extends TorStatus {
  const TorStopped();
  @override
  String toString() => 'stopped';
}

class TorStarting extends TorStatus {
  const TorStarting();
  @override
  String toString() => 'starting';
}

class TorBootstrapping extends TorStatus {
  const TorBootstrapping(this.percent, {this.tag, this.summary});
  final int percent;

  /// tor's `BOOTSTRAP TAG` for the phase it is in (`conn_dir`,
  /// `loading_descriptors`, `circuit_create`, …). Kept because where
  /// bootstrap stalls is most of what distinguishes a censored network
  /// from a merely slow one.
  final String? tag;

  /// tor's human-readable `SUMMARY` for the phase.
  final String? summary;

  @override
  String toString() =>
      'bootstrapping($percent%${tag == null ? '' : ', $tag'})';
}

class TorUp extends TorStatus {
  const TorUp(this.host, this.port);
  final String host;
  final int port;
  @override
  String toString() => 'up($host:$port)';
}

class TorErrored extends TorStatus {
  TorErrored(String message, {TorFailure? failure})
      : failure = failure ?? classifyTorFailure(message);

  /// The classified failure. Built from [message] when the caller has no
  /// richer signals, so every construction site keeps working while the
  /// ones that do have tor's bootstrap fields can pass a real [TorFailure].
  final TorFailure failure;

  String get message => failure.detail;
  TorFailureKind get kind => failure.kind;

  @override
  String toString() => 'error($failure)';
}

/// The side of the runtime the engine cannot decide for itself. Implemented
/// by the method-channel binding in production and by a fake in tests.
abstract class TorRuntime {
  /// Whether this build/platform has a Tor runtime at all.
  bool get isAvailable;

  /// Spawn tor. Resolves once the thread is running; bootstrap progress
  /// arrives asynchronously on [events].
  Future<void> start();

  /// Tear tor down and release the loopback port.
  Future<void> stop();

  /// `SIGNAL NEWNYM`. Rate-limiting is the runtime's business.
  Future<void> rebuildCircuits();

  /// Pin exits to [exitNodes] (tor's `ExitNodes` syntax, e.g. `{de}`) with
  /// `StrictNodes 1`, or clear both when null. Global to the tor instance:
  /// the caller is responsible for ensuring no site that disagrees is
  /// loaded (TOR-014).
  Future<void> applyExitCountry(String? exitNodes);

  /// Status pushed from the native side.
  Stream<TorStatus> get events;
}

/// Owns "is tor supposed to be running, and what should a caller dial".
///
/// Deliberately ignorant of *why* a client wants Tor: callers hold a
/// refcount by an opaque reason string (a `siteId`, or the global-proxy
/// tag), so a site toggled on twice can't double-count and a site deleted
/// mid-bootstrap can't leave the runtime pinned up forever.
class TorEngine {
  TorEngine({
    required TorRuntime runtime,
    required String sessionSecret,
    Duration idleDebounce = kTorIdleDebounce,
    Duration bootstrapTimeout = kTorBootstrapTimeout,
  })  : _runtime = runtime,
        _sessionSecret = sessionSecret,
        _idleDebounce = idleDebounce,
        _bootstrapTimeout = bootstrapTimeout {
    // Second gate, belt to the runtime's braces: a runtime with no plugin
    // behind it has nothing to say, and subscribing to find that out is
    // what threw MissingPluginException on Android.
    if (_runtime.isAvailable) {
      _sub = _runtime.events.listen(_onRuntimeStatus);
    }
  }

  final TorRuntime _runtime;
  final String _sessionSecret;
  final Duration _idleDebounce;
  final Duration _bootstrapTimeout;

  final Set<String> _holders = <String>{};
  final StreamController<TorStatus> _statuses =
      StreamController<TorStatus>.broadcast();
  StreamSubscription<TorStatus>? _sub;
  Timer? _idleTimer;
  Timer? _bootstrapTimer;
  TorStatus _status = const TorStopped();
  String? _exitNodes;
  bool _exitNodesApplied = false;

  /// Last bootstrap progress seen, kept past the transition out of
  /// [TorBootstrapping] so a timeout can say where it stalled. Where it
  /// stopped is most of the difference between "censored" and "slow".
  int? _lastBootstrapPercent;
  String? _lastBootstrapTag;

  bool get isAvailable => _runtime.isAvailable;
  TorStatus get status => _status;
  Stream<TorStatus> get statusStream => _statuses.stream;

  /// Reason strings currently pinning the runtime up. Diagnostics only.
  Set<String> get holders => Set.unmodifiable(_holders);

  /// Register [reason] as needing Tor, starting the runtime on the 0 -> 1
  /// transition and canceling any pending idle shutdown (TOR-002).
  Future<void> acquire(String reason) async {
    if (!_runtime.isAvailable) return;
    final wasEmpty = _holders.isEmpty;
    if (!_holders.add(reason)) return;
    _idleTimer?.cancel();
    _idleTimer = null;
    if (!wasEmpty) return;
    if (_status is TorUp || _status is TorStarting) return;
    _emit(const TorStarting());
    _armBootstrapTimeout();
    try {
      await _runtime.start();
    } catch (e) {
      _cancelBootstrapTimeout();
      _emit(TorErrored('$e'));
    }
  }

  /// Drop [reason]'s claim. On the last release the runtime stays up for
  /// [kTorIdleDebounce] so a reactivation inside the window is free.
  void release(String reason) {
    if (!_holders.remove(reason)) return;
    if (_holders.isNotEmpty) return;
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleDebounce, () {
      _idleTimer = null;
      // Re-check rather than trust the timer: a client may have acquired
      // and released again while it was pending.
      if (_holders.isNotEmpty) return;
      _cancelBootstrapTimeout();
      _runtime.stop().catchError((_) {});
      // tor is gone, so whatever ExitNodes it held is gone with it; the pin
      // must be re-applied to the next instance rather than assumed live.
      _exitNodesApplied = false;
      _emit(const TorStopped());
    });
  }

  /// Replace the whole holder set in one shot. Used by the startup scan and
  /// after bulk edits (settings import, site deletion) where computing the
  /// delta at the call site would just be a worse version of this.
  Future<void> syncHolders(Iterable<String> reasons) async {
    final next = reasons.toSet();
    for (final gone in _holders.difference(next).toList()) {
      release(gone);
    }
    for (final added in next.difference(_holders).toList()) {
      await acquire(added);
    }
  }

  Future<void> rebuildCircuits() async {
    if (!_status.isUp) return;
    await _runtime.rebuildCircuits();
  }

  /// Tear the runtime down and start it again, keeping the holder set.
  ///
  /// This is what a Retry needs and what [acquire] cannot provide: acquire
  /// returns early whenever the holder set is already non-empty, which it
  /// always is for a site pinned to TOR, so retrying through it was a no-op
  /// and the button was left out of the first cut rather than shipped inert.
  /// Stopping first also discards whatever half-state the failure left —
  /// a control connection attached to a dead thread, a consensus that never
  /// finished downloading — which a bare re-start would inherit.
  Future<void> restart() async {
    if (!_runtime.isAvailable) return;
    if (_holders.isEmpty) return;
    _cancelBootstrapTimeout();
    _lastBootstrapPercent = null;
    _lastBootstrapTag = null;
    // The pin has to be re-applied to whatever instance comes back; the one
    // that dies takes its SETCONF with it.
    _exitNodesApplied = false;
    try {
      await _runtime.stop();
    } catch (_) {
      // A stop that fails on an already-dead runtime must not block the
      // restart that is the entire point of this call.
    }
    _emit(const TorStarting());
    _armBootstrapTimeout();
    try {
      await _runtime.start();
    } catch (e) {
      _cancelBootstrapTimeout();
      _emit(TorErrored('$e'));
    }
  }

  /// The exit-country pin currently in force, in tor's `ExitNodes` syntax.
  String? get exitNodes => _exitNodes;

  /// Pin every circuit to [exitNodes], or clear the pin when null.
  ///
  /// Deferred until the runtime is up: `SETCONF` needs a live control port,
  /// and a pin set before then would be silently dropped. `_exitNodesApplied`
  /// tracks whether the value in `_exitNodes` has actually reached tor, so
  /// the deferred apply on reaching `up` is not mistaken for a no-op.
  Future<void> setExitCountry(String? exitNodes) async {
    if (!_runtime.isAvailable) return;
    if (_exitNodes == exitNodes && _exitNodesApplied) return;
    _exitNodes = exitNodes;
    _exitNodesApplied = false;
    await _flushExitCountry();
  }

  Future<void> _flushExitCountry() async {
    if (!_status.isUp) return;
    try {
      await _runtime.applyExitCountry(_exitNodes);
      _exitNodesApplied = true;
    } catch (e) {
      // A pin that did not land must not be reported as in force: the user
      // would believe traffic is leaving from a country it is not.
      _exitNodesApplied = false;
      _emit(TorErrored(
        'Could not apply the exit-country pin: $e',
        failure: classifyTorFailure(
          'Could not apply the exit-country pin: $e',
          hadExitPin: true,
        ),
      ));
    }
  }

  /// Materialize the SOCKS5 settings [reason] should dial (TOR-003).
  ///
  /// Returns null when the runtime is not up: callers must fail closed
  /// rather than fall through to a direct connection. The username is the
  /// isolation tag, so two reasons never share a circuit.
  UserProxySettings? socksFor(String reason) {
    final s = _status;
    if (s is! TorUp) return null;
    return UserProxySettings(
      type: ProxyType.SOCKS5,
      address: '${s.host}:${s.port}',
      username: reason,
      password: _sessionSecret,
    );
  }

  /// Isolation tag for a site, or the app-global tag when [siteId] is
  /// absent. Kept here so call sites can't invent their own tag scheme.
  static String tagFor(String? siteId) =>
      (siteId == null || siteId.isEmpty) ? kTorAppGlobalTag : siteId;

  void _onRuntimeStatus(TorStatus s) {
    if (s is TorUp || s is TorErrored) _cancelBootstrapTimeout();
    if (s is TorBootstrapping) {
      _lastBootstrapPercent = s.percent;
      _lastBootstrapTag = s.tag ?? _lastBootstrapTag;
    }

    // A late status from a runtime we already shut down must not resurrect
    // it; without this an in-flight bootstrap event racing `stop()` leaves
    // the engine reporting `up` against a dead listener.
    if (_holders.isEmpty && _idleTimer == null && s is! TorStopped) return;
    _emit(s);
    // Only past the resurrection guard, and only once `_status` really is
    // up: a pin requested before bootstrap finished has been waiting for a
    // control port, and now there is one. Assigning `_status` here directly
    // would step around the guard above and revive a shut-down runtime.
    // Only when there is a pin to (re-)establish. A fresh tor has no
    // ExitNodes of its own, so pushing a reset on every bootstrap would be
    // a SETCONF round trip that changes nothing.
    if (s is TorUp && _exitNodes != null && !_exitNodesApplied) {
      Future.microtask(_flushExitCountry);
    }
  }

  void _armBootstrapTimeout() {
    _bootstrapTimer?.cancel();
    _bootstrapTimer = Timer(_bootstrapTimeout, () {
      _bootstrapTimer = null;
      if (_status is TorUp) return;
      _runtime.stop().catchError((_) {});
      // Where it stalled is the signal: a deadline hit in the directory
      // phase is what a censoring network looks like, while one past
      // circuit-building with a strict exit pin in force is the pin.
      _emit(TorErrored(
        'Tor did not finish bootstrapping in time.',
        failure: classifyTorFailure(
          'Tor did not finish bootstrapping in time.',
          torTag: _lastBootstrapTag,
          atPercent: _lastBootstrapPercent,
          hadExitPin: _exitNodes != null,
          timedOut: true,
        ),
      ));
    });
  }

  void _cancelBootstrapTimeout() {
    _bootstrapTimer?.cancel();
    _bootstrapTimer = null;
  }

  void _emit(TorStatus s) {
    _status = s;
    if (!_statuses.isClosed) _statuses.add(s);
  }

  Future<void> dispose() async {
    _idleTimer?.cancel();
    _cancelBootstrapTimeout();
    await _sub?.cancel();
    _sub = null;
    await _statuses.close();
  }
}
