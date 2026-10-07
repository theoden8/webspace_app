// Lifecycle and stream-isolation rules for the embedded Tor runtime, with no
// platform channel, no Flutter and no dart:io in sight. The native binding
// lives in tor_service.dart; everything decidable without a running tor is
// decided here so it can be tested against a fake runtime.
//
// Spec: openspec/specs/tor-proxy/spec.md (TOR-002 lifecycle, TOR-003 stream
// isolation, TOR-008 fail-closed).

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:webspace/services/tor_bridges.dart';
import 'package:webspace/services/tor_failure.dart';
import 'package:webspace/services/tor_geoip.dart';
import 'package:webspace/services/tor_holders.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/utils/concurrency.dart';

export 'package:webspace/services/tor_bridges.dart'
    show TorBridgeConfig, TorBridgeLine, TorTransport, parseTorBridgeLine;
export 'package:webspace/services/tor_failure.dart'
    show TorFailure, TorFailureKind, classifyTorFailure;

/// Reserved SOCKS5 username for app-global Dart-side traffic (blocklist
/// downloads, filter lists, map tiles). Never a real `siteId`, so app-global
/// fetches can't be correlated with any site's circuit (TOR-003).
const String kTorAppGlobalTag = '__webspace_app_global__';

/// How long a released runtime is still treated as claimed, so a webspace
/// switch or a quick toggle-off-toggle-on does not look like an idle
/// runtime. It no longer ends in a stop: see [TorEngine.release].
const Duration kTorIdleDebounce = Duration(seconds: 60);

/// How long `bootstrapping` may last before the engine gives up. Past this
/// the network is censored, broken, or the directory authorities are
/// unreachable; an unbounded wait would read to the user (and to App Review)
/// as a frozen feature. See TOR-013.
const Duration kTorBootstrapTimeout = Duration(seconds: 90);

/// Bootstrap tag the engine publishes while tor is up but a requested exit
/// pin has not landed yet. tor is connected; the sites are not allowed to
/// use it until their country is in force (TOR-014).
const String kTorExitPinTag = 'exit_country';

