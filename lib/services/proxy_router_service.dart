import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:webspace/platform/host_platform.dart';
// Conditional so a UI file that reaches this service still compiles for
// web: the real adapter owns a `ServerSocket` (DESIGN-001).
import 'package:webspace/services/local_proxy_relay_api_web.dart'
    if (dart.library.io) 'package:webspace/services/local_proxy_relay_api.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/proxy_relay.dart';
import 'package:webspace/services/proxy_router_engine.dart';
import 'package:webspace/services/router_attribution.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/proxy.dart';

/// Points the process-wide WebView proxy at the relay on [host]:[port].
///
/// Runs after the routes are installed and BEFORE the attribution probe:
/// the probe travels that same process-wide proxy, so with the override
/// not yet applied it resolves its own hostname directly, never reaches
/// the relay, and reads as a failed attribution on every device.
typedef ProxyRouterOverrideBinder = Future<bool> Function(
    String host, {required int port});

/// Owns the per-site proxy router (PROXY-013): the relay lifecycle, the
/// per-site credentials, and the one question the WebView layer asks it at
/// runtime ("is this auth challenge yours, and what do I answer?").
///
/// Router mode replaces the serialisation Android needed under PROXY-008.
/// `ProxyController` still carries one process-wide rule, but that rule
/// now points at the relay for the whole app, and the relay fans traffic
/// out per site. Sites with different proxies can therefore stay loaded
/// at the same time.
///
/// **Apple takes the same router with a different delivery** (PROXY-026).
/// There is no process-wide rule to point: each container store carries its
/// own `proxyConfigurations` naming the relay, and the site's credential
/// rides `ProxyConfiguration.applyCredential` preemptively rather than
/// answering a `407`. The relay itself is the in-process
/// [`LocalProxyRelay`] instead of the Kotlin plugin.
///
/// `WKWebsiteDataStore.proxyConfigurations` carries two different proxies
/// at once: BUG-014 attempt 80 measured four container stores reaching four
/// distinct upstreams in one frame, two of them separated only by the credential
/// they presented to one relay endpoint, which is this design end to end.
///
/// Gated on container mode. Chromium caches a proxy credential per
/// `HttpNetworkSession`, and proxy entries are deliberately not
/// partitioned by `NetworkAnonymizationKey`, so the profile boundary is
/// the only thing keeping site A's credential off site B's connections.
/// Without `MULTI_PROFILE` every site shares one session and one cached
/// credential, which would route sites through each other's proxies. On
/// that path the app keeps the PROXY-008 unload instead.
class ProxyRouterService {
  static final ProxyRouterService instance = ProxyRouterService._();
  ProxyRouterService._();

  ProxyRelayApi? _relayOverride;

  /// Android drives the Kotlin relay plugin; everywhere else the relay is
  /// an in-process Dart socket. Resolved lazily so a test can substitute
  /// one before the platform is ever read.
  ProxyRelayApi get _relay =>
      _relayOverride ??= hostIsAndroid ? ProxyRelay.instance : LocalProxyRelayApi();
  ProxyRouterState? _state;
  String? _host;
  int? _port;

  /// This run's checks; null when no probe was supplied (tests only).
  RouterAttribution? _attribution;

  /// The table last asked for, which a late failed check reinstalls less
  /// the identities it failed.
  Map<RouterIdentity, UserProxySettings> _table = const {};

  /// The identities the relay routes right now.
  Set<RouterIdentity> _routed = const {};

  void setRelayForTest(ProxyRelayApi relay) {
    _relayOverride = relay;
  }

  void resetForTest() {
    _attribution?.end();
    _attribution = null;
    _table = const {};
    _routed = const {};
    _state = null;
    _host = null;
    _port = null;
    _proven = false;
  }

  /// [resetForTest], and the relay stopped.
  @visibleForTesting
  Future<void> stopForTest() async {
    _proven = false;
    await _standDown();
  }

  /// True once the relay is bound and holding a route table: it owns the
  /// process-wide rule and answers the challenges its credentials meet.
  bool get isActive => _state != null && _port != null && _host != null;

