import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/web_search_engine.dart';

SearchSite site(String id,
        {required String url, String? address, bool web = false}) =>
    SearchSite(
      siteId: id,
      name: id,
      initUrl: url,
      capability: WebSearchEngine.capabilityOf(
        initUrl: url,
        searchAddress: address,
        searchesWeb: web,
      ),
    );

void main() {
  group('capabilityOf (LIR-028)', () {
    test('known web engines search the web', () {
      final ddg = WebSearchEngine.capabilityOf(initUrl: 'https://duckduckgo.com/')!;
      expect(ddg.kind, SearchKind.web);
      expect(ddg.siteOperator, isTrue);
      expect(ddg.template, 'https://duckduckgo.com/?q=%s');
      final pplx = WebSearchEngine.capabilityOf(
          initUrl: 'https://www.perplexity.ai/')!;
      expect(pplx.kind, SearchKind.web);
      expect(pplx.siteOperator, isTrue,
          reason: 'Perplexity restricts its sources with site:');
      final metager =
          WebSearchEngine.capabilityOf(initUrl: 'https://metager.org/')!;
      expect(metager.kind, SearchKind.web);
      expect(metager.siteOperator, isFalse,
          reason: 'MetaGer documents no site: operator');
    });

    test('the table knows the common engines by their own addresses', () {
      const cases = <String, String>{
        'https://duck.com/': 'https://duckduckgo.com/?q=%s',
        'https://html.duckduckgo.com/html/':
            'https://html.duckduckgo.com/html/?q=%s',
        'https://lite.duckduckgo.com/lite/':
            'https://lite.duckduckgo.com/lite/?q=%s',
        'https://google.de/': 'https://www.google.de/search?q=%s',
        'https://www.google.co.uk/': 'https://www.google.co.uk/search?q=%s',
        'https://www.google.com.au/': 'https://www.google.com.au/search?q=%s',
        'https://cn.bing.com/': 'https://cn.bing.com/search?q=%s',
        'https://bing.com/': 'https://www.bing.com/search?q=%s',
        'https://www.qwant.com/': 'https://www.qwant.com/?q=%s',
        'https://metager.org/': 'https://metager.org/meta/meta.ger3?eingabe=%s',
        'https://metager.de/': 'https://metager.de/meta/meta.ger3?eingabe=%s',
        'https://swisscows.com/en': 'https://swisscows.com/web?query=%s',
        'https://search.marginalia.nu/':
            'https://marginalia-search.com/search?query=%s',
        'https://search.yahoo.com/': 'https://search.yahoo.com/search?p=%s',
        'https://yandex.ru/': 'https://yandex.ru/search/?text=%s',
        'https://www.yandex.com.tr/': 'https://yandex.com.tr/search/?text=%s',
        'https://ya.ru/': 'https://ya.ru/search/?text=%s',
        'https://www.baidu.com/': 'https://www.baidu.com/s?wd=%s',
        'https://www.naver.com/':
            'https://search.naver.com/search.naver?query=%s',
        'https://search.seznam.cz/': 'https://search.seznam.cz/?q=%s',
      };
      cases.forEach((home, address) {
        final cap = WebSearchEngine.capabilityOf(initUrl: home);
        expect(cap?.template, address, reason: home);
        expect(cap?.kind, SearchKind.web, reason: home);
      });
    });

    test('a service on an engine\'s domain is not the engine', () {
      for (final home in [
        'https://mail.google.com/',
        'https://docs.google.com/',
        'https://maps.yandex.cloud/',
        'https://mail.yahoo.com/',
        'https://seznam.cz/',
      ]) {
        expect(WebSearchEngine.capabilityOf(initUrl: home), isNull,
            reason: home);
      }
    });

    test('sites with their own search search themselves', () {
      final gh = WebSearchEngine.capabilityOf(initUrl: 'https://github.com/')!;
      expect(gh.kind, SearchKind.site);
      expect(gh.template, 'https://github.com/search?q=%s');
      final wiki = WebSearchEngine.capabilityOf(
          initUrl: 'https://de.wikipedia.org/wiki/Hauptseite')!;
      expect(wiki.template, 'https://de.wikipedia.org/w/index.php?search=%s',
          reason: 'each language searches itself');
    });

    test('an unknown host cannot search until given an address', () {
      expect(WebSearchEngine.capabilityOf(initUrl: 'https://blog.example/'),
          isNull);
      final custom = WebSearchEngine.capabilityOf(
        initUrl: 'https://blog.example/',
        searchAddress: 'https://blog.example/?s=%s',
      )!;
      expect(custom.kind, SearchKind.site);
      expect(custom.siteOperator, isFalse);
    });

    test('a custom address that searches the web takes site:', () {
      final searx = WebSearchEngine.capabilityOf(
        initUrl: 'https://searx.lan/',
        searchAddress: 'https://searx.lan/search?q=%s',
        searchesWeb: true,
      )!;
      expect(searx.kind, SearchKind.web);
      expect(searx.siteOperator, isTrue);
    });

    test('a custom address wins over the known one; a bad one searches nothing',
        () {
      final gh = WebSearchEngine.capabilityOf(
        initUrl: 'https://github.com/',
        searchAddress: 'https://github.com/search?type=code&q=%s',
      )!;
      expect(gh.template, 'https://github.com/search?type=code&q=%s');
      expect(
        WebSearchEngine.capabilityOf(
            initUrl: 'https://github.com/', searchAddress: 'https://github.com/'),
        isNull,
      );
    });

    test('brave.com is not Brave Search', () {
      expect(WebSearchEngine.capabilityOf(initUrl: 'https://brave.com/'), isNull);
    });
  });

  group('discovered addresses (LIR-035)', () {
    test('an unknown site searches with what its pages declared', () {
      final site = WebSearchEngine.capabilityOf(
        initUrl: 'https://blog.example/',
        discoveredAddress: 'https://blog.example/search?q=%s',
      )!;
      expect(site.kind, SearchKind.site);
      expect(site.siteOperator, isFalse);
      final searx = WebSearchEngine.capabilityOf(
        initUrl: 'https://searx.lan/',
        discoveredAddress: 'https://searx.lan/search?q=%s',
        discoveredWeb: true,
      )!;
      expect(searx.kind, SearchKind.web);
      expect(searx.siteOperator, isTrue);
    });

    test('the user\'s address and the table both win over a declared one', () {
      expect(
        WebSearchEngine.capabilityOf(
          initUrl: 'https://blog.example/',
          searchAddress: 'https://blog.example/?s=%s',
          discoveredAddress: 'https://blog.example/search?q=%s',
        )!.template,
        'https://blog.example/?s=%s',
      );
      expect(
        WebSearchEngine.capabilityOf(
          initUrl: 'https://github.com/',
          discoveredAddress: 'https://github.com/find?q=%s',
          discoveredWeb: true,
        )!.template,
        'https://github.com/search?q=%s',
      );
    });

    test('a declared address off the site\'s domain is never taken', () {
      expect(
        WebSearchEngine.capabilityOf(
          initUrl: 'https://blog.example/',
          discoveredAddress: 'https://tracker.example.net/?q=%s',
          discoveredWeb: true,
        ),
        isNull,
      );
      expect(
        WebSearchEngine.capabilityOf(
          initUrl: 'https://moved.example/',
          discoveredAddress: 'https://blog.example/search?q=%s',
        ),
        isNull,
        reason: 'a site whose home moved drops its old home\'s address',
      );
      expect(
        WebSearchEngine.acceptsDiscovered(
            'https://www.blog.example/search?q=%s',
            initUrl: 'https://blog.example/'),
        isTrue,
      );
    });

    test('only a site with no address and an unknown host discovers', () {
      expect(WebSearchEngine.discovers(initUrl: 'https://searx.lan/'), isTrue);
      expect(
          WebSearchEngine.discovers(initUrl: 'https://duckduckgo.com/'), isFalse);
      expect(
        WebSearchEngine.discovers(
            initUrl: 'https://searx.lan/',
            searchAddress: 'https://searx.lan/search?q=%s'),
        isFalse,
      );
      expect(WebSearchEngine.discovers(initUrl: 'file:///x.html'), isFalse);
    });
  });

  group('URLs', () {
    const ddg = 'https://duckduckgo.com/?q=%s';

    test('a template needs http(s), a host and %s', () {
      expect(WebSearchEngine.isValidTemplate(ddg), isTrue);
      expect(WebSearchEngine.isValidTemplate('https://duckduckgo.com/?q='),
          isFalse);
      expect(WebSearchEngine.isValidTemplate('javascript:alert(%s)'), isFalse);
      expect(WebSearchEngine.isValidTemplate('https:///?q=%s'), isFalse);
    });

    test('the query is encoded as one query component', () {
      final url = WebSearchEngine.buildUrl(ddg, query: '  a&b=c #d  ')!;
      expect(url.queryParameters['q'], 'a&b=c #d');
      expect(url.queryParameters.keys, ['q']);
      expect(url.fragment, isEmpty);
    });

    test('a blank query builds nothing', () {
      expect(WebSearchEngine.buildUrl(ddg, query: '   '), isNull);
    });

    test('a scoped option searches site:<host>', () {
      final option = SearchOption(site('ddg', url: 'https://duckduckgo.com/'),
          scoped: true);
      final url = WebSearchEngine.urlFor(option,
          query: 'tabs', scopeHost: 'github.com')!;
      expect(url.queryParameters['q'], 'site:github.com tabs');
      final plain = WebSearchEngine.urlFor(
          SearchOption(site('ddg', url: 'https://duckduckgo.com/'),
              scoped: false),
          query: 'tabs',
          scopeHost: 'github.com')!;
      expect(plain.queryParameters['q'], 'tabs');
    });
  });

  group('barOptions (LIR-033)', () {
    final gh = site('gh', url: 'https://github.com/');
    final blog = site('blog', url: 'https://blog.example/');
    final ddg = site('ddg', url: 'https://duckduckgo.com/');
    final kagi = site('kagi', url: 'https://kagi.com/');
    final all = [gh, blog, ddg, kagi];

    List<String> ids(List<SearchOption> o) => [for (final x in o) x.site.siteId];

    test('web engines first, then the site on screen\'s own search', () {
      final bar = WebSearchEngine.barOptions(
          identity: gh, candidates: all, declared: const []);
      expect(ids(bar.options), ['ddg', 'kagi', 'gh']);
      expect(bar.options.every((o) => !o.scoped), isTrue);
      expect(bar.preselected, 0);
    });

    test('the default follows the site\'s, then the app\'s', () {
      expect(
          WebSearchEngine.barOptions(
                  identity: blog,
                  candidates: all,
                  declared: const [],
                  appDefault: 'kagi')
              .preselected,
          1);
      final bar = WebSearchEngine.barOptions(
          identity: blog,
          candidates: all,
          declared: const [],
          declaredDefault: 'ddg',
          appDefault: 'kagi');
      expect(ids(bar.options), ['ddg', 'kagi']);
      expect(bar.preselected, 0);
    });

    test('with no web engine the site\'s own search is the default', () {
      final bar = WebSearchEngine.barOptions(
          identity: gh, candidates: [gh, blog], declared: const []);
      expect(ids(bar.options), ['gh']);
      expect(bar.preselected, 0);
    });

    test('nothing can search: no options', () {
      expect(
          WebSearchEngine.barOptions(
                  identity: blog, candidates: [blog], declared: const [])
              .options,
          isEmpty);
    });
  });

  group('options', () {
    final gh = site('gh', url: 'https://github.com/');
    final blog = site('blog', url: 'https://blog.example/');
    final ddg = site('ddg', url: 'https://duckduckgo.com/');
    final kagi = site('kagi', url: 'https://kagi.com/');
    final pplx = site('pplx', url: 'https://www.perplexity.ai/');
    final mg = site('mg', url: 'https://metager.org/');
    final all = [gh, blog, ddg, kagi, pplx, mg];

    List<String> ids(List<SearchOption> o) => [for (final x in o) x.site.siteId];

    test('the web scope offers web engines only', () {
      expect(
        ids(WebSearchEngine.options(
            scope: SearchScope.web, identity: gh, candidates: all, declared: [])),
        ['ddg', 'kagi', 'pplx', 'mg'],
      );
    });

    test('this site: own search first, then engines that take site:', () {
      final o = WebSearchEngine.options(
          scope: SearchScope.thisSite, identity: gh, candidates: all, declared: []);
      expect(ids(o), ['gh', 'ddg', 'kagi', 'pplx']);
      expect(o.first.scoped, isFalse);
      expect(o.skip(1).every((x) => x.scoped), isTrue);
    });

    test('a site with no search is searched through engines only', () {
      expect(
        ids(WebSearchEngine.options(
            scope: SearchScope.thisSite, identity: blog, candidates: all, declared: [])),
        ['ddg', 'kagi', 'pplx'],
      );
    });

    test('the declared list limits engines but never own search (D2)', () {
      expect(
        ids(WebSearchEngine.options(
            scope: SearchScope.thisSite,
            identity: gh,
            candidates: all,
            declared: ['kagi'])),
        ['gh', 'kagi'],
      );
      expect(
        ids(WebSearchEngine.options(
            scope: SearchScope.web,
            identity: gh,
            candidates: all,
            declared: ['kagi', 'pplx'])),
        ['kagi', 'pplx'],
      );
    });

    test('a web engine on screen offers only the web scope', () {
      expect(WebSearchEngine.offersThisSite(ddg), isFalse);
      expect(WebSearchEngine.initialScope(ddg), SearchScope.web);
      expect(WebSearchEngine.initialScope(gh), SearchScope.thisSite);
      expect(WebSearchEngine.initialScope(blog), SearchScope.web);
    });

    test('preselect: the site default, then the app default, then the first', () {
      final o = WebSearchEngine.options(
          scope: SearchScope.web, identity: gh, candidates: all, declared: []);
      expect(WebSearchEngine.preselect(o, declaredDefault: 'pplx', appDefault: 'kagi'), 2);
      expect(WebSearchEngine.preselect(o, appDefault: 'kagi'), 1);
      expect(WebSearchEngine.preselect(o, declaredDefault: 'gone'), 0);
    });
  });

  group('land', () {
    SearchLanding land({
      String search = 'ddg',
      String owner = 'gh',
      String identity = 'gh',
      bool tabs = true,
      bool canHost = true,
      bool inDomain = true,
    }) =>
        WebSearchEngine.land(
          (search: search, owner: owner, identity: identity),
          tabsEnabled: tabs,
          canHost: canHost,
          urlInSearchSiteDomain: inDomain,
        );

    test('own search: a child tab, or in place with tabs off (S1)', () {
      expect(land(search: 'gh'), SearchLanding.childTab);
      expect(land(search: 'gh', tabs: false), SearchLanding.inPlace);
    });

    test('another site: a hosted tab (S2)', () {
      expect(land(), SearchLanding.hostedChildTab);
    });

    test('fallbacks: tabs off, cannot host, off-domain address (S13, S14)', () {
      expect(land(tabs: false), SearchLanding.inSearchSite);
      expect(land(canHost: false), SearchLanding.inSearchSite);
      expect(land(inDomain: false), SearchLanding.inSearchSite);
    });

    test('from a hosted tab, the engine it runs as searches in a child tab', () {
      expect(land(search: 'ddg', identity: 'ddg'), SearchLanding.childTab);
    });

    test('from a hosted tab, the owner searches as the owner', () {
      expect(land(search: 'gh', identity: 'ddg'), SearchLanding.childTab);
      expect(land(search: 'gh', identity: 'ddg', tabs: false),
          SearchLanding.inSearchSite);
    });
  });

  group('addable (LIR-029 empty state)', () {
    List<String> names(List<KnownSearchHost> k) => [for (final x in k) x.name];

    test('offers the five engines when the user has none', () {
      expect(names(kAddableSearchEngines),
          ['DuckDuckGo', 'Brave Search', 'Kagi', 'Perplexity', 'Google']);
      expect(
          names(WebSearchEngine.addable(SearchScope.web, candidates: const [])),
          names(kAddableSearchEngines));
      expect(
          names(WebSearchEngine.addable(SearchScope.thisSite,
              candidates: const [])),
          names(kAddableSearchEngines),
          reason: 'all five take site:');
    });

    test('never offers a second site for an engine the user has', () {
      final mine = [
        site('blog', url: 'https://blog.example/'),
        site('ddg', url: 'https://start.duckduckgo.com/'),
        site('g', url: 'https://www.google.de/'),
      ];
      expect(names(WebSearchEngine.addable(SearchScope.web, candidates: mine)),
          ['Brave Search', 'Kagi', 'Perplexity']);
    });
  });
}
