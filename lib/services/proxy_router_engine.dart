import 'dart:convert';
import 'dart:math';

import 'package:webspace/services/outbound_http_types.dart';
import 'package:webspace/settings/proxy.dart';

/// Pure-Dart policy for the Android per-site proxy router (PROXY-013).
///
/// `androidx.webkit.ProxyController` is process-wide, so Android cannot
/// point two WebViews at two proxies. Router mode works around that by
/// pointing every WebView at one loopback relay and having each site
/// identify itself to the relay with its own proxy credential, which the
/// relay maps back to that site's upstream. The credential travels the
/// only per-WebView channel Chromium offers for this: it answers the
/// relay's `407` through `onReceivedHttpAuthRequest`, which
/// `AwContentBrowserClient::CreateLoginDelegate` routes to the
/// `WebContents` that issued the request.
///
/// Everything here is deliberately free of Flutter and platform channels
/// so the admission policy can be tested without a device.
class ProxyRouterEngine {
  /// Username half of the credential. Carries no secret: it is there so a
  /// relay log line can name the site without touching the token.
  static const String usernamePrefix = 'ws-';

  static const String loopbackHost = '127.0.0.1';

  /// Suffix of the attribution self-test hostnames (PROXY-015). Mirrors
  /// `ProxyRelay.PROBE_SUFFIX`. `.invalid` is RFC 2606 reserved, so a
  /// probe host can never resolve even if something forwarded one.
  static const String probeSuffix = '.webspace-probe.invalid';

  /// Probe URL for [nonce]. Plain `http` on purpose: the relay answers it
  /// itself, and an `https` probe would arrive as a CONNECT the relay
  /// would have to fake a TLS handshake for.
  static String probeUrlFor(String nonce) => 'http://$nonce$probeSuffix/';

  /// Does the device actually attribute each site's traffic to that site?
  ///
  /// [expected] is siteId -> the nonce we told that site's container to
  /// fetch; [observed] is nonce -> the siteId whose credential the relay
  /// saw carrying it. They agree only if every container presented its
  /// OWN credential.
  ///
  /// This is the runtime form of the PROXY-013 gate. Chromium caches a
  /// proxy credential per `HttpNetworkSession`; if a device turned out to
  /// share one session across container profiles, every probe would come
  /// back stamped with whichever site authenticated first, and this
  /// returns false. A missing observation also returns false: an
  /// unproven site is treated exactly like a failed one, because the
  /// failure it would otherwise hide is silent.
  static bool attributionHolds({
    required Map<String, String> expected,
    required Map<String, String> observed,
  }) {
    if (expected.isEmpty) return true;
    for (final entry in expected.entries) {
      if (observed[entry.value] != entry.key) return false;
    }
    return true;
  }

  /// The sites whose attribution could not be proven, for logging.
  static List<String> attributionFailures({
    required Map<String, String> expected,
    required Map<String, String> observed,
  }) =>
      [
        for (final entry in expected.entries)
          if (observed[entry.value] != entry.key) entry.key,
      ];

