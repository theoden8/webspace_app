/// Pure-Dart logic for web search (LIR-028 to LIR-030): which of the user's
/// sites can search and how, which of them a search from a given site offers,
/// and where its results land. A search runs in one of the user's own sites,
/// with that site's container and posture; this file never names a site the
/// user does not have, except as an offer to add one.
library;

import 'package:webspace/services/url_host.dart';

/// The token a search address carries where the query goes.
const String kSearchQueryToken = '%s';

/// A web search searches everything; a site search only its own site.
enum SearchKind { web, site }

/// What a search from the sheet covers: the web, or the site on screen.
enum SearchScope { web, thisSite }

/// How a site searches: its address and what it covers.
class SearchCapability {
  final String template;
  final SearchKind kind;

  /// Whether the engine honours `site:`, so it can search inside another site.
  final bool siteOperator;

  const SearchCapability({
    required this.template,
    required this.kind,
    required this.siteOperator,
  });
}

/// A search engine or a site with its own search, recognised by host.
class KnownSearchHost {
  final String name;
  final String home;
  final SearchKind kind;
  final bool siteOperator;
  final bool Function(String host) matches;
  final String Function(String host) template;

  const KnownSearchHost({
    required this.name,
    required this.home,
    required this.kind,
    required this.siteOperator,
    required this.matches,
    required this.template,
  });
}

bool _isOrUnder(String host, {required String domain}) =>
    host == domain || host.endsWith('.$domain');

/// `google.com` and Google's country domains (`google.de`, `google.co.uk`,
/// `google.com.au`), with or without `www.`.
final RegExp _googleHost =
    RegExp(r'^(www\.)?google\.(com|[a-z]{2}|co\.[a-z]{2}|com\.[a-z]{2})$');

/// Yandex's country domains (`yandex.ru`, `yandex.com.tr`) and `ya.ru`.
final RegExp _yandexHost =
    RegExp(r'^(www\.)?(yandex\.(com|[a-z]{2}|com\.[a-z]{2})|ya\.ru)$');

String _withWww(String host) => host.startsWith('www.') ? host : 'www.$host';

