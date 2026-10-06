import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/site_search_list_engine.dart';
import 'package:webspace/services/site_search_list_service.dart';
import 'package:webspace/services/web_search_engine.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/web_view_model.dart';

// Entries as Kagi's bangs.json has them (2026-10-06), several per site where
// the list has several.
const _bangs = [
  {'t': 'imd', 'd': 'www.imdb.com', 'u': 'https://www.imdb.com/find?q={{{s}}}+&s=all'},
  {'t': 'imbd', 'd': 'www.imdb.com', 'u': 'https://www.imdb.com/find?q={{{s}}}&s=all'},
  {'t': 'imdb', 'd': 'www.imdb.com', 'u': 'https://www.imdb.com/find?s=all&q={{{s}}}'},
  {'t': 'prel', 'd': 'archive.org', 'u': 'https://archive.org/details/prelinger?and[]={{{s}}}'},
  {'t': 'archive', 'd': 'archive.org', 'u': 'https://archive.org/search.php?query={{{s}}}'},
  {'t': 'gh', 'd': 'github.com', 'ts': ['git', 'github'], 'u': 'https://github.com/search?q={{{s}}}'},
  {'t': 'ghus', 'd': 'github.com', 'u': 'https://github.com/{{{s}}}/'},
  {'t': 'ghuser', 'd': 'github.com', 'u': 'https://github.com/search?type=Users&q={{{s}}}'},
  {'t': 'a', 'd': 'www.amazon.com', 'ts': ['amazon', 'amz'], 'u': 'https://www.amazon.com/s?k={{{s}}}'},
  {'t': 'aa', 'd': 'www.amazon.com', 'u': 'https://www.amazon.com/s/&url=search-alias=automotive&field-keywords={{{s}}}'},
  {'t': 'jso', 'd': 'stackoverflow.com', 'u': 'https://stackoverflow.com/search?q=[java]+{{{s}}}'},
  {'t': 'ov', 'd': 'stackoverflow.com', 'ts': ['so', 'stackoverflow'], 'u': 'https://stackoverflow.com/search?q={{{s}}}'},
  {'t': 'msocial', 'd': 'mastodon.social', 'u': 'https://mastodon.social/tags/{{{s}}}'},
  {'t': '4chan', 'd': 'kagi.com', 'ad': '4chan.org', 'u': '/search?q={{{s}}}+site:4chan.org'},
  {'t': 'aamulehti', 'd': 'duckduckgo.com', 'u': 'https://duckduckgo.com/?sites=www.aamulehti.fi&kh=1&q={{{s}}}&ia=web'},
  {'t': 'wbm', 'd': 'web.archive.org', 'fmt': ['open_base_path'], 'u': 'https://web.archive.org/web/*/?q={{{s}}}'},
  {'t': 'ahkd', 'd': 'www.autohotkey.com', 'fmt': ['url_encode_placeholder'], 'u': 'https://www.autohotkey.com/docs/v2/search.htm?q={{{s}}}'},
  {'t': 'evil', 'd': 'blog.example', 'u': 'https://tracker.example.net/?q={{{s}}}'},
  {'t': 'arx', 'd': 'arxiv.org', 'u': 'http://arxiv.org/search?query={{{s}}}&searchtype=all'},
  'not an entry',
  {'t': 'x', 'd': 42, 'u': 'https://x.example/?q={{{s}}}'},
];

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final Directory dir;
  _FakePathProvider(this.dir);
  @override
  Future<String?> getApplicationDocumentsPath() async => dir.path;
}

class _FakeOutbound implements OutboundHttpFactory {
  http.Response Function(http.Request) responder =
      (_) => http.Response(jsonEncode(_bangs), 200);
  bool block = false;
  final List<Uri> fetched = [];

  @override
  OutboundClient clientFor(UserProxySettings settings) {
    if (block) return const OutboundClientBlocked('blocked by test fake');
    return OutboundClientReady(MockClient((req) async {
      fetched.add(req.url);
      return responder(req);
    }));
  }
}

