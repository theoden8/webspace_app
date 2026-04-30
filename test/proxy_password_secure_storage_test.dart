import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/proxy_password_secure_storage.dart';
import 'package:webspace/settings/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';

import 'helpers/mock_secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockFlutterSecureStorage mockSecureStorage;
  late ProxyPasswordSecureStorage store;

  setUp(() {
    mockSecureStorage = MockFlutterSecureStorage();
    store = ProxyPasswordSecureStorage(secureStorage: mockSecureStorage);
    SharedPreferences.setMockInitialValues({});
  });

  group('ProxyPasswordSecureStorage', () {
    test('savePassword + loadPassword round-trip', () async {
      await store.savePassword('site-1', 'shh');
      expect(await store.loadPassword('site-1'), equals('shh'));
    });

    test('savePassword(null) deletes the entry', () async {
      await store.savePassword('site-1', 'shh');
      await store.savePassword('site-1', null);
      expect(await store.loadPassword('site-1'), isNull);
    });

    test('savePassword("") deletes the entry', () async {
      await store.savePassword('site-1', 'shh');
      await store.savePassword('site-1', '');
      expect(await store.loadPassword('site-1'), isNull);
    });

    test('saveAll replaces the whole map', () async {
      await store.savePassword('a', '1');
      await store.savePassword('b', '2');
      await store.saveAll({'b': '2-updated', 'c': '3'});
      // 'a' is dropped because saveAll is a wholesale replace.
      expect(await store.loadPassword('a'), isNull);
      expect(await store.loadPassword('b'), equals('2-updated'));
      expect(await store.loadPassword('c'), equals('3'));
    });

    test('saveAll with empty map deletes the underlying entry', () async {
      await store.savePassword('a', '1');
      await store.saveAll({});
      expect(mockSecureStorage.storage.containsKey('proxy_passwords'), false);
    });

    test('removeOrphaned drops site keys not in the active set', () async {
      await store.savePassword('site-1', 'a');
      await store.savePassword('site-2', 'b');
      await store.savePassword('site-3', 'c');
      await store.savePassword(
          ProxyPasswordSecureStorage.globalProxyKey, 'global');

      await store.removeOrphaned({'site-1', 'site-3'});

      expect(await store.loadPassword('site-1'), equals('a'));
      expect(await store.loadPassword('site-2'), isNull);
      expect(await store.loadPassword('site-3'), equals('c'));
      // The reserved global key is preserved across orphan sweeps.
      expect(
          await store
              .loadPassword(ProxyPasswordSecureStorage.globalProxyKey),
          equals('global'));
    });

    test('plaintext password never lands in SharedPreferences via toJson',
        () async {
      // Default toJson omits the password — this is the at-rest contract.
      final settings = UserProxySettings(
        type: ProxyType.HTTP,
        address: 'p:8080',
        username: 'u',
        password: 'top-secret',
      );
      final json = jsonEncode(settings.toJson());
      expect(json.contains('top-secret'), isFalse);

      // The opt-in form (used only for backups) does include it.
      final backupJson = jsonEncode(settings.toJson(includePassword: true));
      expect(backupJson.contains('top-secret'), isTrue);
    });
  });

  group('ProxyPasswordSecureStorage.migrateLegacyPassword', () {
    test('moves plaintext password from SharedPreferences to secure storage',
        () async {
      final prefs = await SharedPreferences.getInstance();
      const prefsKey = 'someProxyKey';
      const secureKey = 'site-x';
      await prefs.setString(
        prefsKey,
        jsonEncode({
          'type': ProxyType.HTTP.index,
          'address': 'p:8080',
          'username': 'u',
          'password': 'legacy-secret',
        }),
      );

      final migrated = await store.migrateLegacyPassword(
        prefs: prefs,
        prefsKey: prefsKey,
        secureKey: secureKey,
      );

      expect(migrated, isTrue);
      // Password is now in secure storage.
      expect(await store.loadPassword(secureKey), equals('legacy-secret'));
      // Password is gone from prefs — only the non-secret fields remain.
      final rewritten = jsonDecode(prefs.getString(prefsKey)!) as Map;
      expect(rewritten.containsKey('password'), isFalse);
      expect(rewritten['address'], equals('p:8080'));
      expect(rewritten['username'], equals('u'));
    });

    test('idempotent — second invocation is a no-op', () async {
      final prefs = await SharedPreferences.getInstance();
      const prefsKey = 'someProxyKey';
      const secureKey = 'site-x';
      await prefs.setString(
        prefsKey,
        jsonEncode({
          'type': ProxyType.HTTP.index,
          'address': 'p:8080',
          'username': 'u',
          'password': 'legacy-secret',
        }),
      );

      expect(
          await store.migrateLegacyPassword(
              prefs: prefs, prefsKey: prefsKey, secureKey: secureKey),
          isTrue);
      expect(
          await store.migrateLegacyPassword(
              prefs: prefs, prefsKey: prefsKey, secureKey: secureKey),
          isFalse);
    });

    test('returns false when key absent from prefs', () async {
      final prefs = await SharedPreferences.getInstance();
      final migrated = await store.migrateLegacyPassword(
        prefs: prefs,
        prefsKey: 'nope',
        secureKey: 'site-x',
      );
      expect(migrated, isFalse);
    });

    test('returns false when prefs value is malformed JSON', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('bad', '{not json');
      final migrated = await store.migrateLegacyPassword(
        prefs: prefs,
        prefsKey: 'bad',
        secureKey: 'site-x',
      );
      expect(migrated, isFalse);
      // Malformed value is preserved as-is — we don't risk corrupting state
      // on data we couldn't decode.
      expect(prefs.getString('bad'), equals('{not json'));
    });

    test('returns false when password field is empty string', () async {
      final prefs = await SharedPreferences.getInstance();
      const prefsKey = 'someProxyKey';
      await prefs.setString(
        prefsKey,
        jsonEncode({
          'type': ProxyType.HTTP.index,
          'address': 'p:8080',
          'username': 'u',
          'password': '',
        }),
      );
      final migrated = await store.migrateLegacyPassword(
        prefs: prefs,
        prefsKey: prefsKey,
        secureKey: 'site-x',
      );
      expect(migrated, isFalse);
    });
  });

  group('GlobalOutboundProxy migration', () {
    setUp(() {
      GlobalOutboundProxy.setPasswordStoreForTest(store);
      GlobalOutboundProxy.resetForTest();
    });

    test('initialize migrates legacy plaintext password and hydrates current',
        () async {
      final prefs = await SharedPreferences.getInstance();
      // Pre-migration state: password lives in plaintext prefs.
      await prefs.setString(
        kGlobalOutboundProxyKey,
        jsonEncode({
          'type': ProxyType.SOCKS5.index,
          'address': '127.0.0.1:9050',
          'username': 'tor',
          'password': 'onion',
        }),
      );

      await GlobalOutboundProxy.initialize();

      // In-memory current has the password (hydrated from secure storage).
      expect(GlobalOutboundProxy.current.password, equals('onion'));
      expect(GlobalOutboundProxy.current.username, equals('tor'));
      // Prefs no longer holds the password.
      final rewritten =
          jsonDecode(prefs.getString(kGlobalOutboundProxyKey)!) as Map;
      expect(rewritten.containsKey('password'), isFalse);
      // Secure storage holds it.
      expect(
          await store
              .loadPassword(ProxyPasswordSecureStorage.globalProxyKey),
          equals('onion'));
    });

    test('update writes JSON-without-password to prefs and password to secure',
        () async {
      final prefs = await SharedPreferences.getInstance();
      await GlobalOutboundProxy.update(UserProxySettings(
        type: ProxyType.HTTP,
        address: 'corp:3128',
        username: 'me',
        password: 'hunter2',
      ));

      // Prefs JSON is sanitised.
      final raw = prefs.getString(kGlobalOutboundProxyKey)!;
      expect(raw.contains('hunter2'), isFalse);
      final decoded = jsonDecode(raw) as Map;
      expect(decoded['username'], equals('me'));
      expect(decoded.containsKey('password'), isFalse);

      // Password is in secure storage.
      expect(
          await store
              .loadPassword(ProxyPasswordSecureStorage.globalProxyKey),
          equals('hunter2'));
    });

    test('update with null password clears secure storage entry', () async {
      // First seed a password.
      await GlobalOutboundProxy.update(UserProxySettings(
        type: ProxyType.HTTP,
        address: 'corp:3128',
        username: 'me',
        password: 'hunter2',
      ));
      // Then update without one.
      await GlobalOutboundProxy.update(UserProxySettings(
        type: ProxyType.HTTP,
        address: 'corp:3128',
        username: 'me',
        password: null,
      ));
      expect(
          await store
              .loadPassword(ProxyPasswordSecureStorage.globalProxyKey),
          isNull);
    });
  });
}
