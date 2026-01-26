import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/cookie_secure_storage.dart';
import 'package:webspace/platform/unified_webview.dart';

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
    throw UnimplementedError();
  }

  @override
  void unregisterListener({required String key}) {
    throw UnimplementedError();
  }

  @override
  void unregisterAllListeners() {
    throw UnimplementedError();
  }
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

  group('CookieSecureStorage', () {
    test('should save cookies to secure storage', () async {
      final cookies = {
        'https://example.com': [
          UnifiedCookie(name: 'session', value: 'abc123', domain: 'example.com'),
          UnifiedCookie(name: 'token', value: 'xyz789', domain: 'example.com'),
        ],
      };

      await cookieSecureStorage.saveCookies(cookies);

      final storedData = mockSecureStorage.storage['secure_cookies'];
      expect(storedData, isNotNull);

      final decoded = jsonDecode(storedData!) as Map<String, dynamic>;
      expect(decoded['https://example.com'], hasLength(2));
    });

    test('should load cookies from secure storage', () async {
      // Pre-populate secure storage
      final cookiesJson = {
        'https://example.com': [
          {'name': 'session', 'value': 'abc123', 'domain': 'example.com'},
        ],
      };
      await mockSecureStorage.write(
        key: 'secure_cookies',
        value: jsonEncode(cookiesJson),
      );

      final loaded = await cookieSecureStorage.loadCookies();

      expect(loaded['https://example.com'], hasLength(1));
      expect(loaded['https://example.com']![0].name, equals('session'));
      expect(loaded['https://example.com']![0].value, equals('abc123'));
    });

    test('should migrate cookies from SharedPreferences to secure storage', () async {
      // Set up SharedPreferences with cookies in webViewModels
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

      // Load cookies - should migrate from SharedPreferences
      final loaded = await cookieSecureStorage.loadCookies();

      expect(loaded['https://example.com'], hasLength(1));
      expect(loaded['https://example.com']![0].name, equals('legacy_cookie'));
      expect(loaded['https://example.com']![0].value, equals('old_value'));

      // Verify cookies are now in secure storage
      final storedData = mockSecureStorage.storage['secure_cookies'];
      expect(storedData, isNotNull);

      // Verify migration flag was set
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('cookies_migrated_to_secure'), isTrue);
    });

    test('should prefer secure storage over SharedPreferences', () async {
      // Set up both secure storage and SharedPreferences with different cookies
      final secureCookiesJson = {
        'https://example.com': [
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

      expect(loaded['https://example.com'], hasLength(1));
      expect(loaded['https://example.com']![0].name, equals('secure_cookie'));
      expect(loaded['https://example.com']![0].value, equals('secure_value'));
    });

    test('should handle empty secure storage and empty SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({});

      final loaded = await cookieSecureStorage.loadCookies();

      expect(loaded, isEmpty);
    });

    test('should save cookies for single URL', () async {
      final cookies = [
        UnifiedCookie(name: 'session', value: 'abc123', domain: 'example.com'),
      ];

      await cookieSecureStorage.saveCookiesForUrl('https://example.com', cookies);

      final loaded = await cookieSecureStorage.loadCookies();
      expect(loaded['https://example.com'], hasLength(1));
      expect(loaded['https://example.com']![0].name, equals('session'));
    });

    test('should merge cookies when saving for single URL', () async {
      // Save initial cookies for first URL
      await cookieSecureStorage.saveCookies({
        'https://first.com': [
          UnifiedCookie(name: 'first', value: 'value1', domain: 'first.com'),
        ],
      });

      // Save cookies for second URL
      await cookieSecureStorage.saveCookiesForUrl('https://second.com', [
        UnifiedCookie(name: 'second', value: 'value2', domain: 'second.com'),
      ]);

      final loaded = await cookieSecureStorage.loadCookies();
      expect(loaded['https://first.com'], hasLength(1));
      expect(loaded['https://second.com'], hasLength(1));
    });

    test('should clear all cookies from secure storage', () async {
      await cookieSecureStorage.saveCookies({
        'https://example.com': [
          UnifiedCookie(name: 'session', value: 'abc123', domain: 'example.com'),
        ],
      });

      await cookieSecureStorage.clearCookies();

      final loaded = await cookieSecureStorage.loadCookies();
      expect(loaded, isEmpty);
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
      final cookie = UnifiedCookie(
        name: 'test_cookie',
        value: 'test_value',
        domain: '.example.com',
        path: '/api',
        expiresDate: 1735689600000,
        isSecure: true,
        isHttpOnly: true,
        isSessionOnly: false,
        sameSite: 'Strict',
      );

      await cookieSecureStorage.saveCookies({
        'https://example.com': [cookie],
      });

      final loaded = await cookieSecureStorage.loadCookies();
      final loadedCookie = loaded['https://example.com']![0];

      expect(loadedCookie.name, equals('test_cookie'));
      expect(loadedCookie.value, equals('test_value'));
      expect(loadedCookie.domain, equals('.example.com'));
      expect(loadedCookie.path, equals('/api'));
      expect(loadedCookie.expiresDate, equals(1735689600000));
      expect(loadedCookie.isSecure, isTrue);
      expect(loadedCookie.isHttpOnly, isTrue);
      expect(loadedCookie.isSessionOnly, isFalse);
      expect(loadedCookie.sameSite, equals('Strict'));
    });

    test('should handle multiple sites with cookies', () async {
      await cookieSecureStorage.saveCookies({
        'https://site1.com': [
          UnifiedCookie(name: 'cookie1', value: 'value1', domain: 'site1.com'),
        ],
        'https://site2.com': [
          UnifiedCookie(name: 'cookie2a', value: 'value2a', domain: 'site2.com'),
          UnifiedCookie(name: 'cookie2b', value: 'value2b', domain: 'site2.com'),
        ],
        'https://site3.com': [
          UnifiedCookie(name: 'cookie3', value: 'value3', domain: 'site3.com'),
        ],
      });

      final loaded = await cookieSecureStorage.loadCookies();

      expect(loaded.keys, hasLength(3));
      expect(loaded['https://site1.com'], hasLength(1));
      expect(loaded['https://site2.com'], hasLength(2));
      expect(loaded['https://site3.com'], hasLength(1));
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
    });
  });
}
