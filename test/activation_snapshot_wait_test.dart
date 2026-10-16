import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/controllers/site_activation_controller.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/surface_repaint_controller.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/services/file_store_io.dart';
import 'package:webspace/services/html_cache_service.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/activation_page.dart';
import 'helpers/fake_path_provider.dart';
import 'helpers/held_file_store.dart';
import 'helpers/isolations.dart';
import 'helpers/mock_cookie_manager.dart';
import 'helpers/mock_secure_storage.dart' show MockFlutterSecureStorage;
import 'helpers/model_fixture.dart';

/// A site's stored page snapshot is megabytes to decrypt. Its webview waits
/// for it only when it renders it; otherwise it builds at once and the
/// snapshot lands behind it, for a rebuild that renders it later.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late HeldFileStore store;
  late SiteActivationController activation;
  late WebViewModel site;

  Future<void> connect({required bool online}) async {
    ConnectivityService.onlineOverride = Future.value(online);
    await ConnectivityService.instance.isOnline();
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webspace_snapshot_wait_');
    useFakePathProvider(tempDir);
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'webspace',
      packageName: 'org.codeberg.theoden8.webspace',
      version: '0.0.1',
      buildNumber: '1',
      buildSignature: '',
    );
    store = HeldFileStore(IoFileStore('html_cache', overrideRoot: tempDir),
        holds: HeldCall.readText);
    HtmlCacheService.resetForTesting();
    await HtmlCacheService.instance
        .initialize(store: store, secureStorage: MockFlutterSecureStorage());
    site = WebViewModel(initUrl: 'https://example.com/', name: 'Example');
    await HtmlCacheService.instance
        .saveHtml(site.siteId, html: '<p>snapshot</p>', url: site.initUrl);
    HtmlCacheService.instance.evictInMemory(site.siteId);
    final sites = SiteRuntime()
      ..isolation = fakeSharedJar(cookies: MockCookieManager())
      ..applied(SitesLoaded([site]));
    final page = FakeActivationPage();
    activation = SiteActivationController(
      sites,
      host: page,
      residency: FakeResidency(sites),
      navStates: InMemoryWebViewStateStorage(),
      surface: SurfaceRepaintController(page, repaints: false, traceSuffix: ''),
    );
  });

  tearDown(() async {
    ConnectivityService.reset();
    HtmlCacheService.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  test('an online start builds without the snapshot it does not render',
      () async {
    await connect(online: true);
    await activation.ensureSiteHtmlForModel(site);
    expect(store.reached.isCompleted, isTrue, reason: 'the read began');
    expect(store.release.isCompleted, isFalse, reason: 'and was not waited on');

    store.release.complete();
    await pumpEventQueue();
    expect(HtmlCacheService.instance.getHtmlSync(site.siteId), '<p>snapshot</p>',
        reason: 'a rebuild offline still finds it');
  });

  for (final (name, caches, isOnline) in [
    ('a site that keeps its HTML', true, true),
    ('an offline start', false, false),
  ]) {
    test('$name waits for the snapshot it renders', () async {
      site.htmlCachingEnabled = caches;
      await connect(online: isOnline);
      var done = false;
      final ensuring =
          activation.ensureSiteHtmlForModel(site).then((_) => done = true);
      await store.reached.future;
      await pumpEventQueue();
      expect(done, isFalse);

      store.release.complete();
      await ensuring;
      expect(HtmlCacheService.instance.getHtmlSync(site.siteId), '<p>snapshot</p>');
    });
  }
}
