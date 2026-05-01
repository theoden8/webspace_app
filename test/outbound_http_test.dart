import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/proxy_password_secure_storage.dart';
import 'package:webspace/settings/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';

import 'helpers/mock_secure_storage.dart';

/// Records every [UserProxySettings] passed to it so call-site tests can
/// assert that a per-site proxy actually reaches [outboundHttp]. Returns
/// either a fixed [http.MockClient] (when permitted) or a Blocked result.
class RecordingOutboundFactory implements OutboundHttpFactory {
  final List<UserProxySettings> queries = [];
  final http.Client Function() clientBuilder;
  final bool blockSocks5;

  RecordingOutboundFactory({
    http.Client Function()? clientBuilder,
    this.blockSocks5 = true,
  }) : clientBuilder = clientBuilder ?? (() => MockClient((_) async => http.Response('', 200)));

  @override
  OutboundClient clientFor(UserProxySettings settings) {
    queries.add(settings);
    if (blockSocks5 && settings.type == ProxyType.SOCKS5) {
      return const OutboundClientBlocked('SOCKS5 unsupported (test fake)');
    }
    return OutboundClientReady(clientBuilder());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    GlobalOutboundProxy.resetForTest();
  });

  tearDown(() {
    resetOutboundHttp();
    GlobalOutboundProxy.resetForTest();
  });

  group('parseHostPort', () {
    test('parses host:port', () {
      expect(parseHostPort('proxy.example.com:8080'), ('proxy.example.com', 8080));
    });

    test('parses IPv4:port', () {
      expect(parseHostPort('127.0.0.1:9050'), ('127.0.0.1', 9050));
    });

    test('rejects missing port', () {
      expect(parseHostPort('proxy.example.com'), isNull);
    });

    test('rejects empty port', () {
      expect(parseHostPort('proxy.example.com:'), isNull);
    });

    test('rejects non-numeric port', () {
      expect(parseHostPort('host:abc'), isNull);
    });

    test('rejects port out of range (high)', () {
      expect(parseHostPort('host:99999'), isNull);
    });

    test('rejects port out of range (low)', () {
      expect(parseHostPort('host:0'), isNull);
    });
  });

  group('DefaultOutboundHttpFactory', () {
    final factory = const DefaultOutboundHttpFactory();

    test('DEFAULT type returns a Ready client', () {
      final result = factory.clientFor(
        UserProxySettings(type: ProxyType.DEFAULT),
      );
      expect(result, isA<OutboundClientReady>());
      (result as OutboundClientReady).client.close();
    });

    test('HTTP with valid address returns a Ready client', () {
      final result = factory.clientFor(
        UserProxySettings(type: ProxyType.HTTP, address: '127.0.0.1:8080'),
      );
      expect(result, isA<OutboundClientReady>());
      (result as OutboundClientReady).client.close();
    });

    test('HTTP with empty address returns a Ready client (treated as DEFAULT)', () {
      final result = factory.clientFor(
        UserProxySettings(type: ProxyType.HTTP, address: ''),
      );
      expect(result, isA<OutboundClientReady>());
      (result as OutboundClientReady).client.close();
    });

    test('HTTPS with malformed address returns Blocked (no direct fallback)', () {
      final result = factory.clientFor(
        UserProxySettings(type: ProxyType.HTTPS, address: 'no-port'),
      );
      expect(result, isA<OutboundClientBlocked>());
    });

    test('SOCKS5 with valid address returns a Ready client (tunnels via socks5_proxy)', () {
      final result = factory.clientFor(
        UserProxySettings(
          type: ProxyType.SOCKS5,
          address: '127.0.0.1:9050',
        ),
      );
      expect(result, isA<OutboundClientReady>());
      (result as OutboundClientReady).client.close();
    });

    test('SOCKS5 with malformed address returns Blocked (no direct fallback)', () {
      final result = factory.clientFor(
        UserProxySettings(type: ProxyType.SOCKS5, address: 'no-port'),
      );
      expect(result, isA<OutboundClientBlocked>());
      expect((result as OutboundClientBlocked).reason, contains('SOCKS5'));
    });

    test('SOCKS5 with empty address returns a Ready client (no override)', () {
      final result = factory.clientFor(
        UserProxySettings(type: ProxyType.SOCKS5, address: ''),
      );
      expect(result, isA<OutboundClientReady>());
      (result as OutboundClientReady).client.close();
    });
  });

  group('resolveEffectiveProxy', () {
    test('per-site DEFAULT falls through to global', () {
      GlobalOutboundProxy.setForTest(UserProxySettings(
        type: ProxyType.HTTP,
        address: '10.0.0.1:3128',
      ));
      final perSite = UserProxySettings(type: ProxyType.DEFAULT);
      final effective = resolveEffectiveProxy(perSite);
      expect(effective.type, ProxyType.HTTP);
      expect(effective.address, '10.0.0.1:3128');
    });

    test('per-site explicit proxy overrides global', () {
      GlobalOutboundProxy.setForTest(UserProxySettings(
        type: ProxyType.HTTP,
        address: '10.0.0.1:3128',
      ));
      final perSite = UserProxySettings(
        type: ProxyType.SOCKS5,
        address: '127.0.0.1:9050',
      );
      final effective = resolveEffectiveProxy(perSite);
      expect(effective.type, ProxyType.SOCKS5);
      expect(effective.address, '127.0.0.1:9050');
    });

    test('per-site DEFAULT and global DEFAULT yields DEFAULT', () {
      final perSite = UserProxySettings(type: ProxyType.DEFAULT);
      final effective = resolveEffectiveProxy(perSite);
      expect(effective.type, ProxyType.DEFAULT);
    });
  });

  group('GlobalOutboundProxy persistence', () {
    setUp(() {
      // The password component lives in flutter_secure_storage, which has
      // no platform impl during unit tests. Inject an in-memory store so
      // the round-trip exercises the real `update -> initialize` path.
      GlobalOutboundProxy.setPasswordStoreForTest(
        ProxyPasswordSecureStorage(secureStorage: MockFlutterSecureStorage()),
      );
    });

    test('initialize loads default when SharedPreferences is empty', () async {
      SharedPreferences.setMockInitialValues({});
      await GlobalOutboundProxy.initialize();
      expect(GlobalOutboundProxy.current.type, ProxyType.DEFAULT);
    });

    test('update writes to SharedPreferences and reloads on initialize', () async {
      SharedPreferences.setMockInitialValues({});
      // Each call to setMockInitialValues hands out a fresh prefs instance,
      // but the mock secure storage installed in setUp persists across the
      // update -> reset -> initialize cycle, just like real Keychain would.
      await GlobalOutboundProxy.initialize();
      await GlobalOutboundProxy.update(UserProxySettings(
        type: ProxyType.HTTP,
        address: '192.168.1.10:8080',
        username: 'alice',
        password: 'secret',
      ));
      // Force a fresh read to confirm persistence.
      GlobalOutboundProxy.resetForTest();
      await GlobalOutboundProxy.initialize();
      expect(GlobalOutboundProxy.current.type, ProxyType.HTTP);
      expect(GlobalOutboundProxy.current.address, '192.168.1.10:8080');
      expect(GlobalOutboundProxy.current.username, 'alice');
      expect(GlobalOutboundProxy.current.password, 'secret');
    });

    test('password is stored in secure storage, not SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({});
      await GlobalOutboundProxy.update(UserProxySettings(
        type: ProxyType.HTTP,
        address: '192.168.1.10:8080',
        username: 'alice',
        password: 'top-secret',
      ));
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kGlobalOutboundProxyKey)!;
      expect(raw.contains('top-secret'), isFalse,
          reason: 'plaintext password leaked into SharedPreferences');
    });

    test('readGlobalOutboundProxy falls back to default on malformed JSON', () async {
      SharedPreferences.setMockInitialValues({
        kGlobalOutboundProxyKey: '{not-valid-json',
      });
      final prefs = await SharedPreferences.getInstance();
      final settings = readGlobalOutboundProxy(prefs);
      expect(settings.type, ProxyType.DEFAULT);
    });
  });

  group('outboundHttp test override', () {
    test('outboundHttp setter replaces the global factory', () {
      final fake = RecordingOutboundFactory();
      outboundHttp = fake;
      addTearDown(resetOutboundHttp);

      outboundHttp.clientFor(UserProxySettings(type: ProxyType.DEFAULT));
      outboundHttp.clientFor(
        UserProxySettings(type: ProxyType.HTTP, address: 'p:1'),
      );

      expect(fake.queries, hasLength(2));
      expect(fake.queries[0].type, ProxyType.DEFAULT);
      expect(fake.queries[1].type, ProxyType.HTTP);
    });
  });

  group('always-on Do Not Track / Sec-GPC headers', () {
    test('every outbound request carries DNT: 1 and Sec-GPC: 1', () async {
      // The privacy posture of this app is "do not track me" — every
      // Dart-side outbound call (downloads, blocklist updates, favicon
      // probes, user-script fetches) must advertise that on the wire
      // even when the caller didn't set the headers explicitly.
      late http.BaseRequest captured;
      final fake = RecordingOutboundFactory(
        clientBuilder: () => MockClient((req) async {
          captured = req;
          return http.Response('', 200);
        }),
      );
      outboundHttp = fake;
      addTearDown(resetOutboundHttp);

      final result = outboundHttp.clientFor(
        UserProxySettings(type: ProxyType.DEFAULT),
      );
      expect(result, isA<OutboundClientReady>());
      final client = (result as OutboundClientReady).client;
      addTearDown(client.close);
      await client.get(Uri.parse('https://example.com/'));

      expect(captured.headers['DNT'], '1');
      expect(captured.headers['Sec-GPC'], '1');
    });

    test('caller-supplied DNT header is preserved (no double-set)', () async {
      // The wrapper uses putIfAbsent so a test or odd-server probe that
      // explicitly sets a different DNT value keeps it.
      late http.BaseRequest captured;
      final fake = RecordingOutboundFactory(
        clientBuilder: () => MockClient((req) async {
          captured = req;
          return http.Response('', 200);
        }),
      );
      outboundHttp = fake;
      addTearDown(resetOutboundHttp);

      final result = outboundHttp.clientFor(
        UserProxySettings(type: ProxyType.DEFAULT),
      );
      final client = (result as OutboundClientReady).client;
      addTearDown(client.close);
      await client.get(
        Uri.parse('https://example.com/'),
        headers: {'DNT': '0'},
      );

      expect(captured.headers['DNT'], '0');
      expect(captured.headers['Sec-GPC'], '1');
    });
  });
}