/// Known hosts. Web engines first, the first five in the order the empty
/// state offers them. Each address is the one the engine's own OpenSearch
/// description gives, less the parameters that only name the referrer.
final List<KnownSearchHost> kKnownSearchHosts = [
  KnownSearchHost(
    name: 'DuckDuckGo',
    home: 'https://duckduckgo.com/',
    kind: SearchKind.web,
    siteOperator: true,
    matches: (h) =>
        _isOrUnder(h, domain: 'duckduckgo.com') || h == 'duck.com' || h == 'www.duck.com',
    // The no-JavaScript editions keep their own result pages.
    template: (h) => switch (h) {
      'html.duckduckgo.com' => 'https://html.duckduckgo.com/html/?q=%s',
      'lite.duckduckgo.com' => 'https://lite.duckduckgo.com/lite/?q=%s',
      _ => 'https://duckduckgo.com/?q=%s',
    },
  ),
  KnownSearchHost(
    name: 'Brave Search',
    home: 'https://search.brave.com/',
    kind: SearchKind.web,
    siteOperator: true,
    matches: (h) => h == 'search.brave.com',
    template: (_) => 'https://search.brave.com/search?q=%s',
  ),
  KnownSearchHost(
    name: 'Kagi',
    home: 'https://kagi.com/',
    kind: SearchKind.web,
    siteOperator: true,
    matches: (h) => _isOrUnder(h, domain: 'kagi.com'),
    template: (_) => 'https://kagi.com/search?q=%s',
  ),
  KnownSearchHost(
    name: 'Perplexity',
    home: 'https://www.perplexity.ai/',
    kind: SearchKind.web,
    siteOperator: true,
    matches: (h) => _isOrUnder(h, domain: 'perplexity.ai'),
    template: (_) => 'https://www.perplexity.ai/search/new?q=%s',
  ),
  KnownSearchHost(
    name: 'Google',
    home: 'https://www.google.com/',
    kind: SearchKind.web,
    siteOperator: true,
    matches: _googleHost.hasMatch,
    template: (h) => 'https://${_withWww(h)}/search?q=%s',
  ),
  KnownSearchHost(
    name: 'Startpage',
    home: 'https://www.startpage.com/',
    kind: SearchKind.web,
    siteOperator: true,
    matches: (h) => _isOrUnder(h, domain: 'startpage.com'),
    template: (_) => 'https://www.startpage.com/do/search?q=%s',
  ),
  KnownSearchHost(
    name: 'Bing',
    home: 'https://www.bing.com/',
    kind: SearchKind.web,
    siteOperator: true,
    matches: (h) => h == 'bing.com' || h == 'www.bing.com' || h == 'cn.bing.com',
    template: (h) => 'https://${h == 'bing.com' ? 'www.bing.com' : h}/search?q=%s',
  ),
  KnownSearchHost(
    name: 'Mojeek',
    home: 'https://www.mojeek.com/',
    kind: SearchKind.web,
    siteOperator: true,
    matches: (h) => _isOrUnder(h, domain: 'mojeek.com'),
    template: (_) => 'https://www.mojeek.com/search?q=%s',
  ),
  KnownSearchHost(
    name: 'Ecosia',
    home: 'https://www.ecosia.org/',
    kind: SearchKind.web,
    siteOperator: true,
    matches: (h) => _isOrUnder(h, domain: 'ecosia.org'),
    template: (_) => 'https://www.ecosia.org/search?q=%s',
  ),
  KnownSearchHost(
    name: 'Qwant',
    home: 'https://www.qwant.com/',
    kind: SearchKind.web,
    siteOperator: true,
    matches: (h) => _isOrUnder(h, domain: 'qwant.com'),
    template: (_) => 'https://www.qwant.com/?q=%s',
  ),
  KnownSearchHost(
    name: 'MetaGer',
    home: 'https://metager.org/',
    kind: SearchKind.web,
    siteOperator: false,
    matches: (h) => _isOrUnder(h, domain: 'metager.org') || _isOrUnder(h, domain: 'metager.de'),
    template: (h) => 'https://${_isOrUnder(h, domain: 'metager.de') ? 'metager.de' : 'metager.org'}'
        '/meta/meta.ger3?eingabe=%s',
  ),
  KnownSearchHost(
    name: 'Swisscows',
    home: 'https://swisscows.com/',
    kind: SearchKind.web,
    siteOperator: false,
    matches: (h) => _isOrUnder(h, domain: 'swisscows.com'),
    template: (_) => 'https://swisscows.com/web?query=%s',
  ),
  KnownSearchHost(
    name: 'Marginalia',
    home: 'https://marginalia-search.com/',
    kind: SearchKind.web,
    siteOperator: true,
    matches: (h) =>
        _isOrUnder(h, domain: 'marginalia-search.com') || h == 'search.marginalia.nu',
    template: (_) => 'https://marginalia-search.com/search?query=%s',
  ),
  KnownSearchHost(
    name: 'Yahoo',
    home: 'https://search.yahoo.com/',
    kind: SearchKind.web,
    siteOperator: true,
    matches: (h) => h == 'search.yahoo.com',
    template: (_) => 'https://search.yahoo.com/search?p=%s',
  ),
  KnownSearchHost(
    name: 'Yandex',
    home: 'https://yandex.com/',
    kind: SearchKind.web,
    siteOperator: true,
    matches: _yandexHost.hasMatch,
    template: (h) =>
        'https://${h.startsWith('www.') ? h.substring(4) : h}/search/?text=%s',
  ),
  KnownSearchHost(
    name: 'Baidu',
    home: 'https://www.baidu.com/',
    kind: SearchKind.web,
    siteOperator: true,
    matches: (h) => h == 'baidu.com' || h == 'www.baidu.com',
    template: (_) => 'https://www.baidu.com/s?wd=%s',
  ),
  KnownSearchHost(
    name: 'Naver',
    home: 'https://www.naver.com/',
    kind: SearchKind.web,
    siteOperator: false,
    matches: (h) =>
        h == 'naver.com' || h == 'www.naver.com' || h == 'search.naver.com',
    template: (_) => 'https://search.naver.com/search.naver?query=%s',
  ),
  KnownSearchHost(
    name: 'Seznam',
    home: 'https://search.seznam.cz/',
    kind: SearchKind.web,
    siteOperator: false,
    matches: (h) => h == 'search.seznam.cz',
    template: (_) => 'https://search.seznam.cz/?q=%s',
  ),
  KnownSearchHost(
    name: 'GitHub',
    home: 'https://github.com/',
    kind: SearchKind.site,
    siteOperator: false,
    matches: (h) => h == 'github.com' || h == 'www.github.com',
    template: (_) => 'https://github.com/search?q=%s',
  ),
  KnownSearchHost(
    name: 'Wikipedia',
    home: 'https://www.wikipedia.org/',
    kind: SearchKind.site,
    siteOperator: false,
    matches: (h) => h.endsWith('.wikipedia.org') && h != 'www.wikipedia.org',
    template: (h) => 'https://$h/w/index.php?search=%s',
  ),
  KnownSearchHost(
    name: 'YouTube',
    home: 'https://www.youtube.com/',
    kind: SearchKind.site,
    siteOperator: false,
    matches: (h) => _isOrUnder(h, domain: 'youtube.com'),
    template: (_) => 'https://www.youtube.com/results?search_query=%s',
  ),
  KnownSearchHost(
    name: 'Reddit',
    home: 'https://www.reddit.com/',
    kind: SearchKind.site,
    siteOperator: false,
    matches: (h) => _isOrUnder(h, domain: 'reddit.com'),
    template: (_) => 'https://www.reddit.com/search/?q=%s',
  ),
  KnownSearchHost(
    name: 'Stack Overflow',
    home: 'https://stackoverflow.com/',
    kind: SearchKind.site,
    siteOperator: false,
    matches: (h) => _isOrUnder(h, domain: 'stackoverflow.com'),
    template: (_) => 'https://stackoverflow.com/search?q=%s',
  ),
];

