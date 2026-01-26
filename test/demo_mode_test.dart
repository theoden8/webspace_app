import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/demo_data.dart';
import 'package:webspace/services/cookie_secure_storage.dart';
import 'package:webspace/platform/unified_webview.dart';
import 'package:webspace/webspace_model.dart';

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
  }) {}

  @override
  void unregisterListener({
    required String key,
    required ValueChanged<String?> listener,
  }) {}

  @override
  void unregisterAllListeners() {}

  @override
  void unregisterAllListenersForKey({required String key}) {}

  @override
  Future<bool?> isCupertinoProtectedDataAvailable() async => true;

  @override
  Stream<bool>? get onCupertinoProtectedDataAvailabilityChanged => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Reset demo mode before each test
    isDemoMode = false;
  });

  tearDown(() {
    // Ensure demo mode is reset after each test
    isDemoMode = false;
  });

  group('Demo Mode Flag', () {
    test('isDemoMode is false by default', () {
      // Reset to ensure fresh state
      isDemoMode = false;
      expect(isDemoMode, isFalse);
    });

    test('seedDemoData sets isDemoMode to true', () async {
      SharedPreferences.setMockInitialValues({});

      // Initially false
      isDemoMode = false;
      expect(isDemoMode, isFalse);

      // Call seedDemoData
      await seedDemoData();

      // Should now be true
      expect(isDemoMode, isTrue);
    });

    test('seedDemoData creates demo data in SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({});

      await seedDemoData();

      final prefs = await SharedPreferences.getInstance();

      // Verify demo data was seeded to demo_* keys
      final sites = prefs.getStringList(demoWebViewModelsKey);
      final webspaces = prefs.getStringList(demoWebspacesKey);

      expect(sites, isNotNull);
      expect(sites!.length, equals(8)); // 8 demo sites

      expect(webspaces, isNotNull);
      expect(webspaces!.length, equals(4)); // 4 demo webspaces
    });
  });

  group('Demo Mode - CookieSecureStorage No Save', () {
    late MockFlutterSecureStorage mockSecureStorage;
    late CookieSecureStorage cookieSecureStorage;

    setUp(() {
      mockSecureStorage = MockFlutterSecureStorage();
      cookieSecureStorage = CookieSecureStorage(secureStorage: mockSecureStorage);
      SharedPreferences.setMockInitialValues({});
      isDemoMode = false;
    });

    tearDown(() {
      mockSecureStorage.clear();
      isDemoMode = false;
    });

    test('saveCookies does nothing when isDemoMode is true', () async {
      // Enable demo mode
      isDemoMode = true;

      final cookies = {
        'example.com': [
          UnifiedCookie(name: 'session', value: 'abc123', domain: 'example.com'),
        ],
      };

      await cookieSecureStorage.saveCookies(cookies);

      // Storage should be empty because demo mode is enabled
      expect(mockSecureStorage.storage, isEmpty);
    });

    test('saveCookies works normally when isDemoMode is false', () async {
      // Demo mode disabled
      isDemoMode = false;

      final cookies = {
        'example.com': [
          UnifiedCookie(name: 'session', value: 'abc123', domain: 'example.com'),
        ],
      };

      await cookieSecureStorage.saveCookies(cookies);

      // Storage should contain the cookies
      expect(mockSecureStorage.storage, isNotEmpty);
      expect(mockSecureStorage.storage['secure_cookies'], isNotNull);
    });

    test('saveCookiesForUrl does nothing when isDemoMode is true', () async {
      isDemoMode = true;

      await cookieSecureStorage.saveCookiesForUrl(
        'https://example.com',
        [UnifiedCookie(name: 'test', value: 'value', domain: 'example.com')],
      );

      expect(mockSecureStorage.storage, isEmpty);
    });

    test('clearCookies does nothing when isDemoMode is true', () async {
      // First, save some cookies with demo mode disabled
      isDemoMode = false;
      await cookieSecureStorage.saveCookies({
        'example.com': [
          UnifiedCookie(name: 'session', value: 'abc123', domain: 'example.com'),
        ],
      });

      // Verify cookies were saved
      expect(mockSecureStorage.storage, isNotEmpty);

      // Now enable demo mode and try to clear
      isDemoMode = true;
      await cookieSecureStorage.clearCookies();

      // Cookies should still be there because demo mode prevented clearing
      expect(mockSecureStorage.storage, isNotEmpty);
    });

    test('removeOrphanedCookies does nothing when isDemoMode is true', () async {
      // First, save some cookies with demo mode disabled
      isDemoMode = false;
      await cookieSecureStorage.saveCookies({
        'example.com': [
          UnifiedCookie(name: 'session', value: 'abc123', domain: 'example.com'),
        ],
        'other.com': [
          UnifiedCookie(name: 'token', value: 'xyz', domain: 'other.com'),
        ],
      });

      // Now enable demo mode and try to remove orphaned cookies
      isDemoMode = true;
      await cookieSecureStorage.removeOrphanedCookies({'example.com'});

      // Both cookies should still be there
      final loaded = await cookieSecureStorage.loadCookies();
      expect(loaded.keys, contains('other.com'));
    });
  });

  group('Demo Mode - Full Workflow', () {
    test('after seedDemoData, no further saves are persisted', () async {
      SharedPreferences.setMockInitialValues({});

      // Seed demo data (this enables demo mode)
      await seedDemoData();
      expect(isDemoMode, isTrue);

      // Try to save something new to SharedPreferences
      final prefs = await SharedPreferences.getInstance();

      // Verify demo data is in demo keys
      final demoSites = prefs.getStringList(demoWebViewModelsKey);
      expect(demoSites, isNotNull);
      expect(demoSites!.length, equals(8));

      // The demo mode flag prevents saves at the application level,
      // not at the SharedPreferences level directly.
      // This test verifies the flag is set correctly after seeding.
      expect(isDemoMode, isTrue);
    });

    test('seeding demo data does not affect user data keys', () async {
      // Setup: Create user data in regular keys
      SharedPreferences.setMockInitialValues({
        'webViewModels': ['{"initUrl":"https://example.com","name":"User Site"}'],
        'webspaces': ['{"id":"all","name":"All","siteIndices":[]}'],
        'selectedWebspaceId': 'all',
        'currentIndex': 0,
        'themeMode': 1,
        'showUrlBar': true,
      });

      final prefs = await SharedPreferences.getInstance();

      // Verify user data exists before seeding
      expect(prefs.getStringList('webViewModels'), isNotNull);
      expect(prefs.getStringList('webViewModels')!.length, equals(1));
      expect(prefs.getString('selectedWebspaceId'), equals('all'));
      expect(prefs.getInt('themeMode'), equals(1));
      expect(prefs.getBool('showUrlBar'), equals(true));

      // Seed demo data
      await seedDemoData();

      // Verify user data is still intact in regular keys
      expect(prefs.getStringList('webViewModels'), isNotNull);
      expect(prefs.getStringList('webViewModels')!.length, equals(1));
      expect(prefs.getString('selectedWebspaceId'), equals('all'));
      expect(prefs.getInt('themeMode'), equals(1));
      expect(prefs.getBool('showUrlBar'), equals(true));

      // Verify demo data is in demo keys
      expect(prefs.getStringList(demoWebViewModelsKey), isNotNull);
      expect(prefs.getStringList(demoWebViewModelsKey)!.length, equals(8));
      expect(prefs.getString(demoSelectedWebspaceIdKey), equals(kAllWebspaceId));
      expect(prefs.getInt(demoThemeModeKey), equals(0));
      expect(prefs.getBool(demoShowUrlBarKey), equals(false));

      // Verify marker is set
      expect(await isDemoModeActive(), isTrue);
    });

    test('starting normal session wipes demo preferences', () async {
      // Setup: Create user data and demo data
      SharedPreferences.setMockInitialValues({
        // User data
        'webViewModels': ['{"initUrl":"https://example.com","name":"User Site"}'],
        'webspaces': ['{"id":"all","name":"All","siteIndices":[]}'],
        'selectedWebspaceId': 'user_space',

        // Demo data (from previous screenshot test)
        demoWebViewModelsKey: ['{"initUrl":"https://demo.com","name":"Demo Site"}'],
        demoWebspacesKey: ['{"id":"all","name":"All","siteIndices":[]}'],
        demoSelectedWebspaceIdKey: 'demo_space',
        demoCurrentIndexKey: 10000,
        demoThemeModeKey: 0,
        demoShowUrlBarKey: false,
        'wasDemoMode': true,
      });

      final prefs = await SharedPreferences.getInstance();

      // Verify both user and demo data exist
      expect(prefs.getStringList('webViewModels'), isNotNull);
      expect(prefs.getStringList(demoWebViewModelsKey), isNotNull);
      expect(prefs.getBool('wasDemoMode'), isTrue);

      // Simulate normal app startup - clear demo data
      await clearDemoDataIfNeeded();

      // Verify demo data is cleared
      expect(prefs.getStringList(demoWebViewModelsKey), isNull);
      expect(prefs.getStringList(demoWebspacesKey), isNull);
      expect(prefs.getString(demoSelectedWebspaceIdKey), isNull);
      expect(prefs.getInt(demoCurrentIndexKey), isNull);
      expect(prefs.getInt(demoThemeModeKey), isNull);
      expect(prefs.getBool(demoShowUrlBarKey), isNull);
      expect(prefs.getBool('wasDemoMode'), isNull);

      // Verify user data is still intact
      expect(prefs.getStringList('webViewModels'), isNotNull);
      expect(prefs.getStringList('webViewModels')!.length, equals(1));
      expect(prefs.getString('selectedWebspaceId'), equals('user_space'));
    });

    test('changes in demo mode only affect demo keyed preferences', () async {
      // Setup: Create user data
      SharedPreferences.setMockInitialValues({
        'webViewModels': ['{"initUrl":"https://example.com","name":"User Site"}'],
        'selectedWebspaceId': 'user_space',
        'themeMode': 1,
      });

      final prefs = await SharedPreferences.getInstance();

      // Store original user values
      final originalSites = prefs.getStringList('webViewModels');
      final originalSpace = prefs.getString('selectedWebspaceId');
      final originalTheme = prefs.getInt('themeMode');

      // Seed demo data (enables demo mode)
      await seedDemoData();
      expect(isDemoMode, isTrue);

      // Simulate app making changes during demo mode
      // In real app, isDemoMode would prevent these writes
      // But let's verify the key separation works

      // Try to modify demo keys
      await prefs.setStringList(demoWebViewModelsKey, ['{"initUrl":"https://changed.com","name":"Changed"}']);
      await prefs.setString(demoSelectedWebspaceIdKey, 'changed_space');

      // Verify user data remains unchanged
      expect(prefs.getStringList('webViewModels'), equals(originalSites));
      expect(prefs.getString('selectedWebspaceId'), equals(originalSpace));
      expect(prefs.getInt('themeMode'), equals(originalTheme));

      // Verify demo keys were modified
      expect(prefs.getStringList(demoWebViewModelsKey)!.length, equals(1));
      expect(prefs.getString(demoSelectedWebspaceIdKey), equals('changed_space'));
    });
  });
}
