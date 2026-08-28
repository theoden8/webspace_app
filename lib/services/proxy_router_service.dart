import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/proxy_relay.dart';
import 'package:webspace/services/proxy_router_engine.dart';
import 'package:webspace/settings/proxy.dart';

/// Owns Android's per-site proxy router (PROXY-013): the relay lifecycle,
/// the per-site credentials, and the one question the WebView layer asks
/// it at runtime ("is this auth challenge yours, and what do I answer?").
///
/// Router mode replaces the serialisation Android needed under PROXY-008.
/// `ProxyController` still carries one process-wide rule, but that rule
/// now points at the relay for the whole app, and the relay fans traffic
/// out per site. Sites with different proxies can therefore stay loaded
/// at the same time, as they already do on iOS 17+ / macOS 14+.
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

  ProxyRelayApi _relay = ProxyRelay.instance;
  ProxyRouterState? _state;
  int? _port;

  /// Test seam: swap the platform-channel relay for a fake.
  void setRelayForTest(ProxyRelayApi relay) {
    _relay = relay;
  }

  /// Reset to the pre-activation state. Tests only.
  void resetForTest() {
    _state = null;
    _port = null;
  }

  /// True once the relay is bound and holding a route table.
  bool get isActive => _state != null && _port != null;

  /// Loopback port `ProxyController` should be pointed at, or null.
  int? get port => _port;

  /// Realm the relay names in its `407`, or null when inactive.
  String? get realm => _state?.realm;

  /// Whether this platform + engine combination can run router mode.
  ///
  /// [useContainers] is the app's cached `ContainerNative.isSupported()`.
  static bool isSupported({required bool useContainers}) =>
      hostIsAndroid && useContainers;

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
  }) async {
    final state = _state ?? ProxyRouterState();
    final port = await _relay.startRouter(state.realm);
    if (port == null) {
      LogService.instance.log(
        'Proxy',
        'Router relay failed to bind; falling back to serialised per-site proxy',
        level: LogLevel.error,
        sensitivity: LogSensitivity.sensitive,
      );
      return null;
    }
    _state = state;
    _port = port;
    final installed = await _installRoutes(perSiteProxies);
    if (!installed) {
      _port = null;
      return null;
    }
    LogService.instance.log(
      'Proxy',
      'Router mode active on 127.0.0.1:$port for ${perSiteProxies.length} site(s)',
      level: LogLevel.info,
      sensitivity: LogSensitivity.sensitive,
    );
    return port;
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
    _port = null;
    await _relay.stop();
  }
}
