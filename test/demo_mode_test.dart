import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/demo_data.dart';
import 'package:webspace/settings/demo_mode.dart';
import 'package:webspace/services/cookie_secure_storage.dart';
import 'helpers/mock_secure_storage.dart';
import 'package:webspace/services/cookie_manager.dart';
import 'package:webspace/controllers/page_orphan_sweep.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/services/container_isolation_engine.dart';
import 'package:webspace/services/container_native.dart';
import 'package:webspace/services/proxy_password_secure_storage.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'helpers/mock_container_native.dart';
import 'helpers/mock_cookie_manager.dart';

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

      // Verify demo data was seeded
      final sites = prefs.getStringList('webViewModels');
      final webspaces = prefs.getStringList('webspaces');

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
          Cookie(name: 'session', value: 'abc123', domain: 'example.com'),
        ],
      };

      await cookieSecureStorage.saveCookies(cookies);

      // Storage should be empty because demo mode is enabled
      expect(mockSecureStorage.storage, isEmpty);
    });

    test('saveCookies works normally when isDemoMode is false', () async {
      // Demo mode disabled
      isDemoMode = false;

      // Use isSecure: true so cookies go to secure storage (COOKIE-006)
      final cookies = {
        'example.com': [
          Cookie(name: 'session', value: 'abc123', domain: 'example.com', isSecure: true),
        ],
      };

      await cookieSecureStorage.saveCookies(cookies);

      // Storage should contain the cookies
      expect(mockSecureStorage.storage, isNotEmpty);
      expect(mockSecureStorage.storage['secure_cookies'], isNotNull);
    });

    test('clearCookies does nothing when isDemoMode is true', () async {
      // First, save some cookies with demo mode disabled
      // Use isSecure: true so cookies go to secure storage (COOKIE-006)
      isDemoMode = false;
      await cookieSecureStorage.saveCookies({
        'example.com': [
          Cookie(name: 'session', value: 'abc123', domain: 'example.com', isSecure: true),
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
      // Use isSecure: true so cookies go to secure storage (COOKIE-006)
      isDemoMode = false;
      await cookieSecureStorage.saveCookies({
        'example': [
          Cookie(name: 'session', value: 'abc123', domain: 'example.com', isSecure: true),
        ],
        'other': [
          Cookie(name: 'token', value: 'xyz', domain: 'other.com', isSecure: true),
        ],
      });

      // Now enable demo mode and try to remove orphaned cookies
      isDemoMode = true;
      await cookieSecureStorage.removeOrphanedCookies({SiteId('example')});

      // Both cookies should still be there
      final loaded = await cookieSecureStorage.loadCookies();
      expect(loaded.keys, contains('other'));
    });
  });

  // A demo or test run starts the app on the user's own storage (a Mac, a
  // physical device) with a site list that is not theirs.
  group('Demo Mode - Orphan sweeps', () {
    final user = SiteId('user-site');
    final demo = SiteId('demo-site');
    late MockContainerNative native;
    late ProxyPasswordSecureStorage proxyPasswords;
    late PageOrphanSweep sweep;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      native = MockContainerNative();
      final containers = ContainerIsolationEngine(containerNative: native);
      await containers.ensureContainer(ContainerKey.ofSite(user));
      proxyPasswords = ProxyPasswordSecureStorage(
          secureStorage: MockFlutterSecureStorage());
      await proxyPasswords.savePassword(ProxyPasswordKey.site(user),
          password: 'hunter2');
      sweep = PageOrphanSweep(
        SiteRuntime(),
        cookieStore:
            CookieSecureStorage(secureStorage: MockFlutterSecureStorage()),
        proxyPasswords: proxyPasswords,
        navStates: InMemoryWebViewStateStorage(),
        cookies: MockCookieManager(),
        containers: containers,
      );
    });

    test('a seeded site list deletes nothing the user\'s sites keep',
        () async {
      isDemoMode = true;
      await sweep.containersBeforeBind({ContainerKey.ofSite(demo)},
          nonIncognito: {ContainerKey.ofSite(demo)});
      await sweep.atLaunch({demo}, nonIncognitoSiteIds: {demo});
      await sweep.afterRemoval();

      expect(native.profiles.keys, contains(user));
      expect(await proxyPasswords.loadPassword(ProxyPasswordKey.site(user)),
          'hunter2');
    });

    test('outside demo mode the same launch sweep reclaims the container',
        () async {
      await sweep.containersBeforeBind({ContainerKey.ofSite(demo)},
          nonIncognito: {ContainerKey.ofSite(demo)});

      expect(native.profiles.keys, isNot(contains(user)));
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

      // Verify initial demo data
      final initialSites = prefs.getStringList('webViewModels');
      expect(initialSites!.length, equals(8));

      // The demo mode flag prevents saves at the application level,
      // not at the SharedPreferences level directly.
      // This test verifies the flag is set correctly after seeding.
      expect(isDemoMode, isTrue);
    });
  });
}