  /// 128 bits of `Random.secure()` as lowercase hex.
  ///
  /// Used for both the per-site token and the realm nonce. The token is
  /// the admission credential for the relay socket, which every app on
  /// the device can reach, so it must not be guessable. The realm is not
  /// secret but is generated the same way, so a page cannot predict it
  /// and mount a challenge that looks like ours.
  static String mintNonce({Random? rng}) {
    final random = rng ?? Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// The `Proxy-Authorization: Basic <...>` payload a site presents.
  ///
  /// The relay compares this blob and never decodes it, so this is the
  /// single place the credential's shape is defined.
  static String credentialFor({
    required String siteId,
    required String token,
  }) =>
      base64.encode(utf8.encode('$usernamePrefix$siteId:$token'));

  /// Whether an `onReceivedHttpAuthRequest` challenge is the relay's.
  ///
  /// Android's callback carries only host and realm: `AwHttpAuthHandler`
  /// forwards `challenger.host()` and `realm` and drops both the port and
  /// `is_proxy`, so there is no way to ask "was this a proxy challenge?".
  /// A site that serves its own `401` therefore reaches the same handler,
  /// and answering it would hand the page the token that admits its
  /// bearer to every site's route. Both checks are required: the host
  /// pins the challenge to the loopback relay, and the realm nonce pins
  /// it to *this* run of it.
  static bool shouldAnswerChallenge({
    required String? host,
    required String? realm,
    required String expectedRealm,
  }) {
    if (expectedRealm.isEmpty) return false;
    if (host != loopbackHost) return false;
    return realm == expectedRealm;
  }

  /// Build the relay's route table: credential -> that site's upstream.
  ///
  /// Every site gets an entry, including one whose effective proxy is
  /// `DEFAULT`. Router mode points `ProxyController` at the relay for the
  /// whole process, so an unproxied site's traffic arrives here too and
  /// has to be routed direct to its origin. A site with
  /// no entry cannot reach the network at all, which is the fail-closed
  /// direction.
  static Map<String, ProxyRoute> buildRoutes({
    required Map<String, UserProxySettings> perSiteProxies,
    required Map<String, String> tokens,
  }) {
    final routes = <String, ProxyRoute>{};
    for (final entry in perSiteProxies.entries) {
      final siteId = entry.key;
      final token = tokens[siteId];
      if (token == null) continue;
      routes[credentialFor(siteId: siteId, token: token)] = ProxyRoute(
        siteId: siteId,
        upstream: resolveEffectiveProxy(entry.value),
      );
    }
    return routes;
  }

  /// Serialise [routes] for the platform channel.
  ///
  /// A malformed address resolves to no entry at all rather than to a
  /// direct route: silently downgrading a site the user proxied is the
  /// leak this whole feature exists to prevent, and an absent credential
  /// makes the relay answer 502.
  static Map<String, Map<String, Object?>> toWire(
    Map<String, ProxyRoute> routes,
  ) {
    final wire = <String, Map<String, Object?>>{};
    for (final entry in routes.entries) {
      final encoded = _encodeUpstream(entry.value);
      if (encoded != null) wire[entry.key] = encoded;
    }
    return wire;
  }

  static Map<String, Object?>? _encodeUpstream(ProxyRoute route) {
    final proxy = route.upstream;
    if (proxy.type == ProxyType.DEFAULT) {
      return {
        'siteId': route.siteId,
        'type': 'direct',
        'host': '',
        'port': 0,
      };
    }
    final address = proxy.address;
    if (address == null) return null;
    final separator = address.lastIndexOf(':');
    if (separator <= 0) return null;
    final port = int.tryParse(address.substring(separator + 1));
    if (port == null || port < 1 || port > 65535) return null;
    final host = address.substring(0, separator);
    if (host.isEmpty) return null;
    return {
      'siteId': route.siteId,
      'type': switch (proxy.type) {
        ProxyType.HTTPS => 'https',
        ProxyType.SOCKS5 => 'socks5',
        _ => 'http',
      },
      'host': host,
      'port': port,
      'username': proxy.username,
      'password': proxy.password,
    };
  }
}

/// One site's resolved upstream, keyed in the relay by its credential.
class ProxyRoute {
  final String siteId;
  final UserProxySettings upstream;

  const ProxyRoute({required this.siteId, required this.upstream});
}

/// In-memory token registry for one app run.
///
/// Tokens are minted on demand, live only here, and are never persisted:
/// a restart rebinds the relay on a fresh port with a fresh realm anyway,
/// so a leaked token from a previous run admits its bearer to nothing.
class ProxyRouterState {
  final String realm;
  final Map<String, String> _tokens = {};
  final Random? _rng;

  ProxyRouterState({String? realm, Random? rng})
      : realm = realm ?? ProxyRouterEngine.mintNonce(rng: rng),
        _rng = rng;

  Map<String, String> get tokens => Map.unmodifiable(_tokens);

  String tokenFor(String siteId) =>
      _tokens.putIfAbsent(siteId, () => ProxyRouterEngine.mintNonce(rng: _rng));

  String credentialFor(String siteId) => ProxyRouterEngine.credentialFor(
        siteId: siteId,
        token: tokenFor(siteId),
      );

  /// Drop tokens for sites that no longer exist, so a deleted site's
  /// credential stops being routable.
  void retainOnly(Iterable<String> siteIds) {
    final keep = siteIds.toSet();
    _tokens.removeWhere((siteId, _) => !keep.contains(siteId));
  }
}