/// Thrown by [TorRuntime.applyExitCountry] when tor's consensus has no exit
/// in the country the pin names. Under such a pin tor builds no circuit at
/// all, so the runtime refuses it before tor sees it (TOR-014); the sites
/// pinned there stay blocked, and the remedy is another country.
class TorExitCountryEmpty implements Exception {
  const TorExitCountryEmpty(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Thrown by [TorRuntime.applyExitCountry] when the runtime cannot pin exits
/// at all: an external tor started outside the app, reached over SOCKS with
/// no control port (TOR-025). The pinned sites stay blocked rather than
/// leave from a country nobody chose.
class TorExitPinUnsupported implements Exception {
  const TorExitPinUnsupported(this.message);

  final String message;

  @override
  String toString() => message;
}

/// How long tor gets to load a GeoIP table and take a pin. A control
/// connection that dropped mid-command never answers, and every later pin
/// change queues behind this one.
const Duration kTorExitPinApplyTimeout = Duration(seconds: 30);

/// Bootstrap tag the engine publishes while tor reopens a SOCKS listener
/// the app's suspension killed (TOR-024).
const String kTorReopenTag = 'reopen';

/// How long reopening tor's listeners may take before it counts as failed.
const Duration kTorReopenTimeout = Duration(seconds: 30);

/// How late the bootstrap deadline may fire before the engine reads it as
/// the app having been suspended through it rather than tor being slow. A
/// busy isolate delays a timer by moments; a suspension by minutes.
const Duration kTorSuspendedSlack = Duration(seconds: 15);

/// Whether a SOCKS5 listener at [host]:[port] answers a greeting.
typedef TorSocksProbe = Future<bool> Function(String host, int port);

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

/// The loopback endpoint a webview would be bound to for [status], or null
/// when there is nothing to bind to.
String? torSocksEndpoint(TorStatus status) =>
    status is TorUp ? '${status.host}:${status.port}' : null;

/// Whether a webview bound while the runtime was [previous] has to be rebuilt
/// now that it is [next].
///
/// The binding is frozen at WebView construction on iOS and macOS, so the
/// question is whether the endpoint changed — not whether the runtime is up.
/// A restart hands out a fresh loopback port, and tor's own port is chosen by
/// the OS, so Up -> Up is a different address more often than not. A webview
/// left on the old one reaches nothing, and TOR-008 keeps it from falling
/// back to direct, so the site simply never loads until the app is restarted.
bool torBindingChanged(TorStatus previous, TorStatus next) =>
    torSocksEndpoint(previous) != torSocksEndpoint(next);

/// What the interstitial in front of a Tor-bound site has to say, which the
/// runtime's own [TorStatus] cannot answer on its own.
///
/// `stopped` is a moment inside a start-up where Tor can run, and forever
/// where the platform has no plugin (TOR-007): every start path returns
/// before the engine emits [TorStarting]. A screen that reads the status
/// alone shows a progress bar for a wait that never ends.
enum TorGate {
  /// The runtime can come up and is on its way; a progress bar means
  /// something.
  working,

  /// Tor failed. The interstitial offers Retry and, where they help,
  /// bridges.
  errored,

  /// No embedded Tor on this platform. Nothing the user does on this screen
  /// will start one; the site's proxy is what has to change.
  unsupported,
}

/// Which [TorGate] a site is sitting behind.
///
/// Availability is read before [status] on purpose: Retry on a platform with
/// no runtime would do nothing, because `restart()` returns at the same gate.
TorGate torGateFor({
  required TorStatus status,
  required bool hasNativeTor,
}) {
  if (!hasNativeTor) return TorGate.unsupported;
  if (status is TorErrored) return TorGate.errored;
  return TorGate.working;
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
  ///
  /// [geoipFile] is loaded first. A country pin is refused, and throws,
  /// unless tor then has a GeoIP table. Either way every circuit that
  /// carried exit traffic before the change is closed, so no open
  /// connection keeps leaving from the old country.
  Future<void> applyExitCountry(String? exitNodes, {String? geoipFile});

  /// Start the pluggable transport named [transport] and return the loopback
  /// port its SOCKS listener bound to, or 0 when it failed to start.
  ///
  /// The port is allocated by IPtProxy at start time, so only the native
  /// side can know it — which is why this is a round trip rather than a
  /// constant. Dart then builds the torrc options around the returned port,
  /// keeping that logic in [torBridgeOptions] where it is tested, rather
  /// than reimplementing it in Swift.
  Future<int> startTransport(String transport);

  /// Extra torrc options to fold into the configuration on the next
  /// [start]. Replaces any previously set; an empty list clears them.
  ///
  /// Applied at start rather than by SETCONF because bridges have to be in
  /// force before bootstrap begins — configuring them afterwards would mean
  /// a bootstrap attempt over the direct guards the user is trying to avoid.
  Future<void> setTorrcOptions(List<(String, String)> options);

  /// Close tor's listeners and relay connections, open the listeners again,
  /// and publish `up` with the SOCKS endpoint tor now has (TOR-024). Throws
  /// when tor could not be reached or opened no listener.
  Future<void> reopenListeners();

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
    Future<TorBridgeConfig?> Function()? bridgeLoader,
    TorGeoIpStore? geoIpStore,
    DateTime Function()? clock,
    TorSocksProbe? socksProbe,
  })  : _runtime = runtime,
        _sessionSecret = sessionSecret,
        _idleDebounce = idleDebounce,
        _bootstrapTimeout = bootstrapTimeout,
        _bridgeLoader = bridgeLoader,
        _geoIpStore = geoIpStore,
        _clock = clock ?? DateTime.now,
        _socksProbe = socksProbe {
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

  final Set<TorHolder> _holders = <TorHolder>{};
  final StreamController<TorStatus> _statuses =
      StreamController<TorStatus>.broadcast();
  StreamSubscription<TorStatus>? _sub;
  Timer? _idleTimer;
  bool _disposed = false;
  Timer? _bootstrapTimer;
  TorStatus _status = const TorStopped();
  String? _exitNodes;
  bool _exitNodesApplied = false;

  /// The runtime's own last `up`, whatever the engine has published since.
  /// Differs from [_status] while a pin is pending or has failed: tor is
  /// connected, and the sites are held off it.
  TorUp? _runtimeUp;

  /// Pin changes, one at a time. Two in flight could land in tor out of
  /// order and leave the older one in force.
  final SerialQueue _pins = SerialQueue();

  /// Where the GeoIP table for a country pin comes from. Null where the
  /// runtime is expected to have its own.
  final TorGeoIpStore? _geoIpStore;
  final DateTime Function() _clock;

  /// Asks tor's SOCKS listener whether it is alive. Null where nothing can
  /// suspend the app out from under it (tests that do not care).
  final TorSocksProbe? _socksProbe;

  /// The app came back while tor was not up yet, so the listener tor
  /// reports when it is may be one the suspension already killed.
  bool _checkNextUp = false;

  bool get _pinPending => _exitNodes != null && !_exitNodesApplied;

  /// False while every site wanting the pin is archive-tier (ARCH-006).
  bool _mayFetchGeoIp = true;

  /// Last bootstrap progress seen, kept past the transition out of
  /// [TorBootstrapping] so a timeout can say where it stalled. Where it
  /// stopped is most of the difference between "censored" and "slow".
  int? _lastBootstrapPercent;
  String? _lastBootstrapTag;

  /// Bridge configuration to put in force on the next start. Held rather
  /// than applied immediately: bridges only take effect at bootstrap, so
  /// changing them while tor is up needs a [restart] to mean anything.
  TorBridgeConfig _bridges = const TorBridgeConfig();

  /// Reads the persisted bridge configuration, or null where nothing
  /// persists it (tests, and platforms with no runtime). The read answers
  /// null when the keystore refused.
  ///
  /// The engine pulls rather than waiting to be pushed. Bridges live in the
  /// keystore precisely so they survive a relaunch, and an in-memory field
  /// seeded only by the settings screen does not: nothing on a cold start
  /// visits that screen, so a user with obfs4 configured got a bridgeless
  /// bootstrap straight to the public directory authorities — from their
  /// real IP, while the screen still showed the toggle on and the card said
  /// "connected". Hydrating here rather than at a startup call site makes
  /// that unmissable, since every start already funnels through
  /// [_applyBridgeConfig].
  final Future<TorBridgeConfig?> Function()? _bridgeLoader;

  /// Whether [_bridges] reflects storage yet. Set by the first load and by
  /// any [setBridges]: an explicit set is the user acting now, so it wins
  /// over a re-read and is not overwritten by one.
  bool _bridgesHydrated = false;

  bool get isAvailable => _runtime.isAvailable;
  TorStatus get status => _status;
  Stream<TorStatus> get statusStream => _statuses.stream;

  /// What currently pins the runtime up.
  Set<TorHolder> get holders => Set.unmodifiable(_holders);

  /// Register [holder] as needing Tor, starting the runtime on the 0 -> 1
  /// transition and canceling any pending idle shutdown (TOR-002).
  Future<void> acquire(TorHolder holder) async {
    if (!_runtime.isAvailable) return;
    final wasEmpty = _holders.isEmpty;
    if (!_holders.add(holder)) return;
    _idleTimer?.cancel();
    _idleTimer = null;
    if (!wasEmpty) return;
    // A tor that is up behind a pending or failed pin is still up: starting
    // it again would publish `starting` over a runtime that never answers.
    if (_runtimeUp != null || _status is TorStarting) return;
    _emit(const TorStarting());
    _armBootstrapTimeout();
    try {
      await _applyBridgeConfig();
      await _runtime.start();
    } catch (e) {
      _cancelBootstrapTimeout();
      _emit(TorErrored('$e'));
    }
  }

  /// Drop [holder]'s claim.
  ///
  /// The runtime is not stopped. tor runs at most once per process — the
  /// second `tor_run_main` dies in `threadpool_new` and never bootstraps
  /// (BUG-013) — so an idle stop spends the app's only launch to save
  /// nothing the user asked to save, and the next site pinned to Tor gets a
  /// runtime that cannot come back. A stop is therefore only worth making
  /// when the process is going away, which is [dispose].
  ///
  /// The debounce timer stays: it is what keeps a released-then-reacquired
  /// runtime from re-arming a bootstrap timeout mid-flight, and
  /// [_onRuntimeStatus] reads it to tell "nobody wants Tor" from "Tor was
  /// never wanted".
  void release(TorHolder holder) {
    if (!_holders.remove(holder)) return;
    if (_holders.isNotEmpty) return;
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleDebounce, () {
      _idleTimer = null;
    });
  }

