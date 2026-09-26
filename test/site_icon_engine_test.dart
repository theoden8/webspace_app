import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/site_icon_engine.dart';
import 'package:webspace/services/site_icon_store.dart';

Uint8List png(int width, [int? height]) => Uint8List.fromList(
    img.encodePng(img.Image(width: width, height: height ?? width)));

SiteIconEngine loadedEngine(String siteUrl, String pageUrl) =>
    SiteIconEngine(siteUrl)
      ..onLoadStarted(pageUrl)
      ..onLoadFinished(pageUrl);

void main() {
  group('pngDimensions', () {
    test('reads the IHDR size', () {
      expect(pngDimensions(png(48, 32)), (width: 48, height: 32));
    });

    test('null for non-PNG and truncated input', () {
      expect(pngDimensions(Uint8List.fromList([1, 2, 3])), isNull);
      expect(pngDimensions(png(32).sublist(0, 20)), isNull);
      final gif = Uint8List.fromList(img.encodeGif(img.Image(width: 8, height: 8)));
      expect(pngDimensions(gif), isNull);
    });
  });

  group('siteIconHost', () {
    test('folds www. and case', () {
      expect(siteIconHost('https://WWW.Example.com/a'), 'example.com');
      expect(siteIconHost('http://example.com:8080/'), 'example.com');
    });

    test('null for non-web URLs', () {
      expect(siteIconHost('about:blank'), isNull);
      expect(siteIconHost('data:text/html,x'), isNull);
      expect(siteIconHost('file:///index.html'), isNull);
      expect(siteIconHost(null), isNull);
    });
  });

  group('SiteIconEngine (ICON-009)', () {
    test('keeps the largest icon of a document whatever order they arrive in',
        () {
      final engine = loadedEngine('https://example.com/', 'https://example.com/');
      final accepted = <int>[];
      for (final size in [192, 16, 32, 64]) {
        final icon = engine.onIcon(png(size));
        if (icon != null) accepted.add(icon.edge);
      }
      expect(accepted, [192]);
    });

    test('reports each larger icon as it arrives', () {
      final engine = loadedEngine('https://example.com/', 'https://example.com/');
      expect(engine.onIcon(png(32))?.edge, 32);
      expect(engine.onIcon(png(32)), isNull);
      expect(engine.onIcon(png(192))?.edge, 192);
    });

    test('drops icons below the preference floor (ICON-010)', () {
      final engine = loadedEngine('https://example.com/', 'https://example.com/');
      expect(engine.onIcon(png(16)), isNull);
      expect(engine.onIcon(png(64, 16)), isNull);
      expect(engine.onIcon(png(kMinSiteIconEdge))?.edge, kMinSiteIconEdge);
    });

    test('drops icons while a main-frame load is in flight', () {
      final engine = SiteIconEngine('https://example.com/')
        ..onLoadStarted('https://example.com/');
      expect(engine.onIcon(png(64)), isNull);
      engine.onLoadFinished('https://example.com/');
      expect(engine.onIcon(png(64))?.edge, 64);
      engine.onLoadStarted('https://example.com/next');
      expect(engine.onIcon(png(128)), isNull,
          reason: 'a late icon from the previous document');
    });

    test('drops icons of a document on another host', () {
      final engine = loadedEngine(
          'https://mail.example.com/', 'https://accounts.example.com/login');
      expect(engine.onIcon(png(64)), isNull);
    });

    test('accepts the www. variant of the site host', () {
      final engine =
          loadedEngine('https://example.com/', 'https://www.example.com/home');
      expect(engine.onIcon(png(64))?.edge, 64);
    });

    test('drops icons of non-web documents', () {
      expect(loadedEngine('https://example.com/', 'about:blank').onIcon(png(64)),
          isNull);
      expect(loadedEngine('file:///x.html', 'file:///x.html').onIcon(png(64)),
          isNull);
    });

    test('drops every icon after the page edits its icon links', () {
      final engine = loadedEngine('https://example.com/', 'https://example.com/');
      expect(engine.onIcon(png(32))?.edge, 32);
      engine.onIconLinksChanged();
      expect(engine.onIcon(png(192)), isNull);
    });

    test('a new document starts from scratch', () {
      final engine = loadedEngine('https://example.com/', 'https://example.com/');
      engine.onIconLinksChanged();
      expect(engine.onIcon(png(64)), isNull);
      engine
        ..onLoadStarted('https://example.com/b')
        ..onLoadFinished('https://example.com/b');
      expect(engine.onIcon(png(32))?.edge, 32);
    });

    test('leaving the site stops accepting until it comes back', () {
      final engine = loadedEngine('https://example.com/', 'https://example.com/');
      engine
        ..onLoadStarted('https://other.test/')
        ..onLoadFinished('https://other.test/');
      expect(engine.onIcon(png(64)), isNull);
      engine
        ..onLoadStarted('https://example.com/')
        ..onLoadFinished('https://example.com/');
      expect(engine.onIcon(png(64))?.edge, 64);
    });
  });

  group('SiteIconEngine document reports (ICON-009)', () {
    const site = 'https://example.com/';

    test('an icon that lands between the load event and onLoadStop is taken',
        () {
      final engine = SiteIconEngine(site)
        ..onLoadStarted(site)
        ..onDocumentStarted(site, 't1');
      expect(engine.onIcon(png(64)), isNull,
          reason: 'before the load event the icon is the replaced document\'s');
      engine.onDocumentLoaded(site, 't1');
      expect(engine.onIcon(png(64))?.edge, 64);
      engine.onLoadFinished(site);
      expect(engine.onIcon(png(128))?.edge, 128);
    });

    test('reports that beat WebView\'s load start still count', () {
      final both = SiteIconEngine(site)
        ..onDocumentStarted(site, 't1')
        ..onDocumentLoaded(site, 't1')
        ..onLoadStarted(site);
      expect(both.onIcon(png(64))?.edge, 64);

      final startOnly = SiteIconEngine(site)
        ..onDocumentStarted(site, 't1')
        ..onLoadStarted(site);
      expect(startOnly.onIcon(png(64)), isNull);
      startOnly.onDocumentLoaded(site, 't1');
      expect(startOnly.onIcon(png(64))?.edge, 64);
    });

    test('a replaced document reporting its load late is ignored', () {
      final engine = SiteIconEngine(site)
        ..onLoadStarted(site)
        ..onDocumentStarted(site, 't1')
        ..onLoadStarted('${site}next')
        ..onDocumentStarted('${site}next', 't2')
        ..onDocumentLoaded(site, 't1');
      expect(engine.onIcon(png(64)), isNull);
      engine.onDocumentLoaded('${site}next', 't2');
      expect(engine.onIcon(png(64))?.edge, 64);
    });

    test('a new load drops the reported document even before it reports', () {
      final engine = SiteIconEngine(site)
        ..onLoadStarted(site)
        ..onDocumentStarted(site, 't1')
        ..onDocumentLoaded(site, 't1')
        ..onLoadFinished(site)
        ..onLoadStarted('${site}next');
      expect(engine.onIcon(png(64)), isNull,
          reason: 'a late icon from the previous document');
      engine.onDocumentLoaded(site, 't1');
      expect(engine.onIcon(png(64)), isNull);
    });

    test('the replaced document\'s onLoadStop does not open the next one', () {
      final engine = SiteIconEngine(site)
        ..onLoadStarted(site)
        ..onDocumentStarted(site, 't1')
        ..onDocumentStarted('${site}next', 't2')
        ..onLoadFinished(site);
      expect(engine.onIcon(png(64)), isNull);
      engine
        ..onLoadStarted('${site}next')
        ..onDocumentLoaded('${site}next', 't2');
      expect(engine.onIcon(png(64))?.edge, 64);
    });

    test('a document that never reports falls back to onLoadStop', () {
      final engine = SiteIconEngine(site)
        ..onLoadStarted(site)
        ..onDocumentStarted(site, 't1')
        ..onDocumentLoaded(site, 't1')
        ..onLoadFinished(site)
        ..onLoadStarted('${site}image.png');
      expect(engine.onIcon(png(64)), isNull);
      engine.onLoadFinished('${site}image.png');
      expect(engine.onIcon(png(64))?.edge, 64);
    });

    test('the load report decides the host, and pushState does not unpair it',
        () {
      final away = SiteIconEngine(site)
        ..onLoadStarted('https://accounts.example.com/login')
        ..onDocumentStarted('https://accounts.example.com/login', 't1')
        ..onDocumentLoaded('https://accounts.example.com/login', 't1');
      expect(away.onIcon(png(64)), isNull);

      final routed = SiteIconEngine(site)
        ..onDocumentStarted(site, 't1')
        ..onDocumentLoaded('${site}app/inbox', 't1')
        ..onLoadStarted(site);
      expect(routed.onIcon(png(64))?.edge, 64);
    });

    test('an icon-link edit still ends the document early', () {
      final engine = SiteIconEngine(site)
        ..onLoadStarted(site)
        ..onDocumentStarted(site, 't1')
        ..onDocumentLoaded(site, 't1');
      expect(engine.onIcon(png(32))?.edge, 32);
      engine.onIconLinksChanged();
      expect(engine.onIcon(png(192)), isNull);
      engine.onLoadFinished(site);
      expect(engine.onIcon(png(192)), isNull);
    });
  });

  group('shouldReplaceSiteIcon', () {
    test('an empty slot takes any icon', () {
      expect(
          shouldReplaceSiteIcon(
              storedEdge: null, storedThisLaunch: false, newEdge: 32),
          isTrue);
    });

    test('a larger icon always replaces', () {
      expect(
          shouldReplaceSiteIcon(
              storedEdge: 32, storedThisLaunch: true, newEdge: 64),
          isTrue);
    });

    test('an equal icon replaces only an entry from a previous launch', () {
      expect(
          shouldReplaceSiteIcon(
              storedEdge: 64, storedThisLaunch: false, newEdge: 64),
          isTrue);
      expect(
          shouldReplaceSiteIcon(
              storedEdge: 64, storedThisLaunch: true, newEdge: 64),
          isFalse);
    });

    test('a smaller icon never replaces', () {
      expect(
          shouldReplaceSiteIcon(
              storedEdge: 192, storedThisLaunch: false, newEdge: 32),
          isFalse);
    });
  });

  group('SiteIconStore', () {
    SiteIcon icon(int size) => SiteIcon(png(size), size, size);
    const site = 'https://example.com/';

    test('persists only when asked, and reloads what it persisted', () async {
      final files = MemoryFileStore();
      final store = SiteIconStore(store: files);
      await store.initialize();
      await store.offer(site, icon(64), persist: true);
      await store.offer('https://incognito.test/', icon(64), persist: false);
      expect((await files.list()).length, 1);

      final reloaded = SiteIconStore(store: files);
      await reloaded.initialize();
      expect(pngDimensions(reloaded.get(site)!), (width: 64, height: 64));
      expect(reloaded.get('https://incognito.test/'), isNull);
    });

    test('an entry from disk yields to an equal icon once per launch', () async {
      final files = MemoryFileStore();
      final first = SiteIconStore(store: files);
      await first.initialize();
      final original = icon(64);
      await first.offer(site, original, persist: true);

      final second = SiteIconStore(store: files);
      await second.initialize();
      final healed = icon(64);
      await second.offer(site, healed, persist: true);
      expect(identical(second.get(site), healed.png), isTrue);
      await second.offer(site, icon(64), persist: true);
      expect(identical(second.get(site), healed.png), isTrue);
    });

    test('remove and removeOrphans clear memory and disk', () async {
      final files = MemoryFileStore();
      final store = SiteIconStore(store: files);
      await store.initialize();
      await store.offer(site, icon(64), persist: true);
      await store.offer('https://gone.test/', icon(64), persist: true);

      await store.removeOrphans({site});
      expect(store.get('https://gone.test/'), isNull);
      expect((await files.list()).length, 1);

      final changes = <String?>[];
      final sub = store.changes.listen(changes.add);
      await store.remove(site);
      await Future<void>.delayed(Duration.zero);
      expect(store.get(site), isNull);
      expect(await files.list(), isEmpty);
      expect(changes, [site]);
      await sub.cancel();
    });

    test('turning a site incognito deletes its file', () async {
      final files = MemoryFileStore();
      final store = SiteIconStore(store: files);
      await store.initialize();
      await store.offer(site, icon(64), persist: true);
      await store.offer(site, icon(128), persist: false);
      expect(await files.list(), isEmpty);
      expect(pngDimensions(store.get(site)!)?.width, 128);
    });
  });
}