void main() {
  group('siteSearchTable (LIR-036)', () {
    final table = siteSearchTable(_bangs);

    test('picks the bang named after the site', () {
      expect(table['imdb.com'], 'https://www.imdb.com/find?s=all&q=%s');
      expect(table['archive.org'], 'https://archive.org/search.php?query=%s',
          reason: 'prel searches one collection, not the site');
      expect(table['github.com'], 'https://github.com/search?q=%s');
      expect(table['amazon.com'], 'https://www.amazon.com/s?k=%s');
      expect(table['stackoverflow.com'], 'https://stackoverflow.com/search?q=%s');
    });

    test('keeps only plain searches of the bang\'s own site', () {
      expect(table, isNot(contains('mastodon.social')),
          reason: 'a page path, not a search');
      expect(table, isNot(contains('kagi.com')), reason: 'a search on Kagi');
      expect(table, isNot(contains('duckduckgo.com')),
          reason: 'a search of another site');
      expect(table, isNot(contains('web.archive.org')),
          reason: 'not a query the address takes as it is');
      expect(table, isNot(contains('blog.example')),
          reason: 'an address off the bang\'s domain');
      expect(table['autohotkey.com'],
          'https://www.autohotkey.com/docs/v2/search.htm?q=%s');
      expect(table['arxiv.org'], 'http://arxiv.org/search?query=%s&searchtype=all');
    });

    test('anything but a list is an empty table', () {
      expect(siteSearchTable({'a': 1}), isEmpty);
      expect(siteSearchTable(null), isEmpty);
    });
  });

  group('listedAddressFor', () {
    final table = siteSearchTable(_bangs);

    test('matches the host with or without www, then the domain', () {
      expect(listedAddressFor(table, 'https://www.imdb.com/'),
          'https://www.imdb.com/find?s=all&q=%s');
      expect(listedAddressFor(table, 'https://imdb.com/'),
          'https://www.imdb.com/find?s=all&q=%s');
      expect(listedAddressFor(table, 'https://m.imdb.com/title/tt1'),
          'https://www.imdb.com/find?s=all&q=%s');
      expect(listedAddressFor(table, 'https://unlisted.example/'), isNull);
      expect(listedAddressFor(const {}, 'https://www.imdb.com/'), isNull);
    });
  });

  group('capabilityOf with a listed address', () {
    test('a listed site searches itself only', () {
      final cap = WebSearchEngine.capabilityOf(
        initUrl: 'https://www.imdb.com/',
        listedAddress: 'https://www.imdb.com/find?s=all&q=%s',
      )!;
      expect(cap.kind, SearchKind.site);
      expect(cap.siteOperator, isFalse);
    });

    test('the table and the site\'s own pages both win over the list', () {
      expect(
        WebSearchEngine.capabilityOf(
          initUrl: 'https://github.com/',
          listedAddress: 'https://github.com/search?type=Users&q=%s',
        )!.template,
        'https://github.com/search?q=%s',
      );
      expect(
        WebSearchEngine.capabilityOf(
          initUrl: 'https://searx.lan/',
          discoveredAddress: 'https://searx.lan/search?q=%s',
          discoveredWeb: true,
          listedAddress: 'https://searx.lan/other?q=%s',
        )!.kind,
        SearchKind.web,
      );
    });

    test('a listed address off the site\'s domain is not taken', () {
      expect(
        WebSearchEngine.capabilityOf(
          initUrl: 'https://blog.example/',
          listedAddress: 'https://tracker.example.net/?q=%s',
        ),
        isNull,
      );
    });
  });

  group('SiteSearchListService', () {
    late Directory docs;
    late _FakeOutbound outbound;

    setUp(() async {
      docs = await Directory.systemTemp.createTemp('webspace_search_list_');
      PathProviderPlatform.instance = _FakePathProvider(docs);
      SharedPreferences.setMockInitialValues({});
      SiteSearchListService.resetForTest();
      outbound = _FakeOutbound();
      outboundHttp = outbound;
    });

    tearDown(() async {
      resetOutboundHttp();
      SiteSearchListService.resetForTest();
      await docs.delete(recursive: true);
    });

    test('nothing is listed or fetched until the user downloads', () async {
      await SiteSearchListService.instance.initialize();
      expect(SiteSearchListService.instance.isLoaded, isFalse);
      expect(SiteSearchListService.instance.addressFor('https://www.imdb.com/'),
          isNull);
      expect(outbound.fetched, isEmpty);
    });

    test('a download is kept across launches until cleared', () async {
      expect(await SiteSearchListService.instance.download(), isTrue);
      expect(outbound.fetched.single.toString(), kSiteSearchListUrl);
      expect(SiteSearchListService.instance.siteCount, 7);
      expect(SiteSearchListService.instance.lastUpdated, isNotNull);

      SiteSearchListService.resetForTest();
      await SiteSearchListService.instance.initialize();
      expect(SiteSearchListService.instance.addressFor('https://www.imdb.com/'),
          'https://www.imdb.com/find?s=all&q=%s');
      final model = WebViewModel(siteId: 'i', initUrl: 'https://www.imdb.com/');
      expect(model.searchCapability!.template,
          'https://www.imdb.com/find?s=all&q=%s');

      await SiteSearchListService.instance.clear();
      expect(SiteSearchListService.instance.isLoaded, isFalse);
      SiteSearchListService.resetForTest();
      await SiteSearchListService.instance.initialize();
      expect(SiteSearchListService.instance.isLoaded, isFalse);
    });

    test('a failed download keeps the list it had', () async {
      expect(await SiteSearchListService.instance.download(), isTrue);
      outbound.responder = (_) => http.Response('nope', 503);
      expect(await SiteSearchListService.instance.download(), isFalse);
      outbound.responder = (_) => http.Response('not json', 200);
      expect(await SiteSearchListService.instance.download(), isFalse);
      outbound.responder = (_) => http.Response('[]', 200);
      expect(await SiteSearchListService.instance.download(), isFalse);
      expect(SiteSearchListService.instance.siteCount, 7);
    });

    test('a proxy that cannot be honoured fetches nothing', () async {
      outbound.block = true;
      expect(await SiteSearchListService.instance.download(), isFalse);
      expect(outbound.fetched, isEmpty);
    });
  });
}
