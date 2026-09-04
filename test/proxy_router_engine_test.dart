import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/proxy_router_engine.dart';
import 'package:webspace/settings/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';

/// Admission and routing policy for the Android per-site proxy router
/// (PROXY-013). The relay half of this contract is covered by real
/// sockets in `ProxyRelayRouterTest.kt`; here we pin the decisions the
/// Dart side owns, above all the two that are security-relevant:
///
///  - which challenges get answered with a token (a site's own `401`
///    must not), and
///  - which sites end up in the route table with which upstream (a
///    proxied site must never be encoded as direct).
void main() {
  UserProxySettings proxy(
    ProxyType type,
    String? address, {
    String? username,
    String? password,
  }) =>
      UserProxySettings(
        type: type,
        address: address,
        username: username,
        password: password,
      );

  setUp(() {
    GlobalOutboundProxy.setForTest(UserProxySettings(type: ProxyType.DEFAULT));
  });

  group('nonces and credentials', () {
    test('mintNonce is 128 bits of lowercase hex', () {
      final nonce = ProxyRouterEngine.mintNonce();
      expect(nonce, hasLength(32));
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(nonce), isTrue);
    });

    test('mintNonce does not repeat across calls', () {
      final seen = {for (var i = 0; i < 200; i++) ProxyRouterEngine.mintNonce()};
      expect(seen, hasLength(200));
    });

    test('credential encodes the ws-<siteId>:<token> pair', () {
      final credential =
          ProxyRouterEngine.credentialFor(siteId: 'acme', token: 'tok');
      expect(utf8.decode(base64.decode(credential)), 'ws-acme:tok');
    });

    test('two sites never share a credential', () {
      final state = ProxyRouterState();
      final credentials = {
        for (var i = 0; i < 50; i++) state.credentialFor('site-$i')
      };
      expect(credentials, hasLength(50));
    });
  });

  group('challenge admission', () {
    const realm = 'a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4';

    test('answers the relay challenge on loopback with the current realm', () {
      expect(
        ProxyRouterEngine.shouldAnswerChallenge(
          host: '127.0.0.1',
          realm: realm,
          expectedRealm: realm,
        ),
        isTrue,
      );
    });

    test("refuses a site's own 401 even if it guesses the realm", () {
      // The Android callback drops `is_proxy` and the port, so a site
      // serving 401 with a copied realm reaches the same handler. The
      // host check is what stops it.
      expect(
        ProxyRouterEngine.shouldAnswerChallenge(
          host: 'accounts.example.com',
          realm: realm,
          expectedRealm: realm,
        ),
        isFalse,
      );
    });

    test('refuses a loopback challenge naming a different realm', () {
      expect(
        ProxyRouterEngine.shouldAnswerChallenge(
          host: '127.0.0.1',
          realm: 'ffffffffffffffffffffffffffffffff',
          expectedRealm: realm,
        ),
        isFalse,
      );
    });

    test('refuses null host or realm', () {
      expect(
        ProxyRouterEngine.shouldAnswerChallenge(
          host: null,
          realm: realm,
          expectedRealm: realm,
        ),
        isFalse,
      );
      expect(
        ProxyRouterEngine.shouldAnswerChallenge(
          host: '127.0.0.1',
          realm: null,
          expectedRealm: realm,
        ),
        isFalse,
      );
    });

    test('refuses everything when no realm is configured', () {
      expect(
        ProxyRouterEngine.shouldAnswerChallenge(
          host: '127.0.0.1',
          realm: '',
          expectedRealm: '',
        ),
        isFalse,
      );
    });

    test('refuses a lookalike loopback host', () {
      for (final host in ['127.0.0.2', 'localhost', '127.0.0.1.evil.com']) {
        expect(
          ProxyRouterEngine.shouldAnswerChallenge(
            host: host,
            realm: realm,
            expectedRealm: realm,
          ),
          isFalse,
          reason: '$host must not be treated as the relay',
        );
      }
    });
  });

  group('route table', () {
    test('each site maps to its own upstream', () {
      final state = ProxyRouterState();
      final routes = ProxyRouterEngine.buildRoutes(
        perSiteProxies: {
          'a': proxy(ProxyType.SOCKS5, '127.0.0.1:9050'),
          'b': proxy(ProxyType.HTTP, 'proxy.example.com:8080'),
        },
        tokens: {'a': state.tokenFor('a'), 'b': state.tokenFor('b')},
      );

      expect(routes, hasLength(2));
      final a = routes[state.credentialFor('a')]!;
      final b = routes[state.credentialFor('b')]!;
      expect(a.siteId, 'a');
      expect(a.upstream.type, ProxyType.SOCKS5);
      expect(b.upstream.address, 'proxy.example.com:8080');
    });

    test('a DEFAULT site gets a direct route, not an absent one', () {
      // ProxyController points the whole process at the relay, so an
      // unproxied site's traffic arrives there too and must be routed
      // out unproxied rather than dropped.
      final state = ProxyRouterState();
      final wire = ProxyRouterEngine.toWire(
        ProxyRouterEngine.buildRoutes(
          perSiteProxies: {'plain': proxy(ProxyType.DEFAULT, null)},
          tokens: {'plain': state.tokenFor('plain')},
        ),
      );
      expect(wire[state.credentialFor('plain')]!['type'], 'direct');
    });

    test('a DEFAULT site inherits the app-global proxy (PROXY-009)', () {
      GlobalOutboundProxy.setForTest(
        proxy(ProxyType.HTTP, '10.0.0.1:8080'),
      );
      final state = ProxyRouterState();
      final wire = ProxyRouterEngine.toWire(
        ProxyRouterEngine.buildRoutes(
          perSiteProxies: {'plain': proxy(ProxyType.DEFAULT, null)},
          tokens: {'plain': state.tokenFor('plain')},
        ),
      );
      final entry = wire[state.credentialFor('plain')]!;
      expect(entry['type'], 'http');
      expect(entry['host'], '10.0.0.1');
      expect(entry['port'], 8080);
    });

    test('a site with no token gets no route', () {
      final routes = ProxyRouterEngine.buildRoutes(
        perSiteProxies: {'a': proxy(ProxyType.HTTP, 'p:1')},
        tokens: const {},
      );
      expect(routes, isEmpty);
    });

    test('a malformed proxy address drops the route instead of going direct',
        () {
      // Fail closed. Encoding an unparseable proxy as `direct` would send
      // a site the user proxied straight out of the device.
      final state = ProxyRouterState();
      for (final bad in ['proxy.example.com', 'host:notaport', ':8080', 'h:0']) {
        final wire = ProxyRouterEngine.toWire(
          ProxyRouterEngine.buildRoutes(
            perSiteProxies: {'a': proxy(ProxyType.HTTP, bad)},
            tokens: {'a': state.tokenFor('a')},
          ),
        );
        expect(wire, isEmpty, reason: '"$bad" must not produce a route');
      }
    });

    test('credentials ride the wire entry for an authenticated upstream', () {
      final state = ProxyRouterState();
      final wire = ProxyRouterEngine.toWire(
        ProxyRouterEngine.buildRoutes(
          perSiteProxies: {
            'a': proxy(ProxyType.SOCKS5, '127.0.0.1:9050',
                username: 'alice', password: 's3cret'),
          },
          tokens: {'a': state.tokenFor('a')},
        ),
      );
      final entry = wire[state.credentialFor('a')]!;
      expect(entry['type'], 'socks5');
      expect(entry['username'], 'alice');
      expect(entry['password'], 's3cret');
    });

    test('a TOR site gets no route, not a cleartext one (TOR-008)', () {
      // Selecting TOR deliberately keeps the previous manual proxy address
      // so switching back restores it (PROXY-010). Encoding that leftover
      // as `http` would send a site the user put on Tor straight through an
      // unrelated proxy in clear. No route means the relay answers 502.
      final state = ProxyRouterState();
      final wire = ProxyRouterEngine.toWire(
        ProxyRouterEngine.buildRoutes(
          perSiteProxies: {
            'a': proxy(ProxyType.TOR, '203.0.113.9:9050'),
          },
          tokens: {'a': state.tokenFor('a')},
        ),
      );
      expect(wire, isEmpty);
    });

    test('a DEFAULT site inheriting a global TOR gets no route either', () {
      GlobalOutboundProxy.setForTest(
        proxy(ProxyType.TOR, '203.0.113.9:9050'),
      );
      final state = ProxyRouterState();
      final wire = ProxyRouterEngine.toWire(
        ProxyRouterEngine.buildRoutes(
          perSiteProxies: {'plain': proxy(ProxyType.DEFAULT, null)},
          tokens: {'plain': state.tokenFor('plain')},
        ),
      );
      expect(wire, isEmpty);
    });

    test('an IPv6 proxy address keeps its host intact', () {
      final state = ProxyRouterState();
      final wire = ProxyRouterEngine.toWire(
        ProxyRouterEngine.buildRoutes(
          perSiteProxies: {'a': proxy(ProxyType.HTTP, '[::1]:8080')},
          tokens: {'a': state.tokenFor('a')},
        ),
      );
      expect(wire[state.credentialFor('a')]!['host'], '[::1]');
    });
  });

  group('token registry', () {
    test('a token is stable for a site across calls', () {
      final state = ProxyRouterState();
      expect(state.tokenFor('a'), state.tokenFor('a'));
    });

    test('retainOnly revokes a deleted site', () {
      final state = ProxyRouterState();
      state.tokenFor('a');
      state.tokenFor('b');
      state.retainOnly(['a']);
      expect(state.tokens.keys, ['a']);
    });

    test('a revoked site gets a fresh token if it comes back', () {
      final state = ProxyRouterState();
      final first = state.tokenFor('a');
      state.retainOnly(const []);
      expect(state.tokenFor('a'), isNot(first));
    });

    test('the realm is independent of every site token', () {
      final state = ProxyRouterState(rng: Random(1));
      final realm = state.realm;
      expect(state.tokens.values, isNot(contains(realm)));
      expect(state.tokenFor('a'), isNot(realm));
    });
  });

  group('attribution predicate (PROXY-015)', () {
    test('holds when every nonce comes back stamped with its own site', () {
      expect(
        ProxyRouterEngine.attributionHolds(
          expected: {'a': 'n1', 'b': 'n2'},
          observed: {'n1': 'a', 'n2': 'b'},
        ),
        isTrue,
      );
    });

    test('fails on the shared-auth-cache signature', () {
      // Both containers replayed whichever credential was cached first,
      // so both probes came back stamped 'a'. Nothing errors on such a
      // device; this predicate is the only thing that notices.
      expect(
        ProxyRouterEngine.attributionHolds(
          expected: {'a': 'n1', 'b': 'n2'},
          observed: {'n1': 'a', 'n2': 'a'},
        ),
        isFalse,
      );
      expect(
        ProxyRouterEngine.attributionFailures(
          expected: {'a': 'n1', 'b': 'n2'},
          observed: {'n1': 'a', 'n2': 'a'},
        ),
        ['b'],
      );
    });

    test('fails when an observation is missing', () {
      expect(
        ProxyRouterEngine.attributionHolds(
          expected: {'a': 'n1', 'b': 'n2'},
          observed: {'n1': 'a'},
        ),
        isFalse,
        reason: 'unproven must not read as proven',
      );
    });

    test('fails when a nonce is stamped with an unrelated site', () {
      expect(
        ProxyRouterEngine.attributionHolds(
          expected: {'a': 'n1'},
          observed: {'n1': 'somebody-else'},
        ),
        isFalse,
      );
    });

    test('vacuously holds with no sites', () {
      expect(
        ProxyRouterEngine.attributionHolds(expected: {}, observed: {}),
        isTrue,
      );
    });

    test('probe URL is http, carries the nonce, and uses the reserved TLD', () {
      final url = ProxyRouterEngine.probeUrlFor('abc123');
      expect(url, 'http://abc123.webspace-probe.invalid/');
      expect(Uri.parse(url).host, endsWith('.invalid'));
    });
  });
}
