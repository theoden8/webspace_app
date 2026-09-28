/// Pure-Dart logic for web search (LIR-028 to LIR-030): which of the user's
/// sites can search and how, which of them a search from a given site offers,
/// and where its results land. A search runs in one of the user's own sites,
/// with that site's container and posture; this file never names a site the
/// user does not have, except as an offer to add one.
library;

import 'package:webspace/web_view_model.dart' show getNormalizedDomain;

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

bool _isOrUnder(String host, String domain) =>
    host == domain || host.endsWith('.$domain');

/// Known hosts. Web engines first, in the order the empty state offers them.
final List<KnownSearchHost> kKnownSearchHosts = [
  KnownSearchHost(
    name: 'DuckDuckGo',
    home: 'https://duckduckgo.com/',
    kind: SearchKind.web,
    siteOperator: true,
    matches: (h) => _isOrUnder(h, 'duckduckgo.com'),
    template: (_) => 'https://duckduckgo.com/?q=%s',
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
    matches: (h) => _isOrUnder(h, 'kagi.com'),
    template: (_) => 'https://kagi.com/search?q=%s',
  ),
  KnownSearchHost(
    name: 'Perplexity',
    home: 'https://www.perplexity.ai/',
    kind: SearchKind.web,
    siteOperator: false,
    matches: (h) => _isOrUnder(h, 'perplexity.ai'),
    template: (_) => 'https://www.perplexity.ai/search/new?q=%s',
  ),
  KnownSearchHost(
    name: 'Google',
    home: 'https://www.google.com/',
    kind: SearchKind.web,
    siteOperator: true,
    matches: (h) => h == 'google.com' || h == 'www.google.com',
    template: (_) => 'https://www.google.com/search?q=%s',
  ),
  KnownSearchHost(
    name: 'Startpage',
    home: 'https://www.startpage.com/',
    kind: SearchKind.web,
    siteOperator: true,
    matches: (h) => _isOrUnder(h, 'startpage.com'),
    template: (_) => 'https://www.startpage.com/do/search?q=%s',
  ),
  KnownSearchHost(
    name: 'Bing',
    home: 'https://www.bing.com/',
    kind: SearchKind.web,
    siteOperator: true,
    matches: (h) => h == 'bing.com' || h == 'www.bing.com',
    template: (_) => 'https://www.bing.com/search?q=%s',
  ),
  KnownSearchHost(
    name: 'Mojeek',
    home: 'https://www.mojeek.com/',
    kind: SearchKind.web,
    siteOperator: true,
    matches: (h) => _isOrUnder(h, 'mojeek.com'),
    template: (_) => 'https://www.mojeek.com/search?q=%s',
  ),
  KnownSearchHost(
    name: 'Ecosia',
    home: 'https://www.ecosia.org/',
    kind: SearchKind.web,
    siteOperator: true,
    matches: (h) => _isOrUnder(h, 'ecosia.org'),
    template: (_) => 'https://www.ecosia.org/search?q=%s',
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
    matches: (h) => _isOrUnder(h, 'youtube.com'),
    template: (_) => 'https://www.youtube.com/results?search_query=%s',
  ),
  KnownSearchHost(
    name: 'Reddit',
    home: 'https://www.reddit.com/',
    kind: SearchKind.site,
    siteOperator: false,
    matches: (h) => _isOrUnder(h, 'reddit.com'),
    template: (_) => 'https://www.reddit.com/search/?q=%s',
  ),
  KnownSearchHost(
    name: 'Stack Overflow',
    home: 'https://stackoverflow.com/',
    kind: SearchKind.site,
    siteOperator: false,
    matches: (h) => _isOrUnder(h, 'stackoverflow.com'),
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
  static Uri? buildUrl(String template, String query) {
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
  static String scopedQuery(String host, String query) =>
      'site:$host ${query.trim()}';

  static KnownSearchHost? knownFor(String initUrl) {
    final host = Uri.tryParse(initUrl)?.host.toLowerCase() ?? '';
    if (host.isEmpty) return null;
    for (final k in kKnownSearchHosts) {
      if (k.matches(host)) return k;
    }
    return null;
  }

  /// How a site searches: its own address when it has one, else what its
  /// host is known for, else not at all. A custom address that searches the
  /// web is assumed to honour `site:`, as SearXNG and the big engines do.
  static SearchCapability? capabilityOf({
    required String initUrl,
    String? searchAddress,
    bool searchesWeb = false,
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
    if (known == null) return null;
    final host = Uri.parse(initUrl).host.toLowerCase();
    return SearchCapability(
      template: known.template(host),
      kind: known.kind,
      siteOperator: known.siteOperator,
    );
  }

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

  /// The URL [option] searches [query] with, or null.
  static Uri? urlFor(SearchOption option, String query, {String? scopeHost}) {
    final template = option.site.capability?.template;
    if (template == null) return null;
    final q = option.scoped && scopeHost != null
        ? scopedQuery(scopeHost, query)
        : query;
    return buildUrl(template, q);
  }

  /// Where a search by [searchSiteId] lands, from a slot owned by
  /// [ownerSiteId] and running as [identitySiteId].
  static SearchLanding land({
    required String searchSiteId,
    required String ownerSiteId,
    required String identitySiteId,
    required bool tabsEnabled,
    required bool canHost,
    required bool urlInSearchSiteDomain,
  }) {
    if (searchSiteId == identitySiteId) {
      return tabsEnabled ? SearchLanding.childTab : SearchLanding.inPlace;
    }
    if (searchSiteId == ownerSiteId) {
      return tabsEnabled ? SearchLanding.childTab : SearchLanding.inSearchSite;
    }
    if (tabsEnabled && canHost && urlInSearchSiteDomain) {
      return SearchLanding.hostedChildTab;
    }
    return SearchLanding.inSearchSite;
  }

  /// Whether [url] is inside [initUrl]'s navigation domain, which a hosted
  /// tab's URL must be (LIR-018).
  static bool inDomainOf(Uri url, String initUrl) =>
      getNormalizedDomain(url.toString()) == getNormalizedDomain(initUrl);

  static Uri? _parse(String s) {
    final uri = Uri.tryParse(s);
    if (uri == null) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    if (uri.host.isEmpty) return null;
    return uri;
  }
}
