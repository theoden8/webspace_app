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

  group('SiteIconEngine link fetches (ICON-013)', () {
    test('one claim per document', () {
      final engine = loadedEngine('https://example.com/', 'https://example.com/');
      final first = engine.claimIconLinks('https://example.com/');
      expect(first, isNotNull);
      expect(engine.claimIconLinks('https://example.com/'), isNull);
      engine
        ..onLoadStarted('https://example.com/b')
        ..onLoadFinished('https://example.com/b');
      final second = engine.claimIconLinks('https://example.com/b');
      expect(second, isNotNull);
      expect(second, isNot(first));
    });

    test('no claim while loading or off the site', () {
      final engine = SiteIconEngine('https://example.com/')
        ..onLoadStarted('https://example.com/');
      expect(engine.claimIconLinks('https://example.com/'), isNull);
      engine.onLoadFinished('https://example.com/');
      expect(engine.claimIconLinks('https://other.test/'), isNull);
      expect(engine.claimIconLinks('https://www.example.com/'), isNotNull);
    });

    test('drops a fetch that outlives its document', () {
      final engine = loadedEngine('https://example.com/', 'https://example.com/');
      final document = engine.claimIconLinks('https://example.com/')!;
      engine.onLoadStarted('https://example.com/b');
      expect(engine.onLinkedIcon(document, png(64)), isNull);
      engine.onLoadFinished('https://example.com/b');
      expect(engine.onLinkedIcon(document, png(64)), isNull);
    });

    test('keeps load-time links after the page edits them', () {
      final engine = loadedEngine('https://example.com/', 'https://example.com/');
      final document = engine.claimIconLinks('https://example.com/')!;
      engine.onIconLinksChanged();
      expect(engine.onLinkedIcon(document, png(64))?.edge, 64);
    });

    test('same floor and largest-per-document rule as reported icons', () {
      final engine = loadedEngine('https://example.com/', 'https://example.com/');
      final document = engine.claimIconLinks('https://example.com/')!;
      expect(engine.onLinkedIcon(document, png(16)), isNull);
      expect(engine.onLinkedIcon(document, png(64))?.edge, 64);
      expect(engine.onLinkedIcon(document, png(48)), isNull);
    });
  });

  group('SiteIconLink.listFrom', () {
    test('keeps well-formed entries and skips the rest', () {
      final links = SiteIconLink.listFrom([
        {'href': 'https://example.com/a.png', 'sizes': '32x32', 'type': 1},
        {'href': 7},
        'https://example.com/b.png',
        {'href': ''},
        {'href': 'https://example.com/c.png'},
      ]);
      expect(links.map((l) => l.href),
          ['https://example.com/a.png', 'https://example.com/c.png']);
      expect(links.first.sizes, '32x32');
      expect(links.first.type, '');
      expect(SiteIconLink.listFrom('nope'), isEmpty);
    });
  });

  group('siteIconCandidates (ICON-013)', () {
    SiteIconLink link(String href, {String sizes = '', String type = ''}) =>
        SiteIconLink(href: href, sizes: sizes, type: type);

    test('/favicon.ico when the document declares no icon', () {
      expect(siteIconCandidates(const [], 'https://example.com/a?b#c'),
          ['https://example.com/favicon.ico']);
      expect(siteIconCandidates(const [], 'http://127.0.0.1:8080/x'),
          ['http://127.0.0.1:8080/favicon.ico']);
    });

    test('nothing for a non-web document', () {
      expect(siteIconCandidates(const [], 'about:blank'), isEmpty);
      expect(
          siteIconCandidates(
              [link('https://example.com/a.png')], 'file:///index.html'),
          isEmpty);
    });

    test('declared sizes first, largest first, then undeclared in order', () {
      final got = siteIconCandidates([
        link('https://example.com/favicon.ico'),
        link('https://example.com/32.png', sizes: '32x32'),
        link('https://example.com/other.ico'),
        link('https://example.com/192.png', sizes: '192x192'),
        link('https://example.com/multi.ico', sizes: '16x16 48x48'),
      ], 'https://example.com/');
      expect(got, [
        'https://example.com/192.png',
        'https://example.com/multi.ico',
        'https://example.com/32.png',
        'https://example.com/favicon.ico',
        'https://example.com/other.ico',
      ]);
    });

    test('skips SVG by type, extension and data URL', () {
      final got = siteIconCandidates([
        link('https://example.com/a', type: 'image/svg+xml'),
        link('https://example.com/b.SVG'),
        link('data:image/svg+xml;base64,PHN2Zy8+'),
        link('https://example.com/c.png'),
      ], 'https://example.com/');
      expect(got, ['https://example.com/c.png']);
    });

    test('skips links whose declared sizes are all under the floor', () {
      final got = siteIconCandidates([
        link('https://example.com/16.png', sizes: '16x16'),
        link('https://example.com/wide.png', sizes: '64x16'),
        link('https://example.com/any.png', sizes: 'any'),
        link('https://example.com/bogus.png', sizes: 'large'),
      ], 'https://example.com/');
      expect(got,
          ['https://example.com/any.png', 'https://example.com/bogus.png']);
    });

    test('upgrades http links on an https document only', () {
      final links = [link('http://cdn.example.com/a.png')];
      expect(siteIconCandidates(links, 'https://example.com/'),
          ['https://cdn.example.com/a.png']);
      expect(siteIconCandidates(links, 'http://example.com/'),
          ['http://cdn.example.com/a.png']);
    });

    test('skips other schemes, oversized data URLs and duplicates', () {
      final small = 'data:image/png;base64,${'A' * 16}';
      final huge = 'data:image/png;base64,${'A' * kMaxDataIconLength}';
      final got = siteIconCandidates([
        link('blob:https://example.com/1'),
        link('javascript:alert(1)'),
        link('data:text/html,x'),
        link(huge),
        link(small),
        link('https://example.com/a.png'),
        link('https://example.com/a.png'),
      ], 'https://example.com/');
      expect(got, [small, 'https://example.com/a.png']);
    });

    test('caps the list', () {
      final got = siteIconCandidates([
        for (var i = 0; i < 20; i++) link('https://example.com/$i.png'),
      ], 'https://example.com/');
      expect(got, hasLength(kMaxSiteIconCandidates));
      expect(got.first, 'https://example.com/0.png');
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
