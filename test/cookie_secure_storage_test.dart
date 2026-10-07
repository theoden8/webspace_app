import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/cookie_secure_storage.dart';
import 'package:webspace/services/webview.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;

import 'helpers/mock_secure_storage.dart';

/// A site as builds before secure storage kept cookies in `webViewModels`,
/// holding one [cookie] on [url]'s host.
String _legacySite(String url, String name, String pageTitle,
        Map<String, String> cookie) =>
    jsonEncode({
      'initUrl': url,
      'currentUrl': url,
      'name': name,
      'pageTitle': pageTitle,
      'cookies': [cookie],
      'proxySettings': {'type': 'DEFAULT', 'host': '', 'port': 0},
      'javascriptEnabled': true,
      'userAgent': '',
      'thirdPartyCookiesEnabled': false,
    });

void _seedLegacySites(List<String> sites) =>
    SharedPreferences.setMockInitialValues({'webViewModels': sites});

/// The cookie names under [key] in a stored JSON blob.
List<Object?> _names(Map<String, dynamic> json, String key) =>
    [for (final c in json[key] as List) (c as Map)['name']];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockFlutterSecureStorage mockSecureStorage;
  late CookieSecureStorage cookieSecureStorage;

  setUp(() {
    mockSecureStorage = MockFlutterSecureStorage();
    cookieSecureStorage = CookieSecureStorage(secureStorage: mockSecureStorage);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    mockSecureStorage.clear();
  });

  Future<void> seedSecure(Map<String, Object> json) =>
      mockSecureStorage.write(key: 'secure_cookies', value: jsonEncode(json));
  Map<String, dynamic>? secureJson() {
    final raw = mockSecureStorage.storage['secure_cookies'];
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>?> fallbackJson() async {
    final raw =
        (await SharedPreferences.getInstance()).getString('cookies_fallback');
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  group('CookieSecureStorage', () {
    test('should save cookies to secure storage keyed by domain', () async {
      // Note: With COOKIE-006, only isSecure=true cookies go to secure storage
      await cookieSecureStorage.saveCookies({
        'example.com': [
          Cookie(name: 'session', value: 'abc123', domain: 'example.com', isSecure: true),
          Cookie(name: 'token', value: 'xyz789', domain: 'example.com', isSecure: true),
        ],
      });

      final decoded = secureJson();
      expect(decoded, isNotNull);
      expect(decoded!['example.com'], hasLength(2));
    });

    test('should load cookies from secure storage keyed by domain', () async {
      await seedSecure({
        'example.com': [
          {'name': 'session', 'value': 'abc123', 'domain': 'example.com'},
        ],
      });

      final loaded = await cookieSecureStorage.loadCookies();

      expect(loaded['example.com'], hasLength(1));
      expect(loaded['example.com']![0].name, equals('session'));
      expect(loaded['example.com']![0].value, equals('abc123'));
    });

    test('should convert URL keys to domain keys when loading', () async {
      await seedSecure({
        'https://example.com/path': [
          {'name': 'session', 'value': 'abc123', 'domain': 'example.com'},
        ],
      });

      final loaded = await cookieSecureStorage.loadCookies();

      expect(loaded['example.com'], hasLength(1));
      expect(loaded['example.com']![0].name, equals('session'));
    });

    test('should merge cookies when multiple URL keys resolve to same domain', () async {
      await seedSecure({
        'https://example.com': [
          {'name': 'cookie1', 'value': 'value1', 'domain': 'example.com'},
        ],
        'https://example.com/other': [
          {'name': 'cookie2', 'value': 'value2', 'domain': 'example.com'},
        ],
      });

      final loaded = await cookieSecureStorage.loadCookies();

      expect(loaded['example.com'], hasLength(2));
      expect(loaded['example.com']!.map((c) => c.name).toSet(), equals({'cookie1', 'cookie2'}));
    });

    test('should migrate cookies from SharedPreferences to secure storage with domain keys', () async {
      // Legacy cookies without isSecure flag are treated as non-secure
      // (COOKIE-006) and stored in SharedPreferences, not secure storage.
      _seedLegacySites([
        _legacySite('https://example.com', 'Example', 'Example Site',
            {'name': 'legacy_cookie', 'value': 'old_value', 'domain': 'example.com'}),
      ]);

      final loaded = await cookieSecureStorage.loadCookies();

      // Should be keyed by domain, not URL
      expect(loaded['example.com'], hasLength(1));
      expect(loaded['example.com']![0].name, equals('legacy_cookie'));
      expect(loaded['example.com']![0].value, equals('old_value'));

      expect(await fallbackJson(), isNotNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('cookies_migrated_to_secure'), isTrue);
    });

    test('should merge cookies during migration when multiple sites share domain', () async {
      _seedLegacySites([
        _legacySite('https://github.com', 'GitHub', 'GitHub',
            {'name': 'cookie1', 'value': 'value1', 'domain': 'github.com'}),
        _legacySite('https://github.com/org', 'GitHub Org', 'GitHub Org',
            {'name': 'cookie2', 'value': 'value2', 'domain': 'github.com'}),
      ]);

      final loaded = await cookieSecureStorage.loadCookies();

      expect(loaded['github.com'], hasLength(2));
      expect(loaded['github.com']!.map((c) => c.name).toSet(), equals({'cookie1', 'cookie2'}));
    });

    test('should prefer secure storage over SharedPreferences', () async {
      await seedSecure({
        'example.com': [
          {'name': 'secure_cookie', 'value': 'secure_value', 'domain': 'example.com'},
        ],
      });
      _seedLegacySites([
        _legacySite('https://example.com', 'Example', 'Example Site',
            {'name': 'legacy_cookie', 'value': 'old_value', 'domain': 'example.com'}),
      ]);

      final loaded = await cookieSecureStorage.loadCookies();

      expect(loaded['example.com'], hasLength(1));
      expect(loaded['example.com']![0].name, equals('secure_cookie'));
      expect(loaded['example.com']![0].value, equals('secure_value'));
    });

    test('should handle empty secure storage and empty SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({});

      final loaded = await cookieSecureStorage.loadCookies();

      expect(loaded, isEmpty);
    });

    test('should clear all cookies from both storages', () async {
      // Save mix of secure and non-secure cookies (COOKIE-006)
      await cookieSecureStorage.saveCookies({
        'example.com': [
          Cookie(name: 'session', value: 'abc123', domain: 'example.com', isSecure: true),
          Cookie(name: 'theme', value: 'dark', domain: 'example.com', isSecure: false),
        ],
      });

      await cookieSecureStorage.clearCookies();

      final loaded = await cookieSecureStorage.loadCookies();
      expect(loaded, isEmpty);
    });

    test('should remove orphaned cookies from both storages', () async {
      // Save cookies with mixed secure flags (COOKIE-006)
      await cookieSecureStorage.saveCookies({
        'github.com': [
          Cookie(name: 'session', value: 'abc', domain: 'github.com', isSecure: true),
          Cookie(name: 'theme', value: 'dark', domain: 'github.com', isSecure: false),
        ],
        'gitlab.com': [
          Cookie(name: 'session', value: 'def', domain: 'gitlab.com', isSecure: true),
        ],
        'bitbucket.org': [
          Cookie(name: 'prefs', value: 'ghi', domain: 'bitbucket.org', isSecure: false),
        ],
      });

      // Remove orphaned cookies - only github.com and bitbucket.org are active
      await cookieSecureStorage.removeOrphanedCookies({'github.com', 'bitbucket.org'});

      final loaded = await cookieSecureStorage.loadCookies();
      expect(loaded.keys, containsAll(['github.com', 'bitbucket.org']));
      expect(loaded.keys, isNot(contains('gitlab.com')));
      // github.com should have 2 cookies (both secure and non-secure preserved)
      expect(loaded['github.com'], hasLength(2));
      expect(loaded['bitbucket.org'], hasLength(1));
    });

    test('should not remove anything when all domains are active', () async {
      // Mix of secure and non-secure (COOKIE-006)
      await cookieSecureStorage.saveCookies({
        'github.com': [
          Cookie(name: 'session', value: 'abc', domain: 'github.com', isSecure: true),
        ],
        'gitlab.com': [
          Cookie(name: 'theme', value: 'def', domain: 'gitlab.com', isSecure: false),
        ],
      });

      await cookieSecureStorage.removeOrphanedCookies({'github.com', 'gitlab.com'});

      final loaded = await cookieSecureStorage.loadCookies();
      expect(loaded.length, equals(2));
    });

    test('should handle corrupted secure storage gracefully', () async {
      await mockSecureStorage.write(key: 'secure_cookies', value: 'not valid json');

      // Should fall back to SharedPreferences
      SharedPreferences.setMockInitialValues({});

      final loaded = await cookieSecureStorage.loadCookies();
      expect(loaded, isEmpty);
    });

    test('should preserve all cookie properties during save and load', () async {
      final cookie = Cookie(
        name: 'test_cookie',
        value: 'test_value',
        domain: '.example.com',
        path: '/api',
        expiresDate: 1735689600000,
        isSecure: true,
        isHttpOnly: true,
        isSessionOnly: false,
        sameSite: inapp.HTTPCookieSameSitePolicy.STRICT,
      );

      await cookieSecureStorage.saveCookies({
        'example.com': [cookie],
      });

      final loaded = await cookieSecureStorage.loadCookies();
      final loadedCookie = loaded['example.com']![0];

      expect(loadedCookie.name, equals('test_cookie'));
      expect(loadedCookie.value, equals('test_value'));
      expect(loadedCookie.domain, equals('.example.com'));
      expect(loadedCookie.path, equals('/api'));
      expect(loadedCookie.expiresDate, equals(1735689600000));
      expect(loadedCookie.isSecure, isTrue);
      expect(loadedCookie.isHttpOnly, isTrue);
      expect(loadedCookie.isSessionOnly, isFalse);
      expect(loadedCookie.sameSite, equals(inapp.HTTPCookieSameSitePolicy.STRICT));
    });

    test('should handle multiple sites with mixed secure cookies', () async {
      // Mix of secure and non-secure cookies across sites (COOKIE-006)
      await cookieSecureStorage.saveCookies({
        'site1.com': [
          Cookie(name: 'cookie1', value: 'value1', domain: 'site1.com', isSecure: true),
        ],
        'site2.com': [
          Cookie(name: 'cookie2a', value: 'value2a', domain: 'site2.com', isSecure: true),
          Cookie(name: 'cookie2b', value: 'value2b', domain: 'site2.com', isSecure: false),
        ],
        'site3.com': [
          Cookie(name: 'cookie3', value: 'value3', domain: 'site3.com', isSecure: false),
        ],
      });

      final loaded = await cookieSecureStorage.loadCookies();

      expect(loaded.keys, hasLength(3));
      expect(loaded['site1.com'], hasLength(1));
      expect(loaded['site2.com'], hasLength(2));
      expect(loaded['site3.com'], hasLength(1));
    });

    test('should report migration status correctly', () async {
      expect(await cookieSecureStorage.isMigrationComplete(), isFalse);

      _seedLegacySites([
        _legacySite('https://example.com', 'Example', 'Example Site',
            {'name': 'cookie', 'value': 'value', 'domain': 'example.com'}),
      ]);

      await cookieSecureStorage.loadCookies();

      expect(await cookieSecureStorage.isMigrationComplete(), isTrue);

      // Verify migrated with domain key
      final loaded = await cookieSecureStorage.loadCookies();
      expect(loaded['example.com'], isNotNull);
    });

    test('should load cookies for specific siteId with mixed secure flags', () async {
      // Save cookies keyed by siteId with mixed secure flags (COOKIE-006)
      await cookieSecureStorage.saveCookies({
        'site-id-1': [
          Cookie(name: 'session1', value: 'value1', domain: 'github.com', isSecure: true),
          Cookie(name: 'theme1', value: 'dark', domain: 'github.com', isSecure: false),
        ],
        'site-id-2': [
          Cookie(name: 'session2', value: 'value2', domain: 'github.com', isSecure: true),
        ],
      });

      final site1Cookies = await cookieSecureStorage.loadCookiesForSite('site-id-1');
      final site2Cookies = await cookieSecureStorage.loadCookiesForSite('site-id-2');
      final unknownSiteCookies = await cookieSecureStorage.loadCookiesForSite('unknown-site');

      expect(site1Cookies, hasLength(2));
      expect(site1Cookies.map((c) => c.name).toSet(), equals({'session1', 'theme1'}));

      expect(site2Cookies, hasLength(1));
      expect(site2Cookies[0].name, equals('session2'));

      expect(unknownSiteCookies, isEmpty);
    });

    test('should save cookies for specific siteId with mixed secure flags', () async {
      await cookieSecureStorage.saveCookiesForSite('site-id-1', [
        Cookie(name: 'session1', value: 'value1', domain: 'github.com', isSecure: true),
      ]);
      await cookieSecureStorage.saveCookiesForSite('site-id-2', [
        Cookie(name: 'theme2', value: 'value2', domain: 'github.com', isSecure: false),
      ]);

      // Verify both are stored independently
      final allCookies = await cookieSecureStorage.loadCookies();
      expect(allCookies.keys, containsAll(['site-id-1', 'site-id-2']));

      expect(allCookies['site-id-1'], hasLength(1));
      expect(allCookies['site-id-1']![0].name, equals('session1'));

      expect(allCookies['site-id-2'], hasLength(1));
      expect(allCookies['site-id-2']![0].name, equals('theme2'));
    });

    test('should remove cookies when saving empty list for siteId', () async {
      // Save cookies with mixed secure flags (COOKIE-006)
      await cookieSecureStorage.saveCookiesForSite('site-id-1', [
        Cookie(name: 'session', value: 'value1', domain: 'github.com', isSecure: true),
        Cookie(name: 'theme', value: 'dark', domain: 'github.com', isSecure: false),
      ]);

      var loaded = await cookieSecureStorage.loadCookiesForSite('site-id-1');
      expect(loaded, hasLength(2));

      // Save empty list - should remove from both storages
      await cookieSecureStorage.saveCookiesForSite('site-id-1', []);

      loaded = await cookieSecureStorage.loadCookiesForSite('site-id-1');
      expect(loaded, isEmpty);
    });

    test('should remove orphaned cookies by siteId from both storages', () async {
      // Save cookies for multiple siteIds with mixed secure flags (COOKIE-006)
      await cookieSecureStorage.saveCookies({
        'site-id-1': [
          Cookie(name: 'session1', value: 'value1', domain: 'github.com', isSecure: true),
        ],
        'site-id-2': [
          Cookie(name: 'theme2', value: 'value2', domain: 'gitlab.com', isSecure: false),
        ],
        'site-id-3': [
          Cookie(name: 'session3', value: 'value3', domain: 'bitbucket.org', isSecure: true),
          Cookie(name: 'prefs3', value: 'abc', domain: 'bitbucket.org', isSecure: false),
        ],
      });

      // Remove orphaned cookies - only site-id-1 and site-id-3 are active
      await cookieSecureStorage.removeOrphanedCookies({'site-id-1', 'site-id-3'});

      final loaded = await cookieSecureStorage.loadCookies();
      expect(loaded.keys, containsAll(['site-id-1', 'site-id-3']));
      expect(loaded.keys, isNot(contains('site-id-2')));
      expect(loaded.length, equals(2));
    });
  });

  group('COOKIE-006: Secure Flag Enforcement', () {
    test('secure cookies stored in secure storage, non-secure in SharedPreferences', () async {
      await cookieSecureStorage.saveCookies({
        'github.com': [
          Cookie(name: 'session', value: 'secret123', domain: 'github.com', isSecure: true),
          Cookie(name: 'theme', value: 'dark', domain: 'github.com', isSecure: false),
        ],
      });

      final secure = secureJson();
      expect(secure, isNotNull);
      expect(_names(secure!, 'github.com'), ['session']);

      final fallback = await fallbackJson();
      expect(fallback, isNotNull);
      expect(_names(fallback!, 'github.com'), ['theme']);
    });

    test('loading merges cookies from both storages', () async {
      await seedSecure({
        'github.com': [{'name': 'session', 'value': 'secret', 'domain': 'github.com', 'isSecure': true}],
      });
      SharedPreferences.setMockInitialValues({
        'cookies_fallback': jsonEncode({
          'github.com': [{'name': 'theme', 'value': 'dark', 'domain': 'github.com', 'isSecure': false}],
        }),
      });

      final loaded = await cookieSecureStorage.loadCookies();
      expect(loaded['github.com'], hasLength(2));
      expect(loaded['github.com']!.map((c) => c.name).toSet(), equals({'session', 'theme'}));
    });

    test('secure cookies NOT stored in SharedPreferences even if secure storage fails', () async {
      mockSecureStorage
        ..throwOnRead = true
        ..throwOnWrite = true;

      await cookieSecureStorage.saveCookies({
        'github.com': [
          Cookie(name: 'session', value: 'secret', domain: 'github.com', isSecure: true),
          Cookie(name: 'theme', value: 'dark', domain: 'github.com', isSecure: false),
        ],
      });

      final fallback = await fallbackJson();
      expect(fallback, isNotNull);
      expect(_names(fallback!, 'github.com'), ['theme']);
    });

    test('site with only secure cookies has no entry in SharedPreferences', () async {
      await cookieSecureStorage.saveCookies({
        'github.com': [
          Cookie(name: 'session', value: 'secret', domain: 'github.com', isSecure: true),
          Cookie(name: 'auth', value: 'token', domain: 'github.com', isSecure: true),
        ],
      });

      expect(await fallbackJson(), isNull); // No non-secure cookies at all
    });

    test('multiple sites with mixed secure cookies split correctly', () async {
      await cookieSecureStorage.saveCookies({
        'github.com': [
          Cookie(name: 'session', value: 'secret', domain: 'github.com', isSecure: true),
          Cookie(name: 'theme', value: 'dark', domain: 'github.com', isSecure: false),
        ],
        'gitlab.com': [
          Cookie(name: 'auth', value: 'token', domain: 'gitlab.com', isSecure: true),
        ],
        'example.com': [
          Cookie(name: 'prefs', value: 'value', domain: 'example.com', isSecure: false),
        ],
      });

      final secure = secureJson()!;
      expect(_names(secure, 'github.com'), ['session']);
      expect(_names(secure, 'gitlab.com'), ['auth']);
      expect(secure.containsKey('example.com'), isFalse);

      final fallback = (await fallbackJson())!;
      expect(_names(fallback, 'github.com'), ['theme']);
      expect(_names(fallback, 'example.com'), ['prefs']);
      expect(fallback.containsKey('gitlab.com'), isFalse);
    });
  });
}
