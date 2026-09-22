import 'package:flutter/foundation.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/developer_mode_service.dart';
// Conditional so a UI file that reaches this service still compiles for
// web: the real adapter owns a `ServerSocket` (DESIGN-001).
import 'package:webspace/services/local_proxy_relay_api_web.dart'
    if (dart.library.io) 'package:webspace/services/local_proxy_relay_api.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/proxy_relay.dart';
import 'package:webspace/services/proxy_router_engine.dart';
import 'package:webspace/settings/proxy.dart';

/// Drives one site's container to fetch [probeUrl], so the relay can
/// observe which credential that container actually presents.
///
/// A function rather than a concrete type so the service stays testable
/// without a WebView; `main.dart` supplies the real one, which opens a
/// short-lived headless WebView bound to that site's container.
typedef ProxyAttributionProbe = Future<void> Function(
  Map<String, String> siteIdToProbeUrl,
);

/// Points the process-wide WebView proxy at the relay on [host]:[port].
///
/// Runs after the routes are installed and BEFORE the attribution probe:
/// the probe travels that same process-wide proxy, so with the override
/// not yet applied it resolves its own hostname directly, never reaches
/// the relay, and reads as a failed attribution on every device.
typedef ProxyRouterOverrideBinder = Future<bool> Function(
    String host, int port);

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
/// This used to add that whether `WKWebsiteDataStore.proxyConfigurations`
/// carries two different proxies at once was open. It is not: BUG-014
/// attempt 80 measured four container stores reaching four distinct
/// upstreams in one frame, two of them separated only by the credential
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

  /// Test seam: swap the platform-channel relay for a fake.
  void setRelayForTest(ProxyRelayApi relay) {
    _relayOverride = relay;
  }

  /// Reset to the pre-activation state. Tests only.
  void resetForTest() {
    _state = null;
    _host = null;
    _port = null;
  }

  /// True once the relay is bound and holding a route table.
  bool get isActive => _state != null && _port != null && _host != null;

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

  /// Whether this platform + engine combination can run router mode.
  ///
  /// [useContainers] is the app's cached `ContainerNative.isSupported()`.
  ///
  /// Also gated on developer mode, which is off by default, so the shipped
  /// default stays PROXY-008 serialisation. The premise router mode rests
  /// on has been proven on one WebView build by the PROXY-015 probe and
  /// never on hardware that fails it; until that changes, the people who
  /// run it are the ones who can read `LogService` when it misbehaves.
  /// Read once at activation, so a flip takes effect at next launch.
  static bool isSupported({required bool useContainers}) => isSupportedWhen(
        isAndroid: hostIsAndroid,
        isApple: hostIsIOS || hostIsMacOS,
        useContainers: useContainers,
        developerMode: DeveloperModeService.instance.enabled,
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
    required bool developerMode,
    bool isApple = false,
    bool appleRelayEnabled = false,
  }) =>
      (isAndroid || (isApple && appleRelayEnabled)) &&
      useContainers &&
      developerMode;

  /// The credential a site presents to the relay, or null when router
  /// mode is not running (in which case the WebView must not answer any
  /// proxy challenge at all). This is the relay's map key.
  String? credentialFor(String siteId) =>
      isActive ? _state!.credentialFor(siteId) : null;

  /// The raw token half, for `HttpAuthResponse.password`. Chromium does
  /// its own base64, so the challenge answer carries the parts and the
  /// route table carries the encoded blob; both come from one token.
  String? tokenFor(String siteId) => isActive ? _state!.tokenFor(siteId) : null;

  /// The username half. Carries no secret.
  String usernameFor(String siteId) =>
      '${ProxyRouterEngine.usernamePrefix}$siteId';

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
    required Map<String, UserProxySettings> perSiteProxies,
    ProxyRouterOverrideBinder? bindOverride,
    ProxyAttributionProbe? probe,
  }) async {
    final state = _state ?? ProxyRouterState();
    final endpoint = await _relay.startRouter(state.realm);
    if (endpoint == null) {
      LogService.instance.log(
        'Proxy',
        'Router relay failed to bind (${_relay.lastError ?? 'no reason reported'}); '
            'falling back to serialised per-site proxy',
        level: LogLevel.error,
      );
      return null;
    }
    final port = endpoint.port;
    _state = state;
    _host = endpoint.host;
    _port = port;
    final installed = await _installRoutes(perSiteProxies);
    if (!installed) {
      LogService.instance.log(
        'Proxy',
        'Relay rejected the route table; not activating router mode',
        level: LogLevel.error,
      );
      _host = null;
      _port = null;
      return null;
    }
    // Before the probe, not after: the probe's own traffic has to reach
    // the relay, and it only does once the process-wide proxy points
    // there. Binding afterwards makes every probe fail to resolve and
    // router mode unreachable on every device.
    if (bindOverride != null && !await bindOverride(endpoint.host, port)) {
      LogService.instance.log(
        'Proxy',
        'Proxy override did not apply; not activating router mode',
        level: LogLevel.error,
      );
      await deactivate();
      return null;
    }
    // PROXY-015. Everything above proves the app WANTS per-site routing;
    // only the probe proves this device DELIVERS it. Skipping the check
    // when no probe is supplied is deliberate for tests, but the app must
    // always pass one: without it a device that shares a proxy auth cache
    // across container profiles would route sites through each other and
    // nothing would say so.
    if (probe != null && !await _verifyAttribution(perSiteProxies.keys, probe)) {
      await deactivate();
      return null;
    }

    LogService.instance.log(
      'Proxy',
      'Router mode active on ${endpoint.host}:$port for '
          '${perSiteProxies.length} site(s)',
      level: LogLevel.info,
      sensitivity: LogSensitivity.sensitive,
    );
    return port;
  }

  /// Prove, on this device, that each container presents its own
  /// credential — then and only then trust router mode.
  ///
  /// Each site's container is asked to fetch a unique probe host. The
  /// relay answers those locally (never contacting an upstream, so a
  /// probe cannot egress) and records which credential carried which
  /// nonce. If any pair disagrees, or any is missing, attribution is not
  /// proven and the caller falls back to PROXY-008 serialisation.
  ///
  /// A useful side effect: a successful probe warms that profile's proxy
  /// auth cache, so a later service-worker request — which cannot answer
  /// a challenge itself, as `AwHttpAuthHandler` cancels with no
  /// `WebContents` — already has a credential to send.
  Future<bool> _verifyAttribution(
    Iterable<String> siteIds,
    ProxyAttributionProbe probe,
  ) async {
    if (_state == null) return false;
    // The shared-profile identity has no container to drive, and nothing
    // to prove: it exists precisely because those sites share one
    // session. What the probe certifies is the per-container boundary.
    final sites = siteIds
        .where((s) => s != ProxyRouterEngine.sharedProfileIdentity)
        .toList();
    if (sites.isEmpty) return true;

    await _relay.clearProbeResults();
    final expected = {for (final s in sites) s: ProxyRouterEngine.mintNonce()};
    try {
      await probe({
        for (final e in expected.entries)
          e.key: ProxyRouterEngine.probeUrlFor(e.value),
      });
    } catch (e) {
      LogService.instance.log(
        'Proxy',
        'Attribution probe failed to run ($e); not activating router mode',
        level: LogLevel.error,
        sensitivity: LogSensitivity.sensitive,
      );
      return false;
    }

    final observed = await _relay.probeResults();
    final failures = ProxyRouterEngine.attributionFailures(
      expected: expected,
      observed: observed,
    );
    if (failures.isNotEmpty) {
      LogService.instance.log(
        'Proxy',
        'ATTRIBUTION CHECK FAILED for ${failures.length} of ${sites.length} '
            'site(s); not activating router mode',
        level: LogLevel.error,
      );
      LogService.instance.log(
        'Proxy',
        'ATTRIBUTION CHECK FAILED for ${failures.length} site(s): $failures. '
            'This device did not give each container its own proxy '
            'credential, so router mode would route sites through each '
            "other's proxies. Falling back to serialised per-site proxy.",
        level: LogLevel.error,
        sensitivity: LogSensitivity.sensitive,
      );
      return false;
    }
    LogService.instance.log(
      'Proxy',
      'Attribution verified for ${sites.length} site(s)',
      level: LogLevel.info,
      sensitivity: LogSensitivity.sensitive,
    );
    return true;
  }

  /// Re-install the route table after sites or proxies changed.
  ///
  /// Credentials of sites that disappeared are revoked, so a deleted
  /// site's token stops routing without restarting the relay.
  Future<bool> refreshRoutes({
    required Map<String, UserProxySettings> perSiteProxies,
  }) async {
    if (!isActive) return false;
    return _installRoutes(perSiteProxies);
  }

  Future<bool> _installRoutes(
    Map<String, UserProxySettings> perSiteProxies,
  ) async {
    final state = _state;
    if (state == null) return false;
    state.retainOnly(perSiteProxies.keys);
    final tokens = {
      for (final siteId in perSiteProxies.keys) siteId: state.tokenFor(siteId)
    };
    final routes = ProxyRouterEngine.buildRoutes(
      perSiteProxies: perSiteProxies,
      tokens: tokens,
    );
    final wire = ProxyRouterEngine.toWire(routes);
    if (wire.length != routes.length) {
      // A route was dropped for a malformed address. Say so: the site is
      // about to be answered 502 rather than quietly sent out direct.
      LogService.instance.log(
        'Proxy',
        'Dropped ${routes.length - wire.length} malformed route(s); '
            'those sites will fail closed',
        level: LogLevel.error,
        sensitivity: LogSensitivity.sensitive,
      );
    }
    final ok = await _relay.setRoutes(wire);
    if (!ok) {
      LogService.instance.log(
        'Proxy',
        'Relay rejected the route table; router mode is not active',
        level: LogLevel.error,
        sensitivity: LogSensitivity.sensitive,
      );
    }
    return ok;
  }

  /// Tear the relay down and forget every credential.
  Future<void> deactivate() async {
    _state = null;
    _host = null;
    _port = null;
    await _relay.stop();
  }
}