  /// Whether sites may run on different routes beside each other: the
  /// launch's checks have proved this device delivers per-site routing
  /// (PROXY-015), and router mode does not stand down for the rest of the
  /// run. Until then the relay is up but a site the user opens is placed
  /// as under PROXY-008, since a check that fails stands the relay down
  /// with every site it let load left on one rule (BUG-037).
  bool get routesPerSite => isActive && _proven;
  bool _proven = false;

  /// Loopback address the relay bound, or null. A random one in 127/8,
  /// so it is not interchangeable with `127.0.0.1`.
  String? get host => _host;

  /// Loopback port the WebView layer should be pointed at, or null.
  /// Android points its one `ProxyController` rule here; Apple points each
  /// container store's `proxyConfigurations` here instead.
  int? get port => _port;

  /// Realm the relay names in its `407`, or null when inactive.
  String? get realm => _state?.realm;

  /// Whether the Apple relay path runs at all. Off, and off by default.
  ///
  /// The relay exists because Android has exactly one process-wide
  /// `ProxyController` rule and Chromium caches a proxy credential per
  /// `HttpNetworkSession` without partitioning it, so per-site proxies there
  /// need something in front of them to fan out. Apple has neither problem:
  /// each container store carries its own `proxyConfigurations`, and
  /// BUG-014 measured that shape delivering distinct upstreams
  /// AND distinct credentials per store, on SOCKS5 and on HTTP CONNECT, at
  /// any frame and on later navigations. So on Apple the relay is a local
  /// TCP hop that buys nothing, while adding the credential-forwarding step
  /// that instance 3 of BUG-014 was a defect in. Apple binds its real
  /// upstream to the store directly instead (`userProxyToInappProxy`).
  ///
  /// For Tor that is also the stronger route: `IsolateSOCKSAuth` keys a
  /// circuit on the SOCKS credential tuple, and binding the site's own tuple
  /// to the store hands tor the real per-site identity rather than depending
  /// on the relay to re-present it upstream.
  ///
  /// The implementation stays for feature-parity testing: a test that has to
  /// drive the Apple relay path sets this true, so the two platforms' router
  /// behaviour can still be compared without a device.
  @visibleForTesting
  static bool appleRelayEnabled = false;

  /// Whether router mode runs: this platform and engine can run it, and the
  /// Proxy router switch in App settings > Network is on (PROXY-013).
  ///
  /// [useContainers] is the app's cached `ContainerNative.isSupported()`.
  /// Offered with developer mode on or off. Read once at activation, so a
  /// flip of the switch takes effect at next launch.
  static bool isSupported({required bool useContainers}) => isSupportedWhen(
        isAndroid: hostIsAndroid,
        isApple: hostIsIOS || hostIsMacOS,
        useContainers: useContainers,
        switchOn: AppPref.proxyRouter.value,
        appleRelayEnabled: appleRelayEnabled,
      );

  /// Whether router mode could run here with its switch on: the Network
  /// screen lists the switch only where this is true.
  static bool canRunHere({required bool useContainers}) => isSupportedWhen(
        isAndroid: hostIsAndroid,
        isApple: hostIsIOS || hostIsMacOS,
        useContainers: useContainers,
        switchOn: true,
        appleRelayEnabled: appleRelayEnabled,
      );

  /// [isSupported]'s decision without the platform reads, so the negative
  /// contract is assertable on any host — where the platform test alone
  /// would answer false and make any further assertion vacuous.
  ///
  /// [isApple] defaults false so the Android contract this started as is
  /// still written the same way, and a caller that has not thought about
  /// Apple cannot widen the gate by omission.
  /// [appleRelayEnabled] defaults false for the same reason [isApple] does:
  /// the Apple relay is off, and a caller that has not thought about it
  /// cannot widen the gate by omission. See [ProxyRouterService.appleRelayEnabled].
  static bool isSupportedWhen({
    required bool isAndroid,
    required bool useContainers,
    required bool switchOn,
    bool isApple = false,
    bool appleRelayEnabled = false,
  }) =>
      (isAndroid || (isApple && appleRelayEnabled)) && useContainers && switchOn;

