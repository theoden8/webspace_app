import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/html_cache_service.dart';

import 'helpers/mock_secure_storage.dart' show MockFlutterSecureStorage;

class _FakePathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin {
  final Directory _dir;
  _FakePathProvider(this._dir);
  @override
  Future<String?> getApplicationDocumentsPath() async => _dir.path;
  @override
  Future<String?> getTemporaryPath() async => _dir.path;
}

/// Tests for the eviction race-condition fix.
///
/// The race: `_goHome` (and similar) used to schedule a fire-and-forget
/// `deleteCache` after a connectivity probe. By the time the probe
/// resolved, the rebuilt webview had often already saved a fresh
/// snapshot — and the deletion wiped that fresh entry. Closer races
/// also let an in-flight `saveHtml` from the disposed webview's still-
/// resolving `getHtml()` IPC overwrite the freshly-evicted memory cache.
///
/// The fix: [HtmlCacheService.evictInMemory] is sync, drops the
/// in-memory snapshot in the same event-loop turn the call site runs
/// in, and bumps a per-site eviction generation that [saveHtml]
/// captures at entry and re-checks before committing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late MockFlutterSecureStorage fakeSecureStorage;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webspace_html_cache_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir);
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'webspace',
      packageName: 'org.codeberg.theoden8.webspace',
      version: '0.0.1',
      buildNumber: '1',
      buildSignature: '',
    );
    fakeSecureStorage = MockFlutterSecureStorage();
    HtmlCacheService.resetForTesting();
    await HtmlCacheService.instance.initialize(
      overrideAppDir: tempDir,
      secureStorage: fakeSecureStorage,
    );
  });

  tearDown(() async {
    HtmlCacheService.resetForTesting();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('evictInMemory', () {
    test('drops in-memory snapshot synchronously', () async {
      final svc = HtmlCacheService.instance;
      await svc.saveHtml('site-1', '<p>cached</p>', 'https://example.com/');
      expect(svc.getHtmlSync('site-1'), '<p>cached</p>');

      svc.evictInMemory('site-1');

      // No await between evict and read - this is the contract `_goHome`
      // depends on. A rebuilt webview's `getHtmlSync` runs in the same
      // event-loop turn; it must see the eviction.
      expect(svc.getHtmlSync('site-1'), isNull);
    });

    test('resets the debounce window so the next save is allowed', () async {
      final svc = HtmlCacheService.instance;
      await svc.saveHtml('site-1', '<p>cached</p>', 'https://example.com/');
      // Just-saved: shouldSave is false within the 10s debounce.
      expect(svc.shouldSave('site-1'), isFalse);

      svc.evictInMemory('site-1');

      // After eviction the rebuilt webview's first onLoadStop must be
      // allowed to save - the cache for this site is now empty, the
      // debounce no longer protects useful state.
      expect(svc.shouldSave('site-1'), isTrue);
    });

    test('bumps the eviction generation per call', () async {
      final svc = HtmlCacheService.instance;
      // Two evictions in a row both bump the gen, so any save that
      // captured a gen between them is also rejected.
      await svc.saveHtml('site-1', '<p>v1</p>', 'https://example.com/');
      svc.evictInMemory('site-1');
      svc.evictInMemory('site-1');
      // The visible effect: getHtmlSync still returns null, and a
      // saveHtml that started before either eviction would still be
      // rejected (verified in the saveHtml race test below).
      expect(svc.getHtmlSync('site-1'), isNull);
    });
  });

  group('saveHtml gen check', () {
    test('rejects a save whose gen was invalidated mid-flight', () async {
      final svc = HtmlCacheService.instance;
      await svc.saveHtml('site-1', '<p>baseline</p>', 'https://example.com/');
      expect(svc.getHtmlSync('site-1'), '<p>baseline</p>');

      // Race: schedule a save. Synchronously evict before the save's
      // first await resumes - simulating `_goHome` running between when
      // the disposed webview's onLoadStop fired its `getHtml()` IPC and
      // when saveHtml lands.
      final saving = svc.saveHtml(
        'site-1',
        '<p>stale-from-pre-home</p>',
        'https://example.com/deep',
      );
      svc.evictInMemory('site-1');
      await saving;

      // saveHtml must observe the gen change and drop the write so the
      // stale snapshot can't resurrect itself over the eviction.
      expect(svc.getHtmlSync('site-1'), isNull);
      // On disk: rolled back. No file should remain for site-1.
      final cacheFile = File('${tempDir.path}/html_cache/site-1.enc');
      expect(await cacheFile.exists(), isFalse);
    });

    test('a save started after eviction is allowed', () async {
      final svc = HtmlCacheService.instance;
      svc.evictInMemory('site-1');
      await svc.saveHtml('site-1', '<p>fresh</p>', 'https://example.com/');
      expect(svc.getHtmlSync('site-1'), '<p>fresh</p>');
    });
  });

  group('deleteCache', () {
    test('drops in-memory entry synchronously even before disk delete completes', () async {
      final svc = HtmlCacheService.instance;
      await svc.saveHtml('site-1', '<p>cached</p>', 'https://example.com/');
      expect(svc.getHtmlSync('site-1'), '<p>cached</p>');

      // Don't await - check the in-memory state in the same turn.
      final pending = svc.deleteCache('site-1');
      expect(svc.getHtmlSync('site-1'), isNull);
      await pending;
      expect(svc.getHtmlSync('site-1'), isNull);
    });

    test('rejects an in-flight save scheduled before the delete', () async {
      final svc = HtmlCacheService.instance;
      // Stale save in flight when delete fires - same shape as a
      // disposed-webview onLoadStop racing an explicit deletion.
      final saving = svc.saveHtml('site-1', '<p>stale</p>', 'https://example.com/');
      final deleting = svc.deleteCache('site-1');
      await Future.wait([saving, deleting]);
      expect(svc.getHtmlSync('site-1'), isNull);
      final cacheFile = File('${tempDir.path}/html_cache/site-1.enc');
      expect(await cacheFile.exists(), isFalse);
    });
  });
}