  /// Replace the whole holder set in one shot. Used by the startup scan and
  /// after bulk edits (settings import, site deletion) where computing the
  /// delta at the call site would just be a worse version of this.
  Future<void> syncHolders(Iterable<TorHolder> holders) async {
    final next = holders.toSet();
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

  /// Make sure the runtime still carries traffic now that the app is back
  /// (TOR-024).
  ///
  /// iOS defuncts every TCP socket a suspended app owns. tor survives it,
  /// and so does its control channel, a Unix socket for that reason; its
  /// SOCKS listener and its relay connections do not, and tor goes on
  /// listing the dead listener as its own. So the listener is asked. One
  /// that does not answer is reopened, and the endpoint the runtime then
  /// publishes is new, which rebuilds every Tor-bound site
  /// ([torBindingChanged]). A runtime still bootstrapping is asked when it
  /// comes up.
  Future<void> revive() async {
    if (!_runtime.isAvailable || _disposed || _socksProbe == null) return;
    final up = _runtimeUp;
    if (up == null) {
      _checkNextUp = true;
      return;
    }
    await _reopenIfDead(up);
  }

  /// Whether [up]'s listener answered. When it did not, it has been
  /// reopened or the failure published, and the `up` for the new listener
  /// arrives from the runtime like any other; nothing here re-publishes one.
  Future<bool> _reopenIfDead(TorUp up) async {
    final probe = _socksProbe;
    if (probe == null) return true;
    if (await probe(up.host, up.port)) return true;
    if (_disposed || !identical(_runtimeUp, up)) return false;
    // Held like a pin change: the listener the sites are bound to is gone,
    // and the one coming is on another port.
    _emit(const TorBootstrapping(100, tag: kTorReopenTag));
    try {
      await _runtime.reopenListeners().timeout(kTorReopenTimeout);
    } catch (e) {
      if (_disposed || !identical(_runtimeUp, up)) return false;
      final message = e is TimeoutException
          ? 'Tor did not reopen its SOCKS listener after the app was suspended.'
          : 'Tor could not reopen its SOCKS listener after the app was '
              'suspended: $e';
      _emit(TorErrored(message));
    }
    return false;
  }

  /// The bridge configuration currently in force, or queued for next start.
  TorBridgeConfig get bridges => _bridges;

  /// Set the bridge configuration.
  ///
  /// Takes effect on the next start. Returns whether a [restart] is needed
  /// for it to apply — true when tor is already running, since bridges are
  /// only read at bootstrap. The caller decides whether to restart: doing it
  /// implicitly would tear down every site's circuits as a side effect of
  /// editing a text field.
  bool setBridges(TorBridgeConfig config) {
    _bridges = config;
    _bridgesHydrated = true;
    return _status is TorUp || _status is TorBootstrapping;
  }

  /// Pull the persisted configuration in, once, before the first start that
  /// needs it.
  ///
  /// A keystore that refused leaves the default (bridges off) for this start
  /// rather than refusing to start Tor, and stays un-hydrated so a later
  /// start asks again rather than keeping bridges off for the process
  /// lifetime (BUG-027).
  Future<void> _hydrateBridges() async {
    if (_bridgesHydrated) return;
    final loader = _bridgeLoader;
    if (loader == null) {
      _bridgesHydrated = true;
      return;
    }
    final loaded = await loader();
    if (loaded == null) return;
    _bridges = loaded;
    _bridgesHydrated = true;
  }

  /// Put [_bridges] into force for the start that is about to happen.
  ///
  /// Starting the transport is what allocates its port, so it has to happen
  /// before the options can be built. A transport that fails to start yields
  /// port 0, and [torBridgeOptions] then produces nothing rather than a
  /// configuration pointing at a dead port — tor would otherwise hang the
  /// whole bootstrap dialling it.
  Future<void> _applyBridgeConfig() async {
    await _hydrateBridges();
    final config = _bridges;
    if (!config.enabled || !config.isUsable) {
      await _runtime.setTorrcOptions(const []);
      return;
    }
    int port = 0;
    try {
      port = await _runtime.startTransport(config.transport.wireName);
    } catch (e) {
      // A transport that will not start is not fatal on its own: falling
      // through with port 0 produces no bridge options, so tor starts
      // without bridges rather than not at all. On a censored network that
      // will fail at bootstrap and be reported as `censored`, which is the
      // honest outcome.
      port = 0;
    }
    await _runtime.setTorrcOptions(
      torBridgeOptions(config, transportPort: port),
    );
  }

  /// Tear the runtime down and start it again, keeping the holder set.
  ///
  /// This is what a Retry needs and what [acquire] cannot provide: acquire
  /// returns early whenever the holder set is already non-empty, which it
  /// always is for a site pinned to TOR, so retrying through it was a no-op.
  /// It does not stop tor first. It cannot: the second `tor_run_main` in a
  /// process dies in `threadpool_new` and never bootstraps (BUG-013), so a
  /// stop here would turn a recoverable failure into a permanent one. A tor
  /// that is still alive keeps retrying, and this re-arms the wait on it; a
  /// tor that is really gone answers [TorRuntime.start] with the one remedy
  /// left, which is to restart the app.
  Future<void> restart() async {
    if (!_runtime.isAvailable) return;
    if (_holders.isEmpty) return;
    // Already connected: nothing to retry. And blanking the status to
    // `starting` would strand it there — the runtime's `start()` is a no-op
    // while tor is alive, so no event would ever move it back, and the
    // bootstrap deadline would report a failure against a tor that is
    // working. A Retry must never be able to break a running runtime.
    if (_status is TorUp) return;
    // tor itself is up and only the exit pin or its listener is not: retry
    // those. A stop and start could not help, and the start would be a
    // no-op that left the status on `starting` for good.
    final up = _runtimeUp;
    if (up != null) {
      if (await _reopenIfDead(up)) await _flushExitCountry();
      return;
    }
    _cancelBootstrapTimeout();
    _lastBootstrapPercent = null;
    _lastBootstrapTag = null;
    // The pin has to be re-applied to whatever instance comes back; the one
    // that dies takes its SETCONF with it.
    _exitNodesApplied = false;
    _emit(const TorStarting());
    _armBootstrapTimeout();
    try {
      // Still applied: `start()` is a no-op on a live tor, and on a dead one
      // this is what the launch would need. It never reaches a tor that is
      // already running — that is what makes an edited bridge configuration
      // an app restart rather than a Retry.
      await _applyBridgeConfig();
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
  ///
  /// From this call until the change is in force the engine does not
  /// publish `up`: every Tor-bound site waits behind the interstitial and
  /// Dart-side Tor fetches block, so nothing leaves through a country the
  /// user did not pick. The hold is published before this returns its
  /// future, which is what lets a caller not wait on it: the change is a
  /// control-port round trip, and one that never answers must not hold up
  /// anything but the Tor sites it concerns (BUG-018).
  ///
  /// With [mayFetchGeoIp] false the pin uses a GeoIP table already on the
  /// device and never downloads one; without one it fails closed.
  Future<void> setExitCountry(String? exitNodes,
      {bool mayFetchGeoIp = true}) async {
    if (!_runtime.isAvailable) return;
    _mayFetchGeoIp = mayFetchGeoIp;
    if (_exitNodes == exitNodes && _exitNodesApplied) return;
    // The same pin again after it failed is not a retry. This is called on
    // every save, and a retry means a 10 MB download; Retry is the
    // interstitial's button, which reaches [restart].
    if (_exitNodes == exitNodes && _status is TorErrored) return;
    _exitNodes = exitNodes;
    _exitNodesApplied = false;
    if (_runtimeUp != null && !_disposed) _holdForPin();
    await _flushExitCountry();
  }

  void _holdForPin() {
    if (!identical(_status, _pinHold)) _emit(_pinHold);
  }

  static const TorStatus _pinHold =
      TorBootstrapping(100, tag: kTorExitPinTag);

  Future<void> _flushExitCountry() => _pins.run(_applyPin);

  Future<void> _applyPin() async {
    final up = _runtimeUp;
    if (up == null || _disposed) return;
    if (_exitNodesApplied) {
      if (!identical(_status, up)) _emit(up);
      return;
    }
    final pin = _exitNodes;
    bool superseded() =>
        _disposed || _exitNodes != pin || !identical(_runtimeUp, up);

    _holdForPin();
    String? geoipFile;
    if (pin != null) {
      final store = _geoIpStore;
      if (store != null) {
        geoipFile = await _geoIpTable(store, up);
        if (superseded()) return;
        if (geoipFile == null) {
          final message = _mayFetchGeoIp
              ? 'Could not download the GeoIP table an exit-country pin '
                  'needs, so the pin was not applied.'
              : 'No GeoIP table is kept on this device, and a site in an '
                  'archived webspace never downloads one, so the exit-country '
                  'pin was not applied.';
          _emit(TorErrored(message,
              failure: classifyTorFailure(message, hadExitPin: true)));
          return;
        }
      }
    }

    try {
      await _runtime
          .applyExitCountry(pin, geoipFile: geoipFile)
          .timeout(kTorExitPinApplyTimeout);
    } on TimeoutException {
      if (superseded()) return;
      // A control socket iOS reclaimed while the app was suspended takes
      // the command and never answers (BUG-018). The change is not in
      // force, so this fails closed like any other refusal.
      const message = 'Tor did not answer on its control port while the exit '
          'country was being changed, so the change is not in force.';
      _emit(TorErrored(message,
          failure: classifyTorFailure(message, hadExitPin: pin != null)));
      return;
    } on TorExitCountryEmpty catch (e) {
      if (superseded()) return;
      // Not "could not apply": tor was reachable, and the country has no
      // exit. Left unapplied so a Retry counts the exits again.
      _emit(TorErrored(e.message,
          failure: TorFailure(kind: TorFailureKind.exitPolicy, detail: e.message)));
      return;
    } on TorExitPinUnsupported catch (e) {
      if (superseded()) return;
      _emit(TorErrored(e.message,
          failure: TorFailure(
              kind: TorFailureKind.externalExitPin, detail: e.message)));
      return;
    } catch (e) {
      if (superseded()) return;
      // A pin that did not land must not be reported as in force: the user
      // would believe traffic is leaving from a country it is not.
      _emit(TorErrored(
        'Could not apply the exit-country pin: $e',
        failure: classifyTorFailure(
          'Could not apply the exit-country pin: $e',
          hadExitPin: true,
        ),
      ));
      return;
    }
    if (superseded()) return;
    _exitNodesApplied = true;
    if (!identical(_status, up)) _emit(up);
  }

  /// A GeoIP table for tor to load, downloading one when none is kept.
  ///
  /// The download rides Tor on its own isolation tag. It cannot go through
  /// [socksFor], which refuses every tag while a pin is pending; it has to
  /// happen *before* the pin, since a country tor cannot resolve leaves it
  /// no exit to download through. A kept table past [kTorGeoIpMaxAge] is
  /// used as it is and refreshed behind it, for the next pin to pick up.
  Future<String?> _geoIpTable(TorGeoIpStore store, TorUp up) async {
    final via = _socksAt(up, kTorGeoIpTag);
    final kept = await _orNull(store.newest());
    if (kept != null) {
      if (_mayFetchGeoIp && kept.isStale(_clock())) {
        unawaited(_orNull(store.download(via)));
      }
      return kept.path;
    }
    if (!_mayFetchGeoIp) return null;
    return (await _orNull(store.download(via)))?.path;
  }

  /// The store's disk failures read as "no table"; errors are bugs and are
  /// not swallowed.
  static Future<TorGeoIpTable?> _orNull(Future<TorGeoIpTable?> table) =>
      table.catchError((Object _) => null, test: (e) => e is Exception);

  /// Materialize the SOCKS5 settings [reason] should dial (TOR-003).
  ///
  /// Returns null when the runtime is not up: callers must fail closed
  /// rather than fall through to a direct connection. The username is the
  /// isolation tag, so two reasons never share a circuit.
  UserProxySettings? socksFor(String reason) {
    final s = _status;
    if (s is! TorUp) return null;
    return _socksAt(s, reason);
  }

  UserProxySettings _socksAt(TorUp up, String reason) => UserProxySettings(
        type: ProxyType.SOCKS5,
        address: '${up.host}:${up.port}',
        username: reason,
        password: _passwordFor(reason),
      );

  /// Per-reason SOCKS password, derived rather than shared.
  ///
  /// Isolation itself never depended on this: tor's `IsolateSOCKSAuth` keys
  /// circuits on the whole (username, password) tuple, and the usernames
  /// already differ, so one shared password still gave every site its own
  /// circuit. What it did not give is containment. The password's job is to
  /// be an unguessable seal, so that nothing else on loopback can dial the
  /// SOCKS port and join a site's circuit — and `siteId`s are not secret
  /// (they appear in exported settings and in logs). With one shared
  /// secret, anything that learned it could pair it with any siteId and ride
  /// that site's circuit. Deriving per reason confines such a leak to the
  /// one site it came from.
  ///
  /// HMAC keyed with the launch secret: deterministic within a launch (so a
  /// site keeps one stable circuit), different per reason, and not
  /// invertible back to the secret.
  String _passwordFor(String reason) {
    final mac = Hmac(sha256, utf8.encode(_sessionSecret));
    return mac.convert(utf8.encode(reason)).toString();
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

    if (s is TorUp) {
      _runtimeUp = s;
      // A fresh tor has no ExitNodes, so "no pin" is already in force.
      // Clearing it again would close every circuit, cutting the first
      // loads of whatever Tor sites are starting up.
      if (_exitNodes == null) _exitNodesApplied = true;
    } else if (s is TorStopped || s is TorErrored || s is TorStarting) {
      _runtimeUp = null;
      // The pin was a SETCONF on that run; whatever comes back has none.
      _exitNodesApplied = false;
    }

    // A late status from a runtime we already tore down must not resurrect
    // it, and must not reach a closed stream. Holders no longer say anything
    // about that: releasing the last one leaves tor running (see [release]),
    // so the only shutdown left is this engine's own.
    if (_disposed) return;
    if (s is TorUp) {
      // The app came back mid-bootstrap, and tor has just named a listener
      // it opened before the suspension. Asked before anything is bound to
      // it; a dead one is reopened and its successor arrives as a new `up`.
      if (_checkNextUp) {
        _checkNextUp = false;
        unawaited(_reopenIfDead(s).then((alive) {
          if (alive && !_disposed && identical(_runtimeUp, s)) _publishUp(s);
        }));
        return;
      }
      _publishUp(s);
      return;
    }
    _emit(s);
  }

  void _publishUp(TorUp s) {
    // A pin requested before bootstrap finished has been waiting for a
    // control port, and now there is one. `up` is not published until it
    // lands. Only when there is a pin to establish: a fresh tor has no
    // ExitNodes of its own, so a reset on every bootstrap would be a SETCONF
    // round trip that changes nothing.
    if (_pinPending) {
      _holdForPin();
      unawaited(_flushExitCountry());
      return;
    }
    _emit(s);
  }

  void _armBootstrapTimeout() {
    _bootstrapTimer?.cancel();
    final armedAt = _clock();
    _bootstrapTimer = Timer(_bootstrapTimeout, () {
      _bootstrapTimer = null;
      if (_status is TorUp) return;
      // A deadline that fires long after it was due slept through it: the
      // app was suspended, and tor with it. A background launch starts tor
      // and iOS suspends it seconds later, so the first thing the next wake
      // ran was this timer, reporting a bootstrap tor was never given time
      // for. The window starts over instead.
      if (_clock().difference(armedAt) > _bootstrapTimeout + kTorSuspendedSlack) {
        _armBootstrapTimeout();
        return;
      }
      // tor is left running. It keeps trying on its own, and this process
      // has no second launch to spend on stopping it (BUG-013): a stop here
      // is what turned "the network was down for a minute" into "Tor is
      // unavailable until you restart the app". The deadline is a report,
      // not a teardown.
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
    _disposed = true;
    _idleTimer?.cancel();
    _cancelBootstrapTimeout();
    await _sub?.cancel();
    _sub = null;
    await _statuses.close();
  }
}
