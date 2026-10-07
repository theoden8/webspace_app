// What the secret stores leave in the keystore and on disk is read back by
// every later release, so the shared primitives must reproduce the bytes
// the per-store code wrote: the same keystore keys, options, JSON and
// sealed-blob layout. Each case below reads data shaped by the code these
// primitives replaced, or pins the exact string stored.
import 'dart:convert';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/block_stats_detail_storage.dart';
import 'package:webspace/services/cookie_secure_storage.dart';
import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/html_cache_service.dart';
import 'package:webspace/services/html_import_storage.dart';
import 'package:webspace/services/http_auth_engine.dart';
import 'package:webspace/services/http_auth_secure_storage.dart';
import 'package:webspace/services/keychain_aead.dart';
import 'package:webspace/services/keystore.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/proxy_password_secure_storage.dart';
import 'package:webspace/services/tor_bridge_secure_storage.dart';
import 'package:webspace/services/tor_bridges.dart';
import 'package:webspace/services/url_host.dart';
import 'package:webspace/services/webview_state_secure_storage.dart';

import 'helpers/mock_secure_storage.dart' show MockFlutterSecureStorage;

/// The removed per-store sealing code, verbatim in effect: AES-GCM under the
/// base64 key, a random 12-byte nonce prepended, the whole base64-encoded.
String _oldSeal(String keyBase64, String plaintext) {
  final key = encrypt.Key(Uint8List.fromList(base64.decode(keyBase64)));
  final gcm = encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.gcm));
  final iv = encrypt.IV.fromSecureRandom(12);
  final enc = gcm.encrypt(plaintext, iv: iv);
  final wire = Uint8List(iv.bytes.length + enc.bytes.length)
    ..setRange(0, iv.bytes.length, iv.bytes)
    ..setRange(iv.bytes.length, iv.bytes.length + enc.bytes.length, enc.bytes);
  return base64.encode(wire);
}

String _oldUnseal(String keyBase64, String wireBase64) {
  final key = encrypt.Key(Uint8List.fromList(base64.decode(keyBase64)));
  final gcm = encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.gcm));
  final wire = base64.decode(wireBase64);
  return gcm.decrypt(encrypt.Encrypted(Uint8List.fromList(wire.sublist(12))),
      iv: encrypt.IV(Uint8List.fromList(wire.sublist(0, 12))));
}

String _oldLegacyCbcSeal(String keyBase64, String plaintext) {
  final bytes = base64.decode(keyBase64);
  final key = encrypt.Key(Uint8List.fromList(bytes));
  final cbc = encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.cbc));
  return cbc
      .encrypt(plaintext, iv: encrypt.IV(Uint8List.fromList(bytes.sublist(0, 16))))
      .base64;
}

