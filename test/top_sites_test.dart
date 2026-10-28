import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/screens/add_site.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/top_sites_engine.dart';
import 'package:webspace/services/top_sites_service.dart';
import 'package:webspace/settings/app_prefs.dart';

import 'helpers/fake_outbound.dart';
import 'helpers/fake_path_provider.dart';
import 'helpers/localized.dart';

// Rows as CrUX's global list has them (2026-09): rank groups in order, an
// origin per row, a site under several hostnames.
const _crux = 'origin,rank\n'
    'https://www.youtube.com,1000\n'
    'https://m.youtube.com,1000\n'
    'https://music.youtube.com,1000\n'
    'https://www.youjizz.com,1000\n'
    'https://www.reddit.com,1000\n'
    'https://old.reddit.com,1000\n'
    'https://github.com,1000\n'
    'https://www.google.com,1000\n'
    'https://yandex.ru,1000\n'
    'https://www.baidu.com,1000\n'
    'https://www.163.com.cn,1000\n'
    'https://www.redtube.com,1000\n'
    'https://hot.noodlemagazine.com,1000\n'
    'https://www.onliner.by,1000\n'
    'https://www.myvidster.com,5000\n'
    'https://www.bet365.com,1000\n'
    'https://ad.clickadu.net,1000\n'
    'https://www.cheap.icu,1000\n'
    'https://kept.icu,1000\n'
    'http://insecure.example,1000\n'
    'https://ported.example:8443,1000\n'
    'https://www.gitlab.com,5000\n'
    'https://xn--80aswg.xn--p1ai,5000\n'
    'https://kcna.kp,5000\n'
    'https://bookmark.xxx,5000\n'
    'https://www.redfin.com,10000\n'
    'https://www.github.community,10000\n'
    'https://www.justice.gov,50000\n';

