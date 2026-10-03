import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/web_search_engine.dart';

SearchSite site(String id, String url, {String? address, bool web = false}) =>
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
      expect(pplx.siteOperator, isFalse,
          reason: 'Perplexity is not offered for a site: search');
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
      final url = WebSearchEngine.buildUrl(ddg, '  a&b=c #d  ')!;
      expect(url.queryParameters['q'], 'a&b=c #d');
      expect(url.queryParameters.keys, ['q']);
      expect(url.fragment, isEmpty);
    });

    test('a blank query builds nothing', () {
      expect(WebSearchEngine.buildUrl(ddg, '   '), isNull);
    });

    test('a scoped option searches site:<host>', () {
      final option = SearchOption(site('ddg', 'https://duckduckgo.com/'),
          scoped: true);
      final url = WebSearchEngine.urlFor(option, 'tabs', scopeHost: 'github.com')!;
      expect(url.queryParameters['q'], 'site:github.com tabs');
      final plain = WebSearchEngine.urlFor(
          SearchOption(site('ddg', 'https://duckduckgo.com/'), scoped: false),
          'tabs',
          scopeHost: 'github.com')!;
      expect(plain.queryParameters['q'], 'tabs');
    });
  });

  group('barOptions (LIR-033)', () {
    final gh = site('gh', 'https://github.com/');
    final blog = site('blog', 'https://blog.example/');
    final ddg = site('ddg', 'https://duckduckgo.com/');
    final kagi = site('kagi', 'https://kagi.com/');
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
    final gh = site('gh', 'https://github.com/');
    final blog = site('blog', 'https://blog.example/');
    final ddg = site('ddg', 'https://duckduckgo.com/');
    final kagi = site('kagi', 'https://kagi.com/');
    final pplx = site('pplx', 'https://www.perplexity.ai/');
    final all = [gh, blog, ddg, kagi, pplx];

    List<String> ids(List<SearchOption> o) => [for (final x in o) x.site.siteId];

    test('the web scope offers web engines only', () {
      expect(
        ids(WebSearchEngine.options(
            scope: SearchScope.web, identity: gh, candidates: all, declared: [])),
        ['ddg', 'kagi', 'pplx'],
      );
    });

    test('this site: own search first, then engines that take site:', () {
      final o = WebSearchEngine.options(
          scope: SearchScope.thisSite, identity: gh, candidates: all, declared: []);
      expect(ids(o), ['gh', 'ddg', 'kagi']);
      expect(o.first.scoped, isFalse);
      expect(o.skip(1).every((x) => x.scoped), isTrue);
    });

    test('a site with no search is searched through engines only', () {
      expect(
        ids(WebSearchEngine.options(
            scope: SearchScope.thisSite, identity: blog, candidates: all, declared: [])),
        ['ddg', 'kagi'],
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
          searchSiteId: search,
          ownerSiteId: owner,
          identitySiteId: identity,
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

  test('the empty state offers web engines, Perplexity only for the web', () {
    final names = [for (final k in kAddableSearchEngines) k.name];
    expect(names, ['DuckDuckGo', 'Brave Search', 'Kagi', 'Perplexity', 'Google']);
  });
}