final String _key = base64.encode(List<int>.generate(32, (i) => i * 7 % 256));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'webspace',
      packageName: 'org.codeberg.theoden8.webspace',
      version: '0.0.1',
      buildNumber: '1',
      buildSignature: '',
    );
    LogService.instance.resetForTest();
  });

  group('keystore options', () {
    // ignore_for_file: deprecated_member_use
    test('each keystore keeps the options its entries were written with', () {
      const legacyAndroid = AndroidOptions(encryptedSharedPreferences: true);
      const firstUnlock =
          IOSOptions(accessibility: KeychainAccessibility.first_unlock);
      Map<String, String> opts(FlutterSecureStorage s) =>
          {...s.aOptions.toMap(), ...s.iOptions.toMap()};

      expect(opts(Keystores.credentials),
          {...legacyAndroid.toMap(), ...firstUnlock.toMap()});
      expect(opts(Keystores.torBridges),
          {...AndroidOptions.defaultOptions.toMap(), ...firstUnlock.toMap()});
      expect(opts(Keystores.archive),
          {...legacyAndroid.toMap(), ...IOSOptions.defaultOptions.toMap()});
      expect(opts(Keystores.aeadKeys), opts(const FlutterSecureStorage()));
    });
  });

  group('KeychainAead', () {
    test('opens a key the old code stored, and leaves it as stored', () async {
      final keychain = MockFlutterSecureStorage();
      await keychain.write(key: 'k', value: _key);
      final aead = await KeychainAead.open(keychain, 'k', logTag: LogTag.test);
      expect(aead!.unseal(_oldSeal(_key, 'hello')), 'hello');
      expect(_oldUnseal(_key, aead.seal('world')), 'world');
      expect(keychain.storage, {'k': _key});
    });

    test('a fresh key is 32 bytes, base64, under the given name', () async {
      final keychain = MockFlutterSecureStorage();
      await KeychainAead.open(keychain, 'k', logTag: LogTag.test);
      expect(base64.decode(keychain.storage['k']!), hasLength(32));
    });

    test('a stored value that is not a 32-byte key opens nothing', () async {
      final keychain = MockFlutterSecureStorage();
      await keychain.write(key: 'short', value: base64.encode([1, 2, 3]));
      await keychain.write(key: 'garbage', value: 'not base64!');
      expect(await KeychainAead.open(keychain, 'short', logTag: LogTag.test), isNull);
      expect(await KeychainAead.open(keychain, 'garbage', logTag: LogTag.test), isNull);
      expect(keychain.storage['short'], base64.encode([1, 2, 3]),
          reason: 'an unreadable key is reported, never replaced');
    });

    test('seals with a fresh nonce each time', () async {
      final keychain = MockFlutterSecureStorage();
      final aead = (await KeychainAead.open(keychain, 'k', logTag: LogTag.test))!;
      expect(aead.seal('same'), isNot(aead.seal('same')));
    });

    test('a tampered, truncated or foreign blob reads as null', () async {
      final keychain = MockFlutterSecureStorage();
      final aead = (await KeychainAead.open(keychain, 'k', logTag: LogTag.test))!;
      final wire = base64.decode(aead.seal('secret'));
      wire[wire.length - 1] ^= 1;
      expect(aead.unseal(base64.encode(wire)), isNull);
      expect(aead.unseal('AAAA'), isNull);
      expect(aead.unseal('not base64!'), isNull);
      expect(aead.unseal(_oldSeal(base64.encode(List.filled(32, 9)), 'x')),
          isNull);
    });

    test('reads a pre-GCM import blob', () async {
      final keychain = MockFlutterSecureStorage();
      await keychain.write(key: 'k', value: _key);
      final aead = (await KeychainAead.open(keychain, 'k', logTag: LogTag.test))!;
      final legacy = _oldLegacyCbcSeal(_key, 'https://a\n<p>old</p>');
      expect(aead.unseal(legacy), isNull);
      expect(aead.unsealLegacyCbc(legacy), 'https://a\n<p>old</p>');
      expect(aead.unsealLegacyCbc(aead.seal('gcm')), isNull);
    });
  });

  group('encrypted stores read what the old code wrote', () {
    test('HTML cache', () async {
      final keychain = MockFlutterSecureStorage();
      await keychain.write(key: 'html_cache_encryption_key', value: _key);
      final store = MemoryFileStore();
      await store.writeText('s1.enc', _oldSeal(_key, 'https://a\n<p>a</p>'));
      HtmlCacheService.resetForTesting();
      await HtmlCacheService.instance
          .initialize(store: store, secureStorage: keychain);
      expect(await HtmlCacheService.instance.loadHtml('s1'),
          ('https://a', '<p>a</p>'));
    });

    test('HTML imports', () async {
      final keychain = MockFlutterSecureStorage();
      await keychain.write(key: 'html_import_encryption_key', value: _key);
      final store = MemoryFileStore();
      await store.writeText('s1.enc', _oldSeal(_key, 'file:///a\n<p>a</p>'));
      final imports = HtmlImportStorage(secureStorage: keychain, store: store);
      await imports.initialize();
      expect(await imports.loadHtml('s1'), ('file:///a', '<p>a</p>'));
    });

    test('webview state', () async {
      final keychain = MockFlutterSecureStorage();
      await keychain.write(key: 'webview_state_encryption_key', value: _key);
      final store = MemoryFileStore();
      await store.writeText(
          's1.t1.enc', _oldSeal(_key, base64.encode([1, 2, 3])));
      final state = SecureWebViewStateStorage(
          secureStorage: keychain, store: store, versionProvider: () => 'v1');
      expect(await state.loadState('s1.t1'), [1, 2, 3]);
    });

    test('block stats detail', () async {
      final keychain = MockFlutterSecureStorage();
      await keychain.write(
          key: 'block_stats_detail_encryption_key', value: _key);
      final store = MemoryFileStore();
      await store.writeText('detail.enc', _oldSeal(_key, '{"v":1}'));
      final detail =
          SecureBlockStatsDetailStore(secureStorage: keychain, store: store);
      expect(await detail.read(), '{"v":1}');
    });
  });

  group('JSON stores write the strings the old code wrote', () {
    test('proxy passwords', () async {
      final keychain = MockFlutterSecureStorage();
      await keychain.write(key: 'proxy_passwords', value: '{"a":"old"}');
      final store = ProxyPasswordSecureStorage(secureStorage: keychain);
      await store.savePassword('b', 'pw');
      expect(keychain.storage['proxy_passwords'], '{"a":"old","b":"pw"}');
      await store.saveAll({'a': null, 'b': ''});
      expect(keychain.storage.containsKey('proxy_passwords'), isFalse);
    });

    test('saved sign-ins', () async {
      final keychain = MockFlutterSecureStorage();
      final store = HttpAuthSecureStorage(secureStorage: keychain);
      await store.save('s1', Host('h.example'), 'r',
          const HttpAuthCredential(username: 'u', password: 'p'));
      expect(keychain.storage['http_auth_credentials'],
          '{"s1":[{"host":"h.example","realm":"r","username":"u","password":"p"}]}');
      await store.removeSite('s1');
      expect(keychain.storage.containsKey('http_auth_credentials'), isFalse);
    });

    test('tor bridges', () async {
      final keychain = MockFlutterSecureStorage();
      final store = TorBridgeSecureStorage(secureStorage: keychain);
      expect(await store.save(const TorBridgeConfig(enabled: true)), isTrue);
      expect(keychain.storage['tor_bridges'],
          '{"enabled":true,"transport":"obfs4","lines":[]}');
    });

    // inapp.Cookie's own toJson (alphabetical keys) shadows the extension
    // in webview.dart, for the old code as for the new.
    test('cookies split by isSecure between keystore and prefs', () async {
      final keychain = MockFlutterSecureStorage();
      final store = CookieSecureStorage(secureStorage: keychain);
      await store.saveCookiesForSite('s1', [
        inapp.Cookie(name: 'sid', value: 'x', domain: 'a.com', isSecure: true),
        inapp.Cookie(name: 'pref', value: 'y', domain: 'a.com'),
      ]);
      expect(
          keychain.storage['secure_cookies'],
          '{"s1":[{"domain":"a.com","expiresDate":null,"isHttpOnly":null,'
          '"isSecure":true,"isSessionOnly":null,"name":"sid","path":null,'
          '"sameSite":null,"value":"x"}]}');
      final prefs = await SharedPreferences.getInstance();
      expect(
          prefs.getString('cookies_fallback'),
          '{"s1":[{"domain":"a.com","expiresDate":null,"isHttpOnly":null,'
          '"isSecure":null,"isSessionOnly":null,"name":"pref","path":null,'
          '"sameSite":null,"value":"y"}]}');
    });
  });

  test('an entry that is not JSON never reaches the log', () async {
    // jsonDecode's FormatException quotes the source it choked on, and the
    // stores used to log the exception whole: a truncated password map put
    // the password into the app log.
    final keychain = MockFlutterSecureStorage();
    await keychain.write(key: 'proxy_passwords', value: '{"site":"hunter2"');
    final store = ProxyPasswordSecureStorage(secureStorage: keychain);
    expect(await store.loadAll(), isEmpty);
    final logged =
        LogService.instance.recent({LogTag.proxyPwdStore}, limit: 50, scan: 2000);
    expect(logged, isNotEmpty);
    expect(logged.map((e) => e.message).join('\n'), isNot(contains('hunter2')));
  });
}
