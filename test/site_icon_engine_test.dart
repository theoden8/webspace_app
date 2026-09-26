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

    test('takes the first page\'s own icon before onLoadStop', () {
      final engine = SiteIconEngine('https://example.com/')
        ..onLoadStarted('https://example.com/');
      expect(engine.onIcon(png(64))?.edge, 64,
          reason: 'WebView can report the icon before onPageFinished');
      engine.onLoadFinished('https://example.com/');
      expect(engine.onIcon(png(128))?.edge, 128);
    });

    test('takes a mid-load icon after a page of the site', () {
      final engine = loadedEngine('https://example.com/', 'https://example.com/')
        ..onLoadStarted('https://example.com/next');
      expect(engine.onIcon(png(64))?.edge, 64,
          reason: 'either page it came from is the site\'s');
    });

    test('drops a mid-load icon after another host\'s page', () {
      final engine = loadedEngine(
          'https://mail.example.com/', 'https://accounts.example.com/login')
        ..onLoadStarted('https://mail.example.com/');
      expect(engine.onIcon(png(64)), isNull,
          reason: 'it may be the login page\'s icon, still in flight');
      engine.onLoadFinished('https://mail.example.com/');
      expect(engine.onIcon(png(64))?.edge, 64);
    });

    test('drops a mid-load icon after the page swapped in a badge', () {
      final engine = loadedEngine('https://example.com/', 'https://example.com/')
        ..onIconLinksChanged()
        ..onLoadStarted('https://example.com/next');
      expect(engine.onIcon(png(64)), isNull);
      engine.onLoadFinished('https://example.com/next');
      expect(engine.onIcon(png(64))?.edge, 64);
    });

    test('a page left before it finished still counts as replaced', () {
      final engine = SiteIconEngine('https://example.com/')
        ..onLoadStarted('https://other.test/')
        ..onLoadStarted('https://example.com/');
      expect(engine.onIcon(png(64)), isNull);
    });

    test('a non-web page leaves the decision to the page before it', () {
      final afterSite =
          loadedEngine('https://example.com/', 'https://example.com/')
            ..onLoadStarted('about:blank')
            ..onLoadFinished('about:blank')
            ..onLoadStarted('https://example.com/next');
      expect(afterSite.onIcon(png(64))?.edge, 64);

      final afterOther =
          loadedEngine('https://example.com/', 'https://other.test/')
            ..onLoadStarted('about:blank')
            ..onLoadFinished('about:blank')
            ..onLoadStarted('https://example.com/');
      expect(afterOther.onIcon(png(64)), isNull);
    });

    test('a loading page on another host takes nothing', () {
      final engine = loadedEngine('https://example.com/', 'https://example.com/')
        ..onLoadStarted('https://other.test/');
      expect(engine.onIcon(png(64)), isNull);
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
