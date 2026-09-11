import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/outbound_http_types.dart';
import 'package:webspace/services/proxy_router_engine.dart';
import 'package:webspace/services/webview.dart' show userProxyToInappProxy;
import 'package:webspace/settings/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';

/// The two per-site proxy mechanisms must agree on where a site egresses.
///
/// Android's `ProxyController` is process-wide, so PROXY-013 routes each
/// site through the loopback relay by credential. Every other platform
/// binds a proxy per WebView (iOS/macOS `WKWebsiteDataStore`, Linux
/// `WebKitNetworkSession`) through `userProxyToInappProxy`. Two
/// independent decision paths, one question: given this site's settings,
/// which upstream carries its traffic?
///
/// They are only ever compared by a human reading both, and that is how
/// PROXY-016 got in: `_encodeUpstream` fell through to `http` for a TOR
/// site while the native path blocked it, so the router would have sent a
/// site the user put on Tor through a stale address in clear. This pins
/// the agreement instead.
///
/// The comparison is deliberately about *egress*, not encoding: the
/// mechanisms disagree in shape (a proxy URL vs a route-table row) and
/// that is fine. What must match is the (scheme, host, port) a site's
/// bytes leave through, and — the leak-relevant half — whether a site
/// egresses at all.
/// `Uri.host` strips an IPv6 literal's brackets and the wire entry keeps
/// them; the address is the same host either way.
String _bareHost(String host) =>
    host.startsWith('[') && host.endsWith(']')
        ? host.substring(1, host.length - 1)
        : host;

void main() {
  /// Where the native per-WebView mechanism sends this site, or null for
  /// "no proxy egress" (direct for DEFAULT, blocked otherwise: the caller
  /// fails closed on `proxyUnavailable`).
  ({String scheme, String host, int port})? nativeEgress(
    UserProxySettings perSite,
  ) {
    final settings = userProxyToInappProxy(
      resolveEffectiveProxy(perSite, siteId: 'parity'),
    );
    if (settings == null) return null;
    final uri = Uri.parse(settings.proxyRules.first.url);
    return (scheme: uri.scheme, host: _bareHost(uri.host), port: uri.port);
  }

  /// Where router mode sends this site, or null when it has no route and
  /// the relay answers 502.
  ({String scheme, String host, int port})? routerEgress(
    UserProxySettings perSite,
  ) {
    final state = ProxyRouterState();
    final wire = ProxyRouterEngine.toWire(
      ProxyRouterEngine.buildRoutes(
        perSiteProxies: {'parity': perSite},
        tokens: {'parity': state.tokenFor('parity')},
      ),
    );
    final entry = wire[state.credentialFor('parity')];
    if (entry == null) return null;
    if (entry['type'] == 'direct') return null;
    return (
      scheme: entry['type']! as String,
      host: _bareHost(entry['host']! as String),
      port: entry['port']! as int,
    );
  }

  UserProxySettings proxy(ProxyType type, String? address,
          {String? username, String? password}) =>
      UserProxySettings(
        type: type,
        address: address,
        username: username,
        password: password,
      );

  setUp(() {
    GlobalOutboundProxy.setForTest(UserProxySettings(type: ProxyType.DEFAULT));
    torProxyResolver = null;
  });

  tearDown(() => torProxyResolver = null);

  final cases = <String, UserProxySettings>{
    'unset': proxy(ProxyType.DEFAULT, null),
    'http': proxy(ProxyType.HTTP, '10.0.0.1:8080'),
    'https': proxy(ProxyType.HTTPS, 'secure.example.com:443'),
    'socks5': proxy(ProxyType.SOCKS5, '127.0.0.1:9050'),
    'authenticated': proxy(ProxyType.SOCKS5, '127.0.0.1:9050',
        username: 'alice', password: 's3cret'),
    'tor with a stale manual address': proxy(ProxyType.TOR, '203.0.113.9:9050'),
    'no address': proxy(ProxyType.HTTP, null),
    'empty address': proxy(ProxyType.HTTP, ''),
    'no port': proxy(ProxyType.HTTP, 'proxy.example.com'),
    'non-numeric port': proxy(ProxyType.HTTP, 'host:notaport'),
    'no host': proxy(ProxyType.HTTP, ':8080'),
    'port zero': proxy(ProxyType.HTTP, 'h:0'),
    'port out of range': proxy(ProxyType.HTTP, 'h:70000'),
    // Regression: the native path split on every colon and required
    // exactly two parts, so it blocked an IPv6 proxy the router honoured.
    'ipv6 literal': proxy(ProxyType.HTTP, '[::1]:8080'),
    'ipv6 literal, authenticated': proxy(ProxyType.SOCKS5, '[2001:db8::1]:1080',
        username: 'alice', password: 's3cret'),
  };

  group('both mechanisms route a site to the same upstream', () {
    cases.forEach((name, perSite) {
      test(name, () {
        expect(routerEgress(perSite), nativeEgress(perSite),
            reason: 'router mode and the native per-WebView proxy disagree '
                'about where "$name" egresses');
      });
    });
  });

  group('with an app-global proxy inherited by DEFAULT (PROXY-009)', () {
    test('a DEFAULT site follows the global on both paths', () {
      GlobalOutboundProxy.setForTest(proxy(ProxyType.HTTP, '10.0.0.1:8080'));
      final site = proxy(ProxyType.DEFAULT, null);
      expect(routerEgress(site), nativeEgress(site));
    });

    test('a DEFAULT site inheriting a global TOR egresses nowhere', () {
      // Neither may fall through to the device connection. The Tor
      // runtime is down here (no resolver installed), which is exactly
      // the state TOR-008 says must never mean "connect anyway".
      GlobalOutboundProxy.setForTest(proxy(ProxyType.TOR, '203.0.113.9:9050'));
      final site = proxy(ProxyType.DEFAULT, null);
      expect(nativeEgress(site), isNull);
      expect(routerEgress(site), isNull);
    });
  });

  test('an explicit per-site proxy still wins over a global on both', () {
    GlobalOutboundProxy.setForTest(proxy(ProxyType.HTTP, '10.0.0.1:8080'));
    final site = proxy(ProxyType.SOCKS5, '127.0.0.1:9050');
    expect(routerEgress(site), nativeEgress(site));
    expect(routerEgress(site)?.port, 9050);
  });
}
