import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/cookie_secure_storage.dart';
import 'package:webspace/services/webview.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;

/// Mock implementation of FlutterSecureStorage for testing
class MockFlutterSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _storage = {};

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _storage.remove(key);
    } else {
      _storage[key] = value;
    }
  }

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return _storage[key];
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _storage.remove(key);
  }

  @override
  Future<bool> containsKey({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return _storage.containsKey(key);
  }

  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return Map<String, String>.from(_storage);
  }

  @override
  Future<void> deleteAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _storage.clear();
  }

  // Helper methods for testing
  void clear() => _storage.clear();
  Map<String, String> get storage => Map.unmodifiable(_storage);

  @override
  IOSOptions get iOptions => throw UnimplementedError();

  @override
  AndroidOptions get aOptions => throw UnimplementedError();

  @override
  LinuxOptions get lOptions => throw UnimplementedError();

  @override
  WebOptions get webOptions => throw UnimplementedError();

  @override
  MacOsOptions get mOptions => throw UnimplementedError();

  @override
  WindowsOptions get wOptions => throw UnimplementedError();

  @override
  void registerListener({
    required String key,
    required ValueChanged<String?> listener,
  }) {
    // No-op for testing
  }

  @override
  void unregisterListener({
    required String key,
    required ValueChanged<String?> listener,
  }) {
    // No-op for testing
  }

  @override
  void unregisterAllListeners() {
    // No-op for testing
  }

  @override
  void unregisterAllListenersForKey({required String key}) {
    // No-op for testing
  }

  @override
  Future<bool?> isCupertinoProtectedDataAvailable() async => true;

  @override
  Stream<bool>? get onCupertinoProtectedDataAvailabilityChanged => null;
}

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

  group('extractDomainFromUrl', () {
    test('should extract domain from full URL', () {
      expect(extractDomainFromUrl('https://example.com'), equals('example.com'));
      expect(extractDomainFromUrl('https://example.com/path'), equals('example.com'));
      expect(extractDomainFromUrl('https://sub.example.com/path?query=1'), equals('sub.example.com'));
      expect(extractDomainFromUrl('http://example.com:8080/path'), equals('example.com'));
    });

    test('should return original string for invalid URLs', () {
      expect(extractDomainFromUrl('not a url'), equals('not a url'));
      expect(extractDomainFromUrl(''), equals(''));
    });
  });

  group('CookieSecureStorage', () {
    test('should save cookies to secure storage keyed by domain', () async {
      final cookies = {
        'example.com': [
          Cookie(name: 'session', value: 'abc123', domain: 'example.com'),
          Cookie(name: 'token', value: 'xyz789', domain: 'example.com'),
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

      // Verify cookies are now in secure storage
      final storedData = mockSecureStorage.storage['secure_cookies'];
      expect(storedData, isNotNull);

      // Verify migration flag was set
      final prefs = await SharedPreferences.getInstance();
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

    test('should save cookies for single URL (converted to domain)', () async {
      final cookies = [
        Cookie(name: 'session', value: 'abc123', domain: 'example.com'),
      ];

      await cookieSecureStorage.saveCookiesForUrl('https://example.com', cookies);

      final loaded = await cookieSecureStorage.loadCookies();
      expect(loaded['example.com'], hasLength(1));
      expect(loaded['example.com']![0].name, equals('session'));
    });

    test('should merge cookies when saving for multiple domains', () async {
      // Save initial cookies for first domain
      await cookieSecureStorage.saveCookies({
        'first.com': [
          Cookie(name: 'first', value: 'value1', domain: 'first.com'),
        ],
      });

      // Save cookies for second domain
      await cookieSecureStorage.saveCookiesForUrl('https://second.com', [
        Cookie(name: 'second', value: 'value2', domain: 'second.com'),
      ]);

      final loaded = await cookieSecureStorage.loadCookies();
      expect(loaded['first.com'], hasLength(1));
      expect(loaded['second.com'], hasLength(1));
    });

    test('should clear all cookies from secure storage', () async {
      await cookieSecureStorage.saveCookies({
        'example.com': [
          Cookie(name: 'session', value: 'abc123', domain: 'example.com'),
        ],
      });

      await cookieSecureStorage.clearCookies();

      final loaded = await cookieSecureStorage.loadCookies();
      expect(loaded, isEmpty);
    });

    test('should remove orphaned cookies', () async {
      // Save cookies for multiple domains
      await cookieSecureStorage.saveCookies({
        'github.com': [
          Cookie(name: 'session', value: 'abc', domain: 'github.com'),
        ],
        'gitlab.com': [
          Cookie(name: 'session', value: 'def', domain: 'gitlab.com'),
        ],
        'bitbucket.org': [
          Cookie(name: 'session', value: 'ghi', domain: 'bitbucket.org'),
        ],
      });

      // Remove orphaned cookies - only github.com and bitbucket.org are active
      await cookieSecureStorage.removeOrphanedCookies({'github.com', 'bitbucket.org'});

      final loaded = await cookieSecureStorage.loadCookies();
      expect(loaded.keys, containsAll(['github.com', 'bitbucket.org']));
      expect(loaded.keys, isNot(contains('gitlab.com')));
      expect(loaded.length, equals(2));
    });

    test('should not remove anything when all domains are active', () async {
      await cookieSecureStorage.saveCookies({
        'github.com': [
          Cookie(name: 'session', value: 'abc', domain: 'github.com'),
        ],
        'gitlab.com': [
          Cookie(name: 'session', value: 'def', domain: 'gitlab.com'),
        ],
      });

      await cookieSecureStorage.removeOrphanedCookies({'github.com', 'gitlab.com'});

      final loaded = await cookieSecureStorage.loadCookies();
      expect(loaded.length, equals(2));
    });

    test('should clear cookies from SharedPreferences', () async {
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

      await cookieSecureStorage.clearSharedPreferencesCookies();

      final prefs = await SharedPreferences.getInstance();
      final updatedModels = prefs.getStringList('webViewModels')!;
      final model = jsonDecode(updatedModels[0]) as Map<String, dynamic>;
      expect(model['cookies'], isEmpty);
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

    test('should handle multiple sites with cookies', () async {
      await cookieSecureStorage.saveCookies({
        'site1.com': [
          Cookie(name: 'cookie1', value: 'value1', domain: 'site1.com'),
        ],
        'site2.com': [
          Cookie(name: 'cookie2a', value: 'value2a', domain: 'site2.com'),
          Cookie(name: 'cookie2b', value: 'value2b', domain: 'site2.com'),
        ],
        'site3.com': [
          Cookie(name: 'cookie3', value: 'value3', domain: 'site3.com'),
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
  });
}