/// The web engines the empty state offers to add as sites.
List<KnownSearchHost> get kAddableSearchEngines => [
      for (final k in kKnownSearchHosts.take(5))
        if (k.kind == SearchKind.web) k,
    ];

/// One of the user's sites, as the search engine needs to see it.
class SearchSite {
  final String siteId;
  final String name;
  final String initUrl;
  final SearchCapability? capability;

  const SearchSite({
    required this.siteId,
    required this.name,
    required this.initUrl,
    required this.capability,
  });
}

/// One chip of the sheet: [site] searching [scope].
class SearchOption {
  final SearchSite site;

  /// The search covers the site on screen through `site:`.
  final bool scoped;

  const SearchOption(this.site, {required this.scoped});
}

/// The sites a search involves, by siteId: the one that searches, the one
/// whose slot it starts from, and the one that slot is running as.
typedef SearchParties = ({String search, String owner, String identity});

/// Where a search's results open.
enum SearchLanding {
  /// The site on screen searches itself, with tabs off: in its page.
  inPlace,

  /// A new child tab of the tab on screen, running as the searching site:
  /// the site on screen's own search, or its owner's.
  childTab,

  /// A new child tab of the tab on screen, owned by the site on screen and
  /// running as the search site (LIR-018).
  hostedChildTab,

  /// The search site's own tab or page: tabs off, or a search site that
  /// cannot host (LIR-019).
  inSearchSite,
}

class WebSearchEngine {
  WebSearchEngine._();

  /// Whether [template] can build a search URL: an http(s) address with a
  /// host and at least one [kSearchQueryToken].
  static bool isValidTemplate(String template) {
    final t = template.trim();
    if (!t.contains(kSearchQueryToken)) return false;
    return _parse(t.replaceAll(kSearchQueryToken, 'q')) != null;
  }

