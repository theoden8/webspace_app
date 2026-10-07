import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/cookie_secure_storage.dart';
import 'package:webspace/services/webview.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;

import 'helpers/mock_secure_storage.dart';

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

  group('CookieSecureStorage', () {
    test('should save cookies to secure storage keyed by domain', () async {
      // Note: With COOKIE-006, only isSecure=true cookies go to secure storage
      final cookies = {
        'example.com': [
          Cookie(name: 'session', value: 'abc123', domain: 'example.com', isSecure: true),
          Cookie(name: 'token', value: 'xyz789', domain: 'example.com', isSecure: true),
        ],
      };

      await cookieSecureStorage.saveCookies(cookies);

      final storedData = mockSecureStorage.storage['secure_cookies'];
      expect(storedData, isNotNull);

      final decoded = jsonDecode(storedData!) as Map<String, dynamic>;
      expect(decoded['example.com'], hasLength(2));
    });

    test('should load cookies from secure storage keyed by domain', () async {
      // Pre-populate secure storage with domain-based keys
      final cookiesJson = {
        'example.com': [
          {'name': 'session', 'value': 'abc123', 'domain': 'example.com'},
        ],
      };
      await mockSecureStorage.write(
        key: 'secure_cookies',
        value: jsonEncode(cookiesJson),
      );

      final loaded = await cookieSecureStorage.loadCookies();

      expect(loaded['example.com'], hasLength(1));
      expect(loaded['example.com']![0].name, equals('session'));
      expect(loaded['example.com']![0].value, equals('abc123'));
    });

    test('should convert URL keys to domain keys when loading', () async {
      // Pre-populate secure storage with old URL-based keys
      final cookiesJson = {
        'https://example.com/path': [
          {'name': 'session', 'value': 'abc123', 'domain': 'example.com'},
        ],
      };
      await mockSecureStorage.write(
        key: 'secure_cookies',
        value: jsonEncode(cookiesJson),
      );

      final loaded = await cookieSecureStorage.loadCookies();

      // Should be converted to domain key
      expect(loaded['example.com'], hasLength(1));
      expect(loaded['example.com']![0].name, equals('session'));
    });

    test('should merge cookies when multiple URL keys resolve to same domain', () async {
      // Pre-populate secure storage with multiple URLs for same domain
      final cookiesJson = {
        'https://example.com': [
          {'name': 'cookie1', 'value': 'value1', 'domain': 'example.com'},
        ],
        'https://example.com/other': [
          {'name': 'cookie2', 'value': 'value2', 'domain': 'example.com'},
        ],
      };
      await mockSecureStorage.write(
        key: 'secure_cookies',
        value: jsonEncode(cookiesJson),
      );

      final loaded = await cookieSecureStorage.loadCookies();

      // Should merge into single domain key
      expect(loaded['example.com'], hasLength(2));
      expect(loaded['example.com']!.map((c) => c.name).toSet(), equals({'cookie1', 'cookie2'}));
    });

    test('should migrate cookies from SharedPreferences to secure storage with domain keys', () async {
      // Set up SharedPreferences with cookies in webViewModels (old URL-based format)
      // Note: Legacy cookies without isSecure flag are treated as non-secure (COOKIE-006)
      // and stored in SharedPreferences, not secure storage
      final webViewModelsJson = [
        jsonEncode({
          'initUrl': 'https://example.com',
          'currentUrl': 'https://example.com',
          'name': 'Example',
          'pageTitle': 'Example Site',
          'cookies': [
            {'name': 'legacy_cookie', 'value': 'old_value', 'domain': 'example.com'},
          ],
          'proxySettings': {'type': 'DEFAULT', 'host': '', 'port': 0},
          'javascriptEnabled': true,
          'userAgent': '',
          'thirdPartyCookiesEnabled': false,
        }),
      ];

      SharedPreferences.setMockInitialValues({
        'webViewModels': webViewModelsJson,
      });

      // Load cookies - should migrate from SharedPreferences with domain-based keys
      final loaded = await cookieSecureStorage.loadCookies();

      // Should be keyed by domain, not URL
      expect(loaded['example.com'], hasLength(1));
      expect(loaded['example.com']![0].name, equals('legacy_cookie'));
      expect(loaded['example.com']![0].value, equals('old_value'));

      // Legacy cookies without isSecure go to SharedPreferences cookies_fallback (COOKIE-006)
      final prefs = await SharedPreferences.getInstance();
      final prefsData = prefs.getString('cookies_fallback');
      expect(prefsData, isNotNull);

      // Verify migration flag was set
      expect(prefs.getBool('cookies_migrated_to_secure'), isTrue);
    });

    test('should merge cookies during migration when multiple sites share domain', () async {
      // Set up SharedPreferences with two sites on same domain
      final webViewModelsJson = [
        jsonEncode({
          'initUrl': 'https://github.com',
          'currentUrl': 'https://github.com',
          'name': 'GitHub',
          'pageTitle': 'GitHub',
          'cookies': [
            {'name': 'cookie1', 'value': 'value1', 'domain': 'github.com'},
          ],
          'proxySettings': {'type': 'DEFAULT', 'host': '', 'port': 0},
          'javascriptEnabled': true,
          'userAgent': '',
          'thirdPartyCookiesEnabled': false,
        }),
        jsonEncode({
          'initUrl': 'https://github.com/org',
          'currentUrl': 'https://github.com/org',
          'name': 'GitHub Org',
          'pageTitle': 'GitHub Org',
          'cookies': [
            {'name': 'cookie2', 'value': 'value2', 'domain': 'github.com'},
          ],
          'proxySettings': {'type': 'DEFAULT', 'host': '', 'port': 0},
          'javascriptEnabled': true,
          'userAgent': '',
          'thirdPartyCookiesEnabled': false,
        }),
      ];

      SharedPreferences.setMockInitialValues({
        'webViewModels': webViewModelsJson,
      });

      final loaded = await cookieSecureStorage.loadCookies();

      // Should be merged under single domain key
      expect(loaded['github.com'], hasLength(2));
      expect(loaded['github.com']!.map((c) => c.name).toSet(), equals({'cookie1', 'cookie2'}));
    });

    test('should prefer secure storage over SharedPreferences', () async {
      // Set up both secure storage and SharedPreferences with different cookies
      final secureCookiesJson = {
        'example.com': [
          {'name': 'secure_cookie', 'value': 'secure_value', 'domain': 'example.com'},
        ],
      };
      await mockSecureStorage.write(
        key: 'secure_cookies',
        value: jsonEncode(secureCookiesJson),
      );

      final webViewModelsJson = [
        jsonEncode({
          'initUrl': 'https://example.com',
          'currentUrl': 'https://example.com',
          'name': 'Example',
          'pageTitle': 'Example Site',
          'cookies': [
            {'name': 'legacy_cookie', 'value': 'old_value', 'domain': 'example.com'},
          ],
          'proxySettings': {'type': 'DEFAULT', 'host': '', 'port': 0},
          'javascriptEnabled': true,
          'userAgent': '',
          'thirdPartyCookiesEnabled': false,
        }),
      ];

      SharedPreferences.setMockInitialValues({
        'webViewModels': webViewModelsJson,
      });

      // Load cookies - should prefer secure storage
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
      // Write invalid JSON to secure storage
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
      // Initially not migrated
      expect(await cookieSecureStorage.isMigrationComplete(), isFalse);

      // Trigger migration by loading from SharedPreferences
      final webViewModelsJson = [
        jsonEncode({
          'initUrl': 'https://example.com',
          'currentUrl': 'https://example.com',
          'name': 'Example',
          'pageTitle': 'Example Site',
          'cookies': [
            {'name': 'cookie', 'value': 'value', 'domain': 'example.com'},
          ],
          'proxySettings': {'type': 'DEFAULT', 'host': '', 'port': 0},
          'javascriptEnabled': true,
          'userAgent': '',
          'thirdPartyCookiesEnabled': false,
        }),
      ];

      SharedPreferences.setMockInitialValues({
        'webViewModels': webViewModelsJson,
      });

      await cookieSecureStorage.loadCookies();

      // Now should be migrated
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

      // Load cookies for specific site
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
      // Save cookies for first site (secure cookie)
      await cookieSecureStorage.saveCookiesForSite('site-id-1', [
        Cookie(name: 'session1', value: 'value1', domain: 'github.com', isSecure: true),
      ]);

      // Save cookies for second site (non-secure cookie)
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

      // Verify saved
      var loaded = await cookieSecureStorage.loadCookiesForSite('site-id-1');
      expect(loaded, hasLength(2));

      // Save empty list - should remove from both storages
      await cookieSecureStorage.saveCookiesForSite('site-id-1', []);

      // Verify removed
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
      final secureStorage = MockFlutterSecureStorage();
      final storage = CookieSecureStorage(secureStorage: secureStorage);
      SharedPreferences.setMockInitialValues({});

      // Save a mix of secure and non-secure cookies
      await storage.saveCookies({
        'github.com': [
          Cookie(name: 'session', value: 'secret123', domain: 'github.com', isSecure: true),
          Cookie(name: 'theme', value: 'dark', domain: 'github.com', isSecure: false),
        ],
      });

      // Verify secure cookie is in secure storage
      final secureData = secureStorage.storage['secure_cookies'];
      expect(secureData, isNotNull);
      final secureDecoded = jsonDecode(secureData!) as Map<String, dynamic>;
      expect(secureDecoded['github.com'], hasLength(1));
      expect(secureDecoded['github.com'][0]['name'], equals('session'));

      // Verify non-secure cookie is in SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      final prefsJson = prefs.getString('cookies_fallback');
      expect(prefsJson, isNotNull);
      final prefsDecoded = jsonDecode(prefsJson!) as Map<String, dynamic>;
      expect(prefsDecoded['github.com'], hasLength(1));
      expect(prefsDecoded['github.com'][0]['name'], equals('theme'));
    });

    test('loading merges cookies from both storages', () async {
      final secureStorage = MockFlutterSecureStorage();
      final storage = CookieSecureStorage(secureStorage: secureStorage);

      // Pre-populate secure storage with secure cookie
      await secureStorage.write(
        key: 'secure_cookies',
        value: jsonEncode({
          'github.com': [{'name': 'session', 'value': 'secret', 'domain': 'github.com', 'isSecure': true}],
        }),
      );

      // Pre-populate SharedPreferences with non-secure cookie
      SharedPreferences.setMockInitialValues({
        'cookies_fallback': jsonEncode({
          'github.com': [{'name': 'theme', 'value': 'dark', 'domain': 'github.com', 'isSecure': false}],
        }),
      });

      // Load should merge both
      final loaded = await storage.loadCookies();
      expect(loaded['github.com'], hasLength(2));
      expect(loaded['github.com']!.map((c) => c.name).toSet(), equals({'session', 'theme'}));
    });

    test('secure cookies NOT stored in SharedPreferences even if secure storage fails', () async {
      final failingSecureStorage = MockFlutterSecureStorage()
        ..throwOnRead = true
        ..throwOnWrite = true;
      final storage = CookieSecureStorage(secureStorage: failingSecureStorage);
      SharedPreferences.setMockInitialValues({});

      await storage.saveCookies({
        'github.com': [
          Cookie(name: 'session', value: 'secret', domain: 'github.com', isSecure: true),
          Cookie(name: 'theme', value: 'dark', domain: 'github.com', isSecure: false),
        ],
      });

      // Only non-secure cookie should be in SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      final prefsJson = prefs.getString('cookies_fallback');
      expect(prefsJson, isNotNull);
      final decoded = jsonDecode(prefsJson!) as Map<String, dynamic>;
      expect(decoded['github.com'], hasLength(1));
      expect(decoded['github.com'][0]['name'], equals('theme'));
    });

    test('site with only secure cookies has no entry in SharedPreferences', () async {
      final secureStorage = MockFlutterSecureStorage();
      final storage = CookieSecureStorage(secureStorage: secureStorage);
      SharedPreferences.setMockInitialValues({});

      await storage.saveCookies({
        'github.com': [
          Cookie(name: 'session', value: 'secret', domain: 'github.com', isSecure: true),
          Cookie(name: 'auth', value: 'token', domain: 'github.com', isSecure: true),
        ],
      });

      // SharedPreferences should have no github.com entry
      final prefs = await SharedPreferences.getInstance();
      final prefsJson = prefs.getString('cookies_fallback');
      expect(prefsJson, isNull); // No non-secure cookies at all
    });

    test('multiple sites with mixed secure cookies split correctly', () async {
      final secureStorage = MockFlutterSecureStorage();
      final storage = CookieSecureStorage(secureStorage: secureStorage);
      SharedPreferences.setMockInitialValues({});

      await storage.saveCookies({
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

      // Check secure storage
      final secureData = secureStorage.storage['secure_cookies'];
      final secureDecoded = jsonDecode(secureData!) as Map<String, dynamic>;
      expect(secureDecoded['github.com'], hasLength(1));
      expect(secureDecoded['github.com'][0]['name'], equals('session'));
      expect(secureDecoded['gitlab.com'], hasLength(1));
      expect(secureDecoded['gitlab.com'][0]['name'], equals('auth'));
      expect(secureDecoded.containsKey('example.com'), isFalse); // No secure cookies

      // Check SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      final prefsJson = prefs.getString('cookies_fallback');
      final prefsDecoded = jsonDecode(prefsJson!) as Map<String, dynamic>;
      expect(prefsDecoded['github.com'], hasLength(1));
      expect(prefsDecoded['github.com'][0]['name'], equals('theme'));
      expect(prefsDecoded['example.com'], hasLength(1));
      expect(prefsDecoded['example.com'][0]['name'], equals('prefs'));
      expect(prefsDecoded.containsKey('gitlab.com'), isFalse); // No non-secure cookies
    });
  });
}