  /// The credential a site presents to the relay, or null when router
  /// mode is not running (in which case the WebView must not answer any
  /// proxy challenge at all). This is the relay's map key.
  String? credentialFor(RouterIdentity identity) =>
      isActive ? _state!.credentialFor(identity) : null;

  /// The raw token half, for `HttpAuthResponse.password`. Chromium does
  /// its own base64, so the challenge answer carries the parts and the
  /// route table carries the encoded blob; both come from one token.
  String? tokenFor(RouterIdentity identity) =>
      isActive ? _state!.tokenFor(identity) : null;

  /// The username half. Carries no secret.
  String usernameFor(RouterIdentity identity) =>
      '${ProxyRouterEngine.usernamePrefix}$identity';

  /// Whether an `onReceivedHttpAuthRequest` challenge belongs to the
  /// relay. Delegates the policy to the engine so it stays testable
  /// without a device.
  bool ownsChallenge({required String? host, required String? realm}) {
    final expected = _state?.realm;
    if (!isActive || expected == null) return false;
    return ProxyRouterEngine.shouldAnswerChallenge(
      host: host,
      realm: realm,
      expectedRealm: expected,
      expectedHost: _host,
    );
  }

  /// Bind the relay and install the route table for [perSiteProxies].
  ///
  /// Callers gate on [isSupported] first; this method does not re-check
  /// the platform, which is what lets it be driven by a fake relay in
  /// tests. Returns the loopback port on success, or null if router mode
  /// could not be established. A null return is NOT permission to clear
  /// the proxy override: the caller must fall back to the PROXY-008 path,
  /// which still honours the user's per-site choice.
  Future<int?> activate({
    required Map<RouterIdentity, UserProxySettings> perSiteProxies,
    ProxyRouterOverrideBinder? bindOverride,
    ProxyAttributionProbe? probe,
  }) async {
    final state = _state ?? ProxyRouterState();
    final endpoint = await _relay.startRouter(state.realm);
    if (endpoint == null) {
      LogTag.proxy.error(
          'Router relay failed to bind (${_relay.lastError ?? 'no reason reported'}); '
          'falling back to serialised per-site proxy');
      return null;
    }
    final port = endpoint.port;
    _state = state;
    _host = endpoint.host;
    _port = port;
    final attribution = switch (probe) {
      final probe? => _checksWith(probe),
      null => null,
    };
    _attribution = attribution;
    if (attribution != null) await _relay.clearProbeResults();
    final installed = await _installRoutes(perSiteProxies);
    if (!installed) {
      LogTag.proxy.error(
          'Relay rejected the route table; not activating router mode');
      attribution?.end();
      _attribution = null;
      _host = null;
      _port = null;
      return null;
    }
    // Before the probe, not after: the probe's own traffic has to reach
    // the relay, and it only does once the process-wide proxy points
    // there. Binding afterwards makes every probe fail to resolve and
    // router mode unreachable on every device.
    if (bindOverride != null &&
        !await bindOverride(endpoint.host, port: port)) {
      LogTag.proxy
          .error('Proxy override did not apply; not activating router mode');
      await _standDown();
      return null;
    }
    // PROXY-015. Everything above proves the app WANTS per-site routing;
    // only the proof shows this device DELIVERS it. The launch waits for two
    // identities checked one after the other; the rest are checked after
    // it, and each webview waits for its own ([attributed]). Skipping the
    // check when no probe is supplied is deliberate for tests, but the app
    // must always pass one: without it a device that shares a proxy auth
    // cache across container profiles would route sites through each other
    // and nothing would say so.
    if (attribution != null &&
        !await attribution.prove([
          for (final identity in perSiteProxies.keys)
            if (_routed.contains(identity)) identity,
        ])) {
      LogTag.proxy.error('Attribution not proven; not activating router mode');
      await _standDown();
      return null;
    }
    _proven = true;

    LogTag.proxy.info('Router mode active on ${endpoint.host}:$port for '
        '${perSiteProxies.length} site(s)', sensitive: true);
    return port;
  }