  /// The URL [template] makes of [query], or null when the query is blank or
  /// the template is not valid. The query is encoded as a query component, so
  /// `&`, `#` and `=` in it stay part of the search.
  static Uri? buildUrl(String template, {required String query}) {
    final q = query.trim();
    if (q.isEmpty || !isValidTemplate(template)) return null;
    return _parse(
      template.trim().replaceAll(
        kSearchQueryToken,
        Uri.encodeQueryComponent(q),
      ),
    );
  }

  /// [query] restricted to [host] for an engine that honours `site:`.
  static String scopedQuery(String host, {required String query}) =>
      'site:$host ${query.trim()}';

  static KnownSearchHost? knownFor(String initUrl) {
    final host = Host.inUrl(initUrl);
    if (host == null) return null;
    for (final k in kKnownSearchHosts) {
      if (k.matches(host)) return k;
    }
    return null;
  }

  /// How a site searches: its own address when it has one, else what its
  /// host is known for, else what its page declared (LIR-035), else what the
  /// downloaded site search list names (LIR-036), else not at all. A custom
  /// or discovered address that searches the web is assumed to honour
  /// `site:`, as SearXNG and the big engines do; a listed one only ever
  /// searches its own site.
  static SearchCapability? capabilityOf({
    required String initUrl,
    String? searchAddress,
    bool searchesWeb = false,
    String? discoveredAddress,
    bool discoveredWeb = false,
    String? listedAddress,
  }) {
    final custom = searchAddress?.trim();
    if (custom != null && custom.isNotEmpty) {
      if (!isValidTemplate(custom)) return null;
      return SearchCapability(
        template: custom,
        kind: searchesWeb ? SearchKind.web : SearchKind.site,
        siteOperator: searchesWeb,
      );
    }
    final known = knownFor(initUrl);
    final host = Host.inUrl(initUrl);
    if (known != null && host != null) {
      return SearchCapability(
        template: known.template(host),
        kind: known.kind,
        siteOperator: known.siteOperator,
      );
    }
    final found = discoveredAddress?.trim();
    if (found != null && acceptsDiscovered(found, initUrl: initUrl)) {
      return SearchCapability(
        template: found,
        kind: discoveredWeb ? SearchKind.web : SearchKind.site,
        siteOperator: discoveredWeb,
      );
    }
    final listed = listedAddress?.trim();
    if (listed == null || !acceptsDiscovered(listed, initUrl: initUrl)) {
      return null;
    }
    return SearchCapability(
      template: listed,
      kind: SearchKind.site,
      siteOperator: false,
    );
  }

  /// Whether a page of the site at [initUrl] may give it [template]: a valid
  /// address inside the site's own domain, so a page can never hand its
  /// site's searches to another host, and a site whose home moved drops the
  /// address its old home declared.
  static bool acceptsDiscovered(String template, {required String initUrl}) {
    if (!isValidTemplate(template)) return false;
    final url = buildUrl(template, query: 'q');
    return url != null && inDomainOf(url, initUrl: initUrl);
  }

  /// Whether a site at [initUrl] can learn its search from its pages: one
  /// with no address of its own and a host the table does not know.
  static bool discovers({required String initUrl, String? searchAddress}) {
    final custom = searchAddress?.trim();
    if (custom != null && custom.isNotEmpty) return false;
    return Host.inUrl(initUrl) != null && knownFor(initUrl) == null;
  }

  /// The known engines the empty state offers to add in [scope]: the web
  /// engines that suit the scope, less those [candidates] already has a site
  /// for. A search never makes a second site for an engine the user has.
  static List<KnownSearchHost> addable(
    SearchScope scope, {
    required List<SearchSite> candidates,
  }) =>
      [
        for (final k in kAddableSearchEngines)
          if ((scope == SearchScope.web || k.siteOperator) &&
              !candidates.any((c) => identical(knownFor(c.initUrl), k)))
            k,
      ];

  /// Whether the sheet offers "this site" for [identity], the site on screen:
  /// any site but a web engine, which has nothing of its own to search.
  static bool offersThisSite(SearchSite identity) =>
      identity.capability?.kind != SearchKind.web;

  /// The scope the sheet opens on: the site on screen when it has its own
  /// search, else the web.
  static SearchScope initialScope(SearchSite identity) =>
      identity.capability?.kind == SearchKind.site
          ? SearchScope.thisSite
          : SearchScope.web;

