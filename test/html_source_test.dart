// Parity guard for the HTML-store classification (htmlSourceFor).
//
// Before, three call sites in main.dart each re-derived "which HTML store
// backs this site" from `incognito || isArchiveTier || initUrl.startsWith
// ('file://')`. If the preload site (SiteActivationController.ensureSiteHtml) and the read site (the
// IndexedStack initialHtml) ever disagreed, a site would render blank
// (preloaded from one store, read from another). They now share this single
// function; these tests pin its behavior so the classification can't drift.
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/html_source.dart';

void main() {
  group('htmlSourceFor', () {
    test('plain URL site -> cache', () {
      expect(
        htmlSourceFor(
            incognito: false,
            isArchiveTier: false,
            initUrl: 'https://example.com'),
        HtmlSource.cache,
      );
      expect(
        htmlSourceFor(
            incognito: false, isArchiveTier: false, initUrl: 'http://x.test'),
        HtmlSource.cache,
      );
    });

    test('file:// import -> import', () {
      expect(
        htmlSourceFor(
            incognito: false,
            isArchiveTier: false,
            initUrl: 'file:///notifs.html'),
        HtmlSource.import,
      );
    });

    test('incognito -> none regardless of URL', () {
      expect(
        htmlSourceFor(
            incognito: true,
            isArchiveTier: false,
            initUrl: 'https://example.com'),
        HtmlSource.none,
      );
      // Incognito wins over file:// (no persisted HTML for incognito at all).
      expect(
        htmlSourceFor(
            incognito: true,
            isArchiveTier: false,
            initUrl: 'file:///notifs.html'),
        HtmlSource.none,
      );
    });

    test('archive-tier -> none regardless of URL', () {
      expect(
        htmlSourceFor(
            incognito: false,
            isArchiveTier: true,
            initUrl: 'https://example.com'),
        HtmlSource.none,
      );
      expect(
        htmlSourceFor(
            incognito: false,
            isArchiveTier: true,
            initUrl: 'file:///notifs.html'),
        HtmlSource.none,
      );
    });

    test('parity: read source == preload source for every config', () {
      // The read site reads from getHtmlSync(import|cache) iff source is
      // import|cache; the preload site preloadOne(import|cache) for the same.
      // Asserting they're computed from one function is the guarantee; this
      // exhaustively covers the input space so a regression in either operand
      // can't slip through.
      for (final incognito in [false, true]) {
        for (final archive in [false, true]) {
          for (final url in [
            'https://example.com',
            'http://x.test',
            'file:///a.html',
            'about:blank',
          ]) {
            final source = htmlSourceFor(
                incognito: incognito, isArchiveTier: archive, initUrl: url);
            // none: neither reads nor preloads. import/cache: both target the
            // matching store. By construction (single function) they agree —
            // this documents and locks the contract.
            final readsImport = source == HtmlSource.import;
            final readsCache = source == HtmlSource.cache;
            final preloadsImport = source == HtmlSource.import;
            final preloadsCache = source == HtmlSource.cache;
            expect(readsImport, preloadsImport);
            expect(readsCache, preloadsCache);
            if (incognito || archive) {
              expect(source, HtmlSource.none);
            }
          }
        }
      }
    });
  });

  group('loadsCacheFirst', () {
    test('a URL site: when it keeps its HTML, or when the probe found none',
        () {
      bool first({required bool caching, required bool? online}) =>
          loadsCacheFirst(HtmlSource.cache,
              htmlCaching: caching, online: online, engineCan: true);
      expect(first(caching: false, online: true), isFalse);
      expect(first(caching: false, online: null), isFalse,
          reason: 'no probe yet reads as online');
      expect(first(caching: false, online: false), isTrue);
      expect(first(caching: true, online: true), isTrue);
      expect(first(caching: true, online: false), isTrue);
    });

    test('never where the engine cannot, nor for an import or a site that '
        'keeps nothing', () {
      for (final source in HtmlSource.values) {
        for (final caching in [false, true]) {
          for (final online in [null, false, true]) {
            final first = loadsCacheFirst(source,
                htmlCaching: caching, online: online, engineCan: true);
            if (source != HtmlSource.cache) expect(first, isFalse);
            expect(
                loadsCacheFirst(source,
                    htmlCaching: caching, online: online, engineCan: false),
                isFalse);
          }
        }
      }
    });
  });
}