  /// Whether a webview may present [identity]'s credential yet: this run
  /// has shown its profile presents its own (PROXY-015). A challenge waits
  /// here, so a site opened before its check ran is held until it has;
  /// nothing reaches its upstream in the meantime.
  ///
  /// A successful check also warms that profile's proxy auth cache, so a
  /// later service-worker request, which cannot answer a challenge itself
  /// (`AwHttpAuthHandler` cancels with no `WebContents`), already has a
  /// credential to send.
  Future<bool> attributed(RouterIdentity identity) async {
    if (!isActive || !_routed.contains(identity)) return false;
    final attribution = _attribution;
    if (attribution == null) return true;
    return attribution.attributed(identity);
  }

  RouterAttribution _checksWith(ProxyAttributionProbe probe) {
    late final RouterAttribution checks;
    return checks = RouterAttribution(
      probe: probe,
      observed: _relay.probeResults,
      onFailed: (failed) => _checkFailed(failed, by: checks),
    );
  }

  /// A check after the launch failed: [failed] stop routing, so the relay
  /// answers their credentials 502. Router mode stays up for every other
  /// identity; standing it down mid-run would move sites that are already
  /// loaded onto another route.
  void _checkFailed(Set<RouterIdentity> failed,
      {required RouterAttribution by}) {
    if (!identical(by, _attribution)) return;
    LogTag.proxy.error('${failed.length} routing identit'
        '${failed.length == 1 ? 'y' : 'ies'} failed attribution; their sites '
        'fail closed for this run');
    unawaited(_installRoutes(_table));
  }

  /// Re-install the route table after sites or proxies changed.
  ///
  /// Credentials of sites that disappeared are revoked, so a deleted
  /// site's token stops routing without restarting the relay.
  ///
  /// An identity new to this run is checked before a webview may present
  /// it (PROXY-015).
  Future<bool> refreshRoutes({
    required Map<RouterIdentity, UserProxySettings> perSiteProxies,
  }) async {
    if (!isActive) return false;
    final installed = await _installRoutes(perSiteProxies);
    _attribution?.enqueue(_routed);
    return installed;
  }

  Future<bool> _installRoutes(
    Map<RouterIdentity, UserProxySettings> perSiteProxies,
  ) async {
    final state = _state;
    if (state == null) return false;
    _table = perSiteProxies;
    final failed = _attribution?.failed ?? const <RouterIdentity>{};
    final routable = {
      for (final e in perSiteProxies.entries)
        if (!failed.contains(e.key)) e.key: e.value,
    };
    state.retainOnly(routable.keys);
    final tokens = {
      for (final identity in routable.keys) identity: state.tokenFor(identity)
    };
    final routes = ProxyRouterEngine.buildRoutes(
      perSiteProxies: routable,
      tokens: tokens,
    );
    final wire = ProxyRouterEngine.toWire(routes);
    if (wire.length != routes.length) {
      // A route was dropped for a malformed address. Say so: the site is
      // about to be answered 502 rather than quietly sent out direct.
      LogTag.proxy.error(
          'Dropped ${routes.length - wire.length} malformed route(s); '
          'those sites will fail closed', sensitive: true);
    }
    final ok = await _relay.setRoutes(wire);
    if (!ok) {
      LogTag.proxy.error(
          'Relay rejected the route table; router mode is not active',
          sensitive: true);
    }
    _routed = ok
        ? {
            for (final e in routes.entries)
              if (wire.containsKey(e.key)) e.value.identity,
          }
        : const {};
    return ok;
  }

  /// Tear the relay down and forget every credential: only the launch's
  /// [activate] does, before its checks pass.
  Future<void> _standDown() async {
    assert(!_proven,
        'router mode never stands down once its launch checks pass (BUG-037)');
    _attribution?.end();
    _attribution = null;
    _table = const {};
    _routed = const {};
    _state = null;
    _host = null;
    _port = null;
    await _relay.stop();
  }
}