  /// The chips for [scope], in order, from a slot running as [identity].
  ///
  /// [candidates] are the user's sites on the same side of an archive as the
  /// site on screen. [declared] is the owner's list of search sites; when not
  /// empty it limits the web engines offered. The site on screen's own search
  /// is always offered for its own scope.
  static List<SearchOption> options({
    required SearchScope scope,
    required SearchSite identity,
    required List<SearchSite> candidates,
    required List<String> declared,
  }) {
    bool allowed(SearchSite s) =>
        declared.isEmpty || declared.contains(s.siteId);
    final web = [
      for (final s in candidates)
        if (s.capability?.kind == SearchKind.web && allowed(s)) s,
    ];
    if (scope == SearchScope.web) {
      return [for (final s in web) SearchOption(s, scoped: false)];
    }
    final own = identity.capability?.kind == SearchKind.site
        ? SearchOption(identity, scoped: false)
        : null;
    return [
      ?own,
      for (final s in web)
        if (s.capability!.siteOperator && s.siteId != identity.siteId)
          SearchOption(s, scoped: true),
    ];
  }

  /// The chip preselected among [options]: the owner's default, else the app
  /// default, else the first.
  static int preselect(
    List<SearchOption> options, {
    String? declaredDefault,
    String? appDefault,
  }) {
    for (final id in [declaredDefault, appDefault]) {
      if (id == null) continue;
      final i = options.indexWhere((o) => o.site.siteId == id);
      if (i >= 0) return i;
    }
    return 0;
  }

  /// What the URL bar searches with (LIR-033): the web searches the sheet
  /// would offer, then the site on screen's own search. The default is the
  /// sheet's web preselection, or the site's own search when nothing
  /// searches the web. Empty options mean nothing can search.
  static ({List<SearchOption> options, int preselected}) barOptions({
    required SearchSite identity,
    required List<SearchSite> candidates,
    required List<String> declared,
    String? declaredDefault,
    String? appDefault,
  }) {
    final web = options(
      scope: SearchScope.web,
      identity: identity,
      candidates: candidates,
      declared: declared,
    );
    final own = identity.capability?.kind == SearchKind.site
        ? SearchOption(identity, scoped: false)
        : null;
    return (
      options: [...web, ?own],
      preselected: web.isEmpty
          ? 0
          : preselect(web,
              declaredDefault: declaredDefault, appDefault: appDefault),
    );
  }

  /// The URL [option] searches [query] with, or null.
  static Uri? urlFor(SearchOption option,
      {required String query, String? scopeHost}) {
    final template = option.site.capability?.template;
    if (template == null) return null;
    final q = option.scoped && scopeHost != null
        ? scopedQuery(scopeHost, query: query)
        : query;
    return buildUrl(template, query: q);
  }

  /// Where a search by `sites.search` lands, from a slot owned by
  /// `sites.owner` and running as `sites.identity`.
  static SearchLanding land(
    SearchParties sites, {
    required bool tabsEnabled,
    required bool canHost,
    required bool urlInSearchSiteDomain,
  }) {
    if (sites.search == sites.identity) {
      return tabsEnabled ? SearchLanding.childTab : SearchLanding.inPlace;
    }
    if (sites.search == sites.owner) {
      return tabsEnabled ? SearchLanding.childTab : SearchLanding.inSearchSite;
    }
    if (tabsEnabled && canHost && urlInSearchSiteDomain) {
      return SearchLanding.hostedChildTab;
    }
    return SearchLanding.inSearchSite;
  }

  /// Whether [url] is inside [initUrl]'s navigation domain, which a hosted
  /// tab's URL must be (LIR-018).
  static bool inDomainOf(Uri url, {required String initUrl}) =>
      getNormalizedDomain(url.toString()) == getNormalizedDomain(initUrl);

  static Uri? _parse(String s) {
    final uri = Uri.tryParse(s);
    if (uri == null) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    if (uri.host.isEmpty) return null;
    return uri;
  }
}
