import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/local_proxy_relay_api.dart';
import 'package:webspace/services/proxy_router_engine.dart';
import 'package:webspace/settings/proxy.dart';

/// The adapter that lets the PROXY-013 router drive the in-process relay
/// (PROXY-026).
///
/// It is the one place the platform-channel wire shape is turned back into
/// the relay's own route type, so every way that decode can go wrong is a
/// site whose traffic is misattributed or silently unrouted. Both are the
/// failures this feature exists to prevent, so they are asserted here
/// rather than left to the one tier that can run a real WebView.
void main() {
  String credential(String siteId, String token) =>
      ProxyRouterEngine.credentialFor(siteId: siteId, token: token);

  Map<String, Object?> wire({
    String siteId = 'site-a',
    String type = 'socks5',
    Object? host = '127.0.0.1',
    Object? port = 9050,
    String? username,
    String? password,
  }) =>
      {
        'siteId': siteId,
        'type': type,
        'host': host,
        'port': port,
        'username': username,
        'password': password,
      };

  group('decodeRoute', () {
    test('splits the credential into the username the relay keys on', () {
      final decoded =
          LocalProxyRelayApi.decodeRoute(credential('site-a', 'tok'), wire());
      expect(decoded, isNotNull);
      expect(decoded!.username, 'ws-site-a');
      expect(decoded.route.token, 'tok');
      expect(decoded.route.siteId, 'site-a');
      expect(decoded.route.upstream.type, ProxyType.SOCKS5);
      expect(decoded.route.upstream.address, '127.0.0.1:9050');
    });

    test('carries the upstream credential on the route, not the settings', () {
      // `UserProxySettings.toJson` must never carry a secret (PWD-005), so
      // the relay holds the upstream password beside the settings object.
      final decoded = LocalProxyRelayApi.decodeRoute(
        credential('site-a', 'tok'),
        wire(username: 'alice', password: 's3cret'),
      );
      expect(decoded!.route.upstream.username, 'alice');
      expect(decoded.route.upstreamPassword, 's3cret');
      expect(decoded.route.upstream.toJson().toString(), isNot(contains('s3cret')));
    });

    test('a direct route needs no address', () {
      final decoded = LocalProxyRelayApi.decodeRoute(
        credential('site-a', 'tok'),
        wire(type: 'direct', host: '', port: 0),
      );
      expect(decoded!.route.upstream.type, ProxyType.DEFAULT);
      expect(decoded.route.upstream.address, isNull);
    });

    test('every malformed shape decodes to null rather than to direct', () {
      // Null is what makes `setRoutes` reject the whole table. A shape that
      // fell through to a DEFAULT route instead would send a site the user
      // proxied straight out on the device IP, which is the leak.
      final bad = <String, ({String cred, Map<String, Object?> body})>{
        'not base64': (cred: 'not-base64!!', body: wire()),
        'no colon': (cred: base64.encode(utf8.encode('nocolon')), body: wire()),
        'empty token': (
          cred: base64.encode(utf8.encode('ws-site-a:')),
          body: wire()
        ),
        'empty username': (
          cred: base64.encode(utf8.encode(':tok')),
          body: wire()
        ),
        'unknown type': (
          cred: credential('site-a', 'tok'),
          body: wire(type: 'carrier-pigeon')
        ),
        'missing siteId': (cred: credential('site-a', 'tok'), body: {
          'type': 'socks5',
          'host': '127.0.0.1',
          'port': 9050,
        }),
        'empty host': (
          cred: credential('site-a', 'tok'),
          body: wire(host: '')
        ),
        'port zero': (cred: credential('site-a', 'tok'), body: wire(port: 0)),
        'port not an int': (
          cred: credential('site-a', 'tok'),
          body: wire(port: '9050')
        ),
      };
      bad.forEach((name, input) {
        expect(LocalProxyRelayApi.decodeRoute(input.cred, input.body), isNull,
            reason: '"$name" must not decode');
      });
    });
  });

  group('the running relay', () {
    late LocalProxyRelayApi api;

    setUp(() => api = LocalProxyRelayApi());
    tearDown(() => api.stop());

    test('binds a loopback endpoint and reuses it for the same realm',
        () async {
      final first = await api.startRouter('realm-1');
      expect(first, isNotNull);
      expect(first!.host, startsWith('127.'));
      expect(first.port, greaterThan(0));
      final again = await api.startRouter('realm-1');
      expect(again, first,
          reason: 'a second activation in the same run must not move the '
              'endpoint out from under the stores already pointed at it');
    });

    test('a new realm rebinds, so the old challenge stops being answered',
        () async {
      await api.startRouter('realm-1');
      final second = await api.startRouter('realm-2');
      expect(second, isNotNull);
      expect(api.relay!.realm, 'realm-2');
    });

    test('setRoutes rejects the whole table when one route is malformed',
        () async {
      await api.startRouter('realm-1');
      final ok = await api.setRoutes({
        credential('site-a', 'tok-a'): wire(siteId: 'site-a'),
        credential('site-b', 'tok-b'): wire(siteId: 'site-b', type: 'nope'),
      });
      expect(ok, isFalse,
          reason: 'half a table routes the missing site to a 502, which '
              'reads as a broken proxy rather than as a bad table');
      expect(api.lastError, isNotNull);
    });

    test('setRoutes without a relay fails rather than silently succeeding',
        () async {
      expect(await api.setRoutes({credential('a', 'b'): wire()}), isFalse);
    });

    test('probe results start empty and clear', () async {
      await api.startRouter('realm-1');
      expect(await api.probeResults(), isEmpty);
      await api.clearProbeResults();
      expect(await api.probeResults(), isEmpty);
    });
  });
}