void main() {
  group('TopSites.fromCrux', () {
    final sites = TopSites.fromCrux(_crux);

    test('keeps rank groups down to kTopSitesRank, best first (SUGGEST-008)',
        () {
      expect(sites.match('ju'), isNot(contains('justice.gov')),
          reason: 'its row is in 50000');
      expect(sites.match('gi'), ['github.com', 'gitlab.com', 'github.community']);
    });

    test('one host per site: www. and m. merge into it (SUGGEST-007)', () {
      expect(sites.match('yo'), ['youtube.com']);
      expect(sites.match('mu'), ['music.youtube.com']);
    });

    test('within a group the site named under more hostnames comes first '
        '(SUGGEST-007)', () {
      expect(sites.match('re').first, 'reddit.com');
    });

    test('offers https on its default port only (SUGGEST-007)', () {
      expect(sites.match('in'), isEmpty);
      expect(sites.match('po'), isEmpty);
    });

    test('filters the listed top-level domains (SUGGEST-009)', () {
      expect(sites.match('ya'), isEmpty);
      expect(sites.match('16'), isEmpty);
      expect(sites.match('xn'), isEmpty);
      expect(sites.match('kc'), isEmpty);
      expect(sites.match('bo'), isEmpty);
      expect(sites.match('on'), isEmpty);
      expect(sites.match('ba'), ['baidu.com'],
          reason: 'the filter reads the domain, not the site');
    });

    test('filters a host carrying a filtered word (SUGGEST-009)', () {
      expect(sites.match('you'), ['youtube.com']);
      expect(sites.match('red'), ['reddit.com', 'redfin.com']);
    });

    test('the filter holds on every read, not only at download (SUGGEST-009)',
        () {
      final stored = cruxHead(_crux);
      expect(stored, contains('https://yandex.ru,1000\n'),
          reason: 'the store keeps rows as CrUX wrote them');
      expect(TopSites.fromCrux(stored).match('ya'), isEmpty);
    });

    test('rows that do not parse are skipped', () {
      final odd = TopSites.fromCrux('origin,rank\nnot a row\n'
          'https://a.example,many\nhttps://ab.example,1000\n');
      expect(odd.length, 1);
      expect(odd.match('ab'), ['ab.example']);
    });
  });

  group('cruxHead', () {
    test('drops rows under a domain a filter list names (SUGGEST-009)', () {
      final head = cruxHead(_crux, filters: [
        (block: '# a domain list\nnoodlemagazine.com\n', allow: ''),
        (block: '# a hosts file\n0.0.0.0 myvidster.com # inline\n', allow: ''),
      ]);
      expect(head, isNot(contains('noodlemagazine')));
      expect(head, isNot(contains('myvidster')));
      expect(head, contains('https://github.com,1000\n'));
      expect(cruxHead(_crux, filters: [(block: 'github.com', allow: '')]),
          contains('https://www.github.community,10000\n'),
          reason: 'a domain filters its subdomains, not its suffix-mates');
    });

    test('a filter\'s allow list exempts rows from its own list only '
        '(SUGGEST-009)', () {
      const tlds = (block: 'icu', allow: 'kept.icu');
      final head = cruxHead(_crux, filters: [tlds]);
      expect(head, isNot(contains('cheap.icu')));
      expect(head, contains('https://kept.icu,1000\n'));
      expect(
          cruxHead(_crux, filters: [tlds, (block: 'kept.icu', allow: '')]),
          isNot(contains('kept.icu')),
          reason: 'another filter still drops what this one allows');
    });

    test('a download cut mid-line loses only that line (SUGGEST-008)', () {
      const cut = 'origin,rank\nhttps://github.com,1000\nhttps://gitl';
      expect(cruxHead(cut), 'https://github.com,1000\n');
    });

    test('keeps no row past kTopSitesRank', () {
      expect(cruxHead(_crux), isNot(contains('justice.gov')));
      expect(cruxHead(_crux), contains('https://www.github.community,10000\n'));
    });
  });

  group('TopSites.match (SUGGEST-007)', () {
    final sites = TopSites.fromCrux(_crux);

    test('reads the host past a scheme and www.', () {
      expect(sites.match('https://gi'), sites.match('gi'));
      expect(sites.match('www.gi'), sites.match('gi'));
      expect(sites.match(' GI '), sites.match('gi'));
    });

    test('offers nothing for fewer than kTopSitesMinTyped characters', () {
      expect(kTopSitesMinTyped, 2);
      expect(sites.match('g'), isEmpty);
      expect(sites.match('www.g'), isEmpty);
    });

    test('a host typed out whole is not offered back', () {
      expect(sites.match('github.com'), ['github.community']);
      expect(sites.match('gitlab.com'), isEmpty);
    });

    test('a path, a port or a space is no host prefix', () {
      expect(sites.match('github.com/x'), isEmpty);
      expect(sites.match('gi:80'), isEmpty);
      expect(sites.match('gi hub'), isEmpty);
    });

    test('at most kTopSitesShown', () {
      final many = TopSites.fromCrux([
        'origin,rank',
        for (var i = 0; i < 20; i++) 'https://site$i.example,1000',
        '',
      ].join('\n'));
      expect(many.match('si'), hasLength(kTopSitesShown));
    });
  });

  group('pinned address (SUGGEST-010)', () {
    final sites = TopSites.fromCrux(_crux);
    final pin = kTopSitesPinned.first;
    final host = pin.address.split('/').first;
    final word = pin.words.first;
    String start(String text) => text.substring(0, kTopSitesMinTyped);

    test('is offered first for what begins its address or its word', () {
      expect(sites.match(start(host)), [pin.address],
          reason: 'its host ranks below the kept groups');
      expect(sites.match('https://www.$host'), [pin.address]);
      expect(sites.match('$host/'), [pin.address]);
      expect(sites.match(start(word)), [pin.address]);
      expect(sites.match(word.toUpperCase()), [pin.address]);
      expect(sites.match('gi').contains(pin.address), isFalse);
    });

    test('is not offered once a site at its address is added', () {
      expect(siteAddress('https://www.${pin.address}/'), pin.address);
      expect(siteAddress('https://m.${pin.address}'), pin.address);
      expect(sites.match(start(host), added: {pin.address}), isEmpty);
      expect(sites.match(start(host), added: {siteAddress('https://$host/')}),
          [pin.address], reason: 'the host\'s home is another address');
    });

    test('a host already added is not offered either', () {
      expect(sites.match('gi', added: {siteAddress('https://www.github.com')}),
          ['gitlab.com', 'github.community']);
    });

    test('nothing is offered until the list is downloaded', () {
      expect(TopSites.empty.match(start(host)), isEmpty);
    });

    test('counts toward kTopSitesShown ahead of the ranked hosts', () {
      final many = TopSites.fromCrux([
        'origin,rank',
        for (var i = 0; i < 20; i++) 'https://${start(host)}$i.example,1000',
        '',
      ].join('\n'));
      final found = many.match(start(host));
      expect(found, hasLength(kTopSitesShown));
      expect(found.first, pin.address);
    });
  });

  group('TopSitesService (SUGGEST-008)', () {
    late Directory docs;
    late FakeOutbound outbound;

    // Each filter list as its sources serve it, long enough to read as one,
    // by file name.
    String list(String named, {required String Function(int) filler}) =>
        [named, for (var i = 0; i < 1000; i++) filler(i)].join('\n');
    final listBodies = {
      'nsfw-onlydomains.txt':
          list('noodlemagazine.com', filler: (i) => 'filler$i.example'),
      'hosts': list('0.0.0.0 myvidster.com',
          filler: (i) => '0.0.0.0 other$i.example'),
      'gambling.mini-onlydomains.txt':
          list('bet365.com', filler: (i) => 'odds$i.example'),
      'popupads-onlydomains.txt':
          list('clickadu.net', filler: (i) => 'pop$i.example'),
      'spam-tlds-onlydomains.txt':
          ['icu', for (var i = 0; i < 150; i++) 'tld$i'].join('\n'),
      'spam-tlds-allow-onlydomains.txt':
          list('kept.icu', filler: (i) => 'fine$i.icu'),
    };

    http.Response Function(http.Request) serving({
      http.Response? crux,
      Map<String, http.Response> lists = const {},
    }) =>
        (request) {
          if (request.url.toString() == kTopSitesUrl) {
            return crux ??
                http.Response.bytes(gzip.encode(_crux.codeUnits), 206);
          }
          final name = request.url.pathSegments.last;
          return lists[name] ?? http.Response(listBodies[name]!, 200);
        };

    Iterable<String> listRequests() => outbound.requested
        .map((u) => u.toString())
        .where((u) => u != kTopSitesUrl);

    Future<List<String>> stored() async => [
          await for (final f in docs.list(recursive: true))
            if (f is File) f.uri.pathSegments.last,
        ];

    setUp(() async {
      docs = await Directory.systemTemp.createTemp('webspace_top_sites_');
      useFakePathProvider(docs);
      SharedPreferences.setMockInitialValues({});
      TopSitesService.resetForTest();
      outbound = FakeOutbound(responder: serving());
      outboundHttp = outbound;
    });

    tearDown(() async {
      resetOutboundHttp();
      TopSitesService.resetForTest();
      await AppPref.topSitesKeepFilters.set(false);
      await docs.delete(recursive: true);
    });

    test('nothing is offered or fetched until the user downloads', () async {
      await TopSitesService.instance.load();
      expect(TopSitesService.instance.isLoaded, isFalse);
      expect(TopSitesService.instance.match('gi', added: const {}), isEmpty);
      expect(outbound.requested, isEmpty);
    });

    test('a download asks for the list\'s start only and is kept until '
        'cleared', () async {
      expect(await TopSitesService.instance.download(), isTrue);
      final request = outbound.requests
          .singleWhere((r) => r.url.toString() == kTopSitesUrl);
      expect(request.headers['Range'], startsWith('bytes=0-'));
      expect(TopSitesService.instance.match('gi', added: const {}),
          ['github.com', 'gitlab.com', 'github.community']);
      expect(TopSitesService.instance.lastUpdated, isNotNull);

      TopSitesService.resetForTest();
      await TopSitesService.instance.load();
      expect(TopSitesService.instance.siteCount, 11);
      expect(TopSitesService.instance.lastUpdated, isNotNull);

      await TopSitesService.instance.clear();
      expect(TopSitesService.instance.isLoaded, isFalse);
      expect(await stored(), isEmpty);
      TopSitesService.resetForTest();
      await TopSitesService.instance.load();
      expect(TopSitesService.instance.isLoaded, isFalse);
    });

    test('a download drops its rows through every filter list '
        '(SUGGEST-009)', () async {
      final unfiltered = TopSites.fromCrux(_crux);
      expect(unfiltered.match('ho'), ['hot.noodlemagazine.com'],
          reason: 'no keyword names it');
      for (final prefix in ['my', 'be', 'ad', 'ch', 'ke']) {
        expect(unfiltered.match(prefix), isNotEmpty, reason: prefix);
      }
      expect(await TopSitesService.instance.download(), isTrue);
      expect(listRequests(), hasLength(TopSitesFilter.values.length + 1),
          reason: 'one fetch per list, the TLD list\'s allow list too');
      for (final prefix in ['ho', 'my', 'be', 'ad', 'ch']) {
        expect(TopSitesService.instance.match(prefix, added: const {}),
            isEmpty, reason: prefix);
      }
      expect(TopSitesService.instance.match('ke', added: const {}),
          ['kept.icu'], reason: 'the TLD list\'s allow list names it');
      TopSitesService.resetForTest();
      await TopSitesService.instance.load();
      expect(TopSitesService.instance.match('ho', added: const {}), isEmpty,
          reason: 'the stored rows are the filtered ones');
    });

    test('without any one filter list a download fails and fetches no rows '
        '(SUGGEST-009)', () async {
      expect(await TopSitesService.instance.download(), isTrue);
      for (final name in listBodies.keys) {
        for (final bad in [
          http.Response('nope', 503),
          http.Response('<html>', 200),
        ]) {
          outbound.requests.clear();
          outbound.responder = serving(lists: {name: bad});
          expect(await TopSitesService.instance.download(), isFalse,
              reason: name);
          expect(outbound.requested.map((u) => u.toString()),
              isNot(contains(kTopSitesUrl)), reason: name);
        }
      }
      expect(TopSitesService.instance.siteCount, 11);
    });

    test('a download cut mid-stream still reads its whole rows', () async {
      final gz = gzip.encode(_crux.codeUnits);
      outbound.responder = serving(
          crux: http.Response.bytes(gz.sublist(0, gz.length - 20), 206));
      expect(await TopSitesService.instance.download(), isTrue);
      expect(TopSitesService.instance.match('yo', added: const {}),
          ['youtube.com']);
    });

    test('a failed download keeps the list it had', () async {
      expect(await TopSitesService.instance.download(), isTrue);
      outbound.responder = serving(crux: http.Response('nope', 503));
      expect(await TopSitesService.instance.download(), isFalse);
      outbound.responder = serving(crux: http.Response('not gzip', 206));
      expect(await TopSitesService.instance.download(), isFalse);
      outbound.responder = serving(
          crux: http.Response.bytes(gzip.encode('origin,rank\n'.codeUnits), 206));
      expect(await TopSitesService.instance.download(), isFalse);
      expect(TopSitesService.instance.siteCount, 11);
    });

    test('a proxy that cannot be honoured fetches nothing', () async {
      outbound.block = true;
      expect(await TopSitesService.instance.download(), isFalse);
      expect(outbound.requested, isEmpty);
    });

    group('the add-site screen\'s offer (SUGGEST-012)', () {
      tearDown(() => AppPref.topSitesOffer.set(true));

      Future<AppLocalizations> open(WidgetTester tester) async {
        await tester.runAsync(TopSitesService.instance.load);
        await pumpLocalized(
          tester,
          home: AddSiteScreen(
            suggestions: const [],
            onSuggestionsChanged: (_) {},
            existingUrls: const [],
          ),
        );
        // The read finished in the real zone, so the screen hears of it
        // there: let it run, then build the frame it asks for.
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        return AppLocalizations.of(tester.element(find.byType(AddSiteScreen)));
      }

      testWidgets('a new user is offered the list and downloads it there',
          (tester) async {
        final loc = await open(tester);
        expect(find.text(loc.topSitesOffer), findsOneWidget);
        await tester.runAsync(() async {
          await tester.tap(find.text(loc.appSettingsDownload));
          for (var i = 0;
              i < 200 && !TopSitesService.instance.isLoaded;
              i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        await tester.pump();
        expect(TopSitesService.instance.isLoaded, isTrue);
        expect(find.text(loc.topSitesOffer), findsNothing);
        await tester.enterText(find.byType(TextField).first, 'gi');
        await tester.pump();
        expect(find.text('gitlab.com'), findsOneWidget);
        await tester.pump(const Duration(seconds: 5));
      });

      testWidgets('dismissed, it goes for good and says where the list is',
          (tester) async {
        final loc = await open(tester);
        await tester.tap(find.byTooltip(loc.commonClose));
        await tester.pump();
        expect(find.text(loc.topSitesOffer), findsNothing);
        expect(find.text(loc.topSitesOfferDismissed), findsOneWidget);
        expect(AppPref.topSitesOffer.value, isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(await open(tester), isNotNull);
        expect(find.text(loc.topSitesOffer), findsNothing);
        expect(outbound.requested, isEmpty);
        await tester.pump(const Duration(seconds: 5));
      });

      testWidgets('with a list there is no offer', (tester) async {
        TopSitesService.instance.setInMemory(_crux);
        final loc = await open(tester);
        expect(find.text(loc.topSitesOffer), findsNothing);
      });
    });

    group('keeping the filter lists (SUGGEST-011)', () {
      test('off, nothing but the rows is kept and each download fetches '
          'every list', () async {
        expect(await TopSitesService.instance.download(), isTrue);
        expect(await stored(), ['rows.csv']);
        outbound.requests.clear();
        expect(await TopSitesService.instance.download(), isTrue);
        expect(listRequests(), hasLength(TopSitesFilter.values.length + 1));
      });

      test('on, a download within the month fetches only the rows',
          () async {
        await AppPref.topSitesKeepFilters.set(true);
        expect(await TopSitesService.instance.download(), isTrue);
        expect(await stored(), hasLength(TopSitesFilter.values.length + 1));
        outbound.requests.clear();
        TopSitesService.resetForTest();
        expect(await TopSitesService.instance.download(), isTrue);
        expect(listRequests(), isEmpty);
        expect(outbound.requested.single.toString(), kTopSitesUrl);
        expect(TopSitesService.instance.match('ho', added: const {}), isEmpty,
            reason: 'the kept lists still filter');
        expect(TopSitesService.instance.match('ke', added: const {}),
            ['kept.icu']);
      });

      test('kept lists older than kTopSitesFiltersKept are fetched again',
          () async {
        await AppPref.topSitesKeepFilters.set(true);
        expect(await TopSitesService.instance.download(), isTrue);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
            'top_sites_filters_kept',
            DateTime.now()
                .subtract(kTopSitesFiltersKept + const Duration(days: 1))
                .toIso8601String());
        outbound.requests.clear();
        expect(await TopSitesService.instance.download(), isTrue);
        expect(listRequests(), hasLength(TopSitesFilter.values.length + 1));
      });

      test('turning it off drops the kept lists', () async {
        await AppPref.topSitesKeepFilters.set(true);
        expect(await TopSitesService.instance.download(), isTrue);
        await AppPref.topSitesKeepFilters.set(false);
        for (var i = 0; i < 100 && (await stored()).length > 1; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(await stored(), ['rows.csv']);
      });
    });
  });

  group('add-site field (SUGGEST-007)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      TopSitesService.resetForTest();
      TopSitesService.instance.setInMemory(_crux);
    });

    tearDown(TopSitesService.resetForTest);

    testWidgets('typing offers popular sites and a pick fills the address',
        (tester) async {
      await pumpLocalized(
        tester,
        home: AddSiteScreen(
          suggestions: const [],
          onSuggestionsChanged: (_) {},
          existingUrls: const ['https://www.github.com/'],
        ),
      );
      await tester.enterText(find.byType(TextField).first, 'gi');
      await tester.pump();
      expect(find.text('gitlab.com'), findsOneWidget);
      expect(find.text('github.com'), findsNothing,
          reason: 'a site already added is not offered (SUGGEST-010)');

      await tester.tap(find.text('gitlab.com'));
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.controller!.text, 'gitlab.com');
      expect(find.text('github.community'), findsNothing);
      // The address preview's lookup, which the fill starts, times out.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('one character offers nothing', (tester) async {
      await pumpLocalized(
        tester,
        home: AddSiteScreen(
          suggestions: const [],
          onSuggestionsChanged: (_) {},
          existingUrls: const [],
        ),
      );
      await tester.enterText(find.byType(TextField).first, 'g');
      await tester.pump();
      expect(find.text('github.com'), findsNothing);
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
