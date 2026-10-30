// What a session holds of a site's icon is not asked for again (ICON-008): an
// icon drawn again, as an open folder's tiles are on every page and every
// layout, shows it from its first frame without a request, and a site that
// answered that it names no icon is not searched again, while one that was
// not reached is.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/controllers/page_orphan_sweep.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/screens/add_site.dart'
    show FaviconUrlCache, UnifiedFaviconImage;
import 'package:webspace/services/cookie_secure_storage.dart';
import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/services/icon_image_store.dart';
import 'package:webspace/services/icon_service.dart';
import 'package:webspace/services/orphan_sweep_engine.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/proxy_password_secure_storage.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/fake_outbound.dart';
import 'helpers/isolations.dart';
import 'helpers/mock_secure_storage.dart';
import 'helpers/model_fixture.dart';

final Uint8List _png =
    Uint8List.fromList(img.encodePng(img.Image(width: 64, height: 64)));
const _svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1">'
    '<rect width="1" height="1" fill="#e33"/></svg>';
const _plain = 'https://plain.test/';

http.Response _sites(http.Request req) => switch (req.url.path) {
      '/' when req.url.host == 'plain.test' => http.Response(
          '<html><head></head></html>', 200,
          headers: {'content-type': 'text/html'}),
      '/' => http.Response(
          '<html><head><link rel="icon" href="/icon.png"></head></html>', 200,
          headers: {'content-type': 'text/html'}),
      '/icon.png' when req.url.host != 'plain.test' => http.Response.bytes(
          _png, 200,
          headers: {'content-type': 'image/png'}),
      '/icon.svg' => http.Response(_svg, 200,
          headers: {'content-type': 'image/svg+xml'}),
      _ => http.Response('', 404),
    };

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

void main() {
  late FakeOutbound factory;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    GlobalOutboundProxy.resetForTest();
    clearFaviconCache();
    factory = FakeOutbound(responder: _sites);
    outboundHttp = factory;
  });

  tearDown(() {
    resetOutboundHttp();
    clearFaviconCache();
  });

  for (final (name, site, kept, shows) in [
    ('an image', 'https://image.test/', 'https://image.test/icon.png',
        find.byType(Image)),
    ('an SVG', 'https://vector.test/', 'https://vector.test/icon.svg',
        find.byType(SvgPicture)),
    ('an icon found this session', 'https://found.test/', null,
        find.byType(Image)),
    ('the globe of a site with no icon', _plain, null,
        find.byIcon(Icons.language)),
  ]) {
    testWidgets(
        'ICON-008: $name drawn again shows from its first frame, and asks '
        'nothing', (tester) async {
      await FaviconUrlCache.initialize();
      if (kept != null) await FaviconUrlCache.set(site, faviconUrl: kept);
      final shown = ValueNotifier(true);
      addTearDown(shown.dispose);
      await tester.pumpWidget(MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: shown,
          builder: (context, on, _) => on
              ? UnifiedFaviconImage(
                  url: site, size: 24, proxy: OutboundProxy.app)
              : const SizedBox(),
        ),
      ));
      await _settle(tester);
      expect(shows, findsOneWidget);
      final asked = factory.requests.length;

      shown.value = false;
      await tester.pump();
      shown.value = true;
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(shows, findsOneWidget, reason: 'drawn again, from the first frame');
      await _settle(tester);
      expect(factory.requests.length, asked, reason: 'nothing is asked again');
    });
  }

  test('ICON-008: a site that names no icon is not searched again this '
      'session', () async {
    expect(await getFaviconUrlStream(_plain, proxy: OutboundProxy.app).toList(),
        isEmpty);
    expect(factory.requests, isNotEmpty);
    factory.requests.clear();

    expect(await getFaviconUrlStream(_plain, proxy: OutboundProxy.app).toList(),
        isEmpty);
    expect(factory.requests, isEmpty, reason: 'the site already answered');

    invalidateFaviconFor(_plain);
    await getFaviconUrlStream(_plain, proxy: OutboundProxy.app).drain<void>();
    expect(factory.requests, isNotEmpty,
        reason: 'the edit dialog\'s refresh asks again');
  });

  group('images on disk', () {
    late MemoryFileStore files;
    late IconImageStore previous;

    setUp(() {
      files = MemoryFileStore();
      previous = IconImageStore.instance;
      IconImageStore.instance = IconImageStore(store: files)..initialize();
    });

    tearDown(() => IconImageStore.instance = previous);

    test(
        'ICON-008: an image is kept on disk only for a site whose state may '
        'outlive the session, and read from there next launch', () async {
      await getIconBytes('https://archived.test/icon.png',
          proxy: OutboundProxy.app, persist: false);
      await pumpEventQueue();
      expect(await files.list(), isEmpty,
          reason: 'an archive-tier site leaves nothing on disk (ARCH-006)');

      const kept = 'https://kept.test/icon.png';
      final fetched =
          await getIconBytes(kept, proxy: OutboundProxy.app, persist: true);
      await pumpEventQueue();
      expect(await files.list(), hasLength(1));

      clearFaviconCache();
      factory
        ..requests.clear()
        ..responder = (_) => throw http.ClientException('offline');
      expect(
          await getIconBytes(kept, proxy: OutboundProxy.app, persist: true),
          fetched);
      expect(factory.requests, isEmpty, reason: 'the next launch reads it');
    });

    test(
        'ICON-008: the sweep keeps the images whose URL a live site keeps, '
        'and no other', () async {
      final alpha = WebViewModel(initUrl: 'https://alpha.test/', name: 'A');
      final beta = WebViewModel(initUrl: 'https://beta.test/', name: 'B');
      await FaviconUrlCache.initialize();
      for (final site in [alpha, beta]) {
        await FaviconUrlCache.set(site.initUrl,
            faviconUrl: '${site.initUrl}icon.png');
        await IconImageStore.instance
            .write('${site.initUrl}icon.png', bytes: _png);
      }
      await IconImageStore.instance
          .write('https://gone.test/icon.png', bytes: _png);

      final sweep = PageOrphanSweep(
        SiteRuntime()
          ..isolation = fakeContainers()
          ..applied(SitesLoaded([alpha, beta])),
        cookieStore:
            CookieSecureStorage(secureStorage: MockFlutterSecureStorage()),
        proxyPasswords: ProxyPasswordSecureStorage(
            secureStorage: MockFlutterSecureStorage()),
        navStates: InMemoryWebViewStateStorage(),
      );
      await sweep.removeOrphans(OrphanStore.iconImages,
          liveSiteIds: {alpha.siteId});

      expect(await IconImageStore.instance.read('https://alpha.test/icon.png'),
          isNotNull);
      expect(await files.list(), hasLength(1),
          reason: 'a site no longer live and an icon no site keeps go');
    });
  });

  for (final (how, unreach) in <(String, void Function())>[
    (
      'the network failed',
      () => factory.responder = (_) => throw http.ClientException('offline'),
    ),
    (
      'the page came back with an error',
      () => factory.responder = (_) => http.Response('', 503),
    ),
    ('its proxy was not up', () => factory.block = true),
  ]) {
    test('ICON-008: a site not reached because $how is searched again',
        () async {
      const site = 'https://later.test/';
      unreach();
      expect(await getFaviconUrlStream(site, proxy: OutboundProxy.app).toList(),
          isEmpty);

      factory
        ..responder = _sites
        ..block = false;
      final found =
          await getFaviconUrlStream(site, proxy: OutboundProxy.app).single;
      expect(Uri.parse(found.url).path, '/icon.png');
    });
  }
}
