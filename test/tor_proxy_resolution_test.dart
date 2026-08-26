// How ProxyType.TOR resolves at the outbound seams: which isolation tag a
// caller gets (PROXY-010, PROXY-011, LEAK-00x) and what happens when the
// runtime is not up (TOR-008).

import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/tor_engine.dart';
import 'package:webspace/settings/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/web_view_model.dart';

UserProxySettings _tor() => UserProxySettings(type: ProxyType.TOR);

void main() {
  setUp(() {
    GlobalOutboundProxy.setForTest(UserProxySettings(type: ProxyType.DEFAULT));
    // Stand in for a bootstrapped runtime on a port nothing hardcodes.
    torProxyResolver = (tag) => UserProxySettings(
          type: ProxyType.SOCKS5,
          address: '127.0.0.1:41337',
          username: tag,
          password: 'session-secret',
        );
  });

  tearDown(() {
    torProxyResolver = null;
    GlobalOutboundProxy.setForTest(UserProxySettings(type: ProxyType.DEFAULT));
    resetOutboundHttp();
  });

  group('isolation tag selection', () {
    test('an explicit per-site TOR is tagged with the siteId', () {
      final resolved = resolveEffectiveProxy(_tor(), siteId: 'site-a');
      expect(resolved.type, ProxyType.TOR);
      expect(resolved.username, 'site-a');

      expect(expandTorProxy(resolved)!.username, 'site-a');
    });

    test('a DEFAULT site inheriting global TOR gets the app-global tag', () {
      GlobalOutboundProxy.setForTest(_tor());

      // The site asked for "whatever the app uses", not for a circuit of its
      // own; handing it one would give every uncustomized site its own exit.
      final resolved = resolveEffectiveProxy(
        UserProxySettings(type: ProxyType.DEFAULT),
        siteId: 'site-a',
      );
      expect(resolved.username, kTorAppGlobalTag);
      expect(resolved.username, isNot('site-a'));
    });

    test('an explicit per-site TOR beats an inherited global TOR', () {
      GlobalOutboundProxy.setForTest(_tor());
      final resolved = resolveEffectiveProxy(_tor(), siteId: 'site-a');
      expect(resolved.username, 'site-a');
    });

    test('app-global traffic with no site resolves to the reserved tag', () {
      GlobalOutboundProxy.setForTest(_tor());
      final resolved = resolveEffectiveProxy(
        UserProxySettings(type: ProxyType.DEFAULT),
      );
      expect(resolved.username, kTorAppGlobalTag);
    });

    test('two sites never share an isolation tag', () {
      final a = expandTorProxy(resolveEffectiveProxy(_tor(), siteId: 'a1'))!;
      final b = expandTorProxy(resolveEffectiveProxy(_tor(), siteId: 'b2'))!;
      expect(a.username, isNot(b.username));
      expect(a.address, b.address);
    });

    test('non-TOR settings pass through untouched', () {
      final socks = UserProxySettings(
        type: ProxyType.SOCKS5,
        address: '192.0.2.1:1080',
        username: 'bob',
      );
      final resolved = resolveEffectiveProxy(socks, siteId: 'site-a');
      expect(identical(resolved, socks), isTrue);
      expect(resolved.username, 'bob', reason: 'not overwritten by the tag');
    });
  });

  group('WebViewModel.outboundProxySettings', () {
    test('a TOR site carries its siteId as the tag', () {
      final m = WebViewModel(initUrl: 'https://example.com', proxySettings: _tor());
      expect(m.outboundProxySettings.username, m.siteId);
    });

    test('the stored manual config survives selecting TOR', () {
      final m = WebViewModel(
        initUrl: 'https://example.com',
        proxySettings: UserProxySettings(
          type: ProxyType.TOR,
          address: '192.0.2.1:1080',
          username: 'manual-user',
          password: 'manual-pass',
        ),
      );

      // The tagged copy is what goes on the wire...
      expect(m.outboundProxySettings.username, m.siteId);
      // ...while the stored object keeps what the user typed, so switching
      // back to SOCKS5 restores it (PROXY-010).
      expect(m.proxySettings.username, 'manual-user');
      expect(m.proxySettings.password, 'manual-pass');
      expect(m.proxySettings.address, '192.0.2.1:1080');
    });

    test('a non-TOR site hands back the very same object', () {
      final m = WebViewModel(
        initUrl: 'https://example.com',
        proxySettings: UserProxySettings(
            type: ProxyType.SOCKS5, address: '192.0.2.1:1080'),
      );
      expect(identical(m.outboundProxySettings, m.proxySettings), isTrue);
    });
  });

  group('TOR-008 fail-closed', () {
    test('clientFor blocks when the runtime is not up', () {
      torProxyResolver = (_) => null; // bootstrapping, or errored

      final result = outboundHttp
          .clientFor(resolveEffectiveProxy(_tor(), siteId: 'site-a'));

      expect(result, isA<OutboundClientBlocked>());
      expect((result as OutboundClientBlocked).reason,
          contains('Tor is not bootstrapped'));
    });

    test('clientFor blocks when no resolver was ever installed', () {
      // A build that forgot to wire the resolver must block, never connect
      // directly — the whole point of the sealed OutboundClient.
      torProxyResolver = null;

      final result = outboundHttp
          .clientFor(resolveEffectiveProxy(_tor(), siteId: 'site-a'));
      expect(result, isA<OutboundClientBlocked>());
    });

    test('clientFor is ready once the runtime is up', () {
      final result = outboundHttp
          .clientFor(resolveEffectiveProxy(_tor(), siteId: 'site-a'));
      expect(result, isA<OutboundClientReady>());
      (result as OutboundClientReady).client.close();
    });
  });

  group('serialization', () {
    test('TOR round-trips through JSON', () {
      final json = UserProxySettings(type: ProxyType.TOR).toJson();
      expect(UserProxySettings.fromJson(json).type, ProxyType.TOR);
    });

    test('appending TOR did not renumber the existing types', () {
      // The index is the on-disk form; renumbering silently rewrites every
      // stored proxy into a different transport.
      expect(ProxyType.DEFAULT.index, 0);
      expect(ProxyType.HTTP.index, 1);
      expect(ProxyType.HTTPS.index, 2);
      expect(ProxyType.SOCKS5.index, 3);
      expect(ProxyType.TOR.index, 4);
    });

    test('an unknown future type decodes to DEFAULT instead of throwing', () {
      // A backup written by a newer build, imported after a rollback.
      final decoded = UserProxySettings.fromJson({
        'type': 99,
        'address': null,
        'username': null,
      });
      expect(decoded.type, ProxyType.DEFAULT);
    });

    test('a TOR site never serializes the session secret', () {
      final m = WebViewModel(initUrl: 'https://example.com', proxySettings: _tor());
      final encoded = m.toJson().toString();
      expect(encoded, isNot(contains('session-secret')));
    });
  });
}
