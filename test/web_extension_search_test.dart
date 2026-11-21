import 'dart:convert';

import 'package:flutter/foundation.dart' show listEquals, mapEquals;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/domain_claim.dart';
import 'package:webspace/services/web_extension_grants_engine.dart'
    show ExtensionSite, SiteReach, grantablePermissions, siteReach;
import 'package:webspace/services/web_extension_search_engine.dart';
import 'package:webspace/settings/site_ids.dart';

import 'helpers/amo_search_reply.dart';
import 'helpers/extension_sources.dart';

/// [value] as `jsonDecode` hands a reply over.
Object? _decoded(Object? value) => jsonDecode(jsonEncode(value));

typedef _Query =
    Uri Function(
      String text, {
      required bool recommendedOnly,
      required int page,
      required AmoSort sort,
    });

/// Each row: the text searched for, whether only recommended extensions
/// are asked for, the page, the order, and the query the request carries.
const _queryRows = <(String, String, bool, int, AmoSort, Map<String, String>)>[
  (
    'every listing',
    'adblock',
    false,
    1,
    AmoSort.users,
    {
      'q': 'adblock',
      'type': 'extension',
      'app': 'firefox',
      'sort': 'users',
      'page': '1',
      'page_size': '20',
      'lang': 'en-US',
    },
  ),
  (
    'recommended only',
    'adblock',
    true,
    1,
    AmoSort.users,
    {
      'q': 'adblock',
      'type': 'extension',
      'app': 'firefox',
      'sort': 'users',
      'page': '1',
      'page_size': '20',
      'lang': 'en-US',
      'promoted': 'recommended',
    },
  ),
  (
    'a later page',
    'adblock',
    false,
    3,
    AmoSort.users,
    {
      'q': 'adblock',
      'type': 'extension',
      'app': 'firefox',
      'sort': 'users',
      'page': '3',
      'page_size': '20',
      'lang': 'en-US',
    },
  ),
  (
    'text trimmed, its inner space kept',
    '  ad block\n',
    true,
    2,
    AmoSort.users,
    {
      'q': 'ad block',
      'type': 'extension',
      'app': 'firefox',
      'sort': 'users',
      'page': '2',
      'page_size': '20',
      'lang': 'en-US',
      'promoted': 'recommended',
    },
  ),
  (
    'the best rated first',
    'dark mode',
    false,
    1,
    AmoSort.rating,
    {
      'q': 'dark mode',
      'type': 'extension',
      'app': 'firefox',
      'sort': 'rating',
      'page': '1',
      'page_size': '20',
      'lang': 'en-US',
    },
  ),
  (
    'the most recently updated first',
    'dark mode',
    true,
    1,
    AmoSort.updated,
    {
      'q': 'dark mode',
      'type': 'extension',
      'app': 'firefox',
      'sort': 'updated',
      'page': '1',
      'page_size': '20',
      'lang': 'en-US',
      'promoted': 'recommended',
    },
  ),
];

List<String> _queryMisses(_Query query) => [
  for (final (label, text, recommendedOnly, page, sort, want) in _queryRows)
    if (query(text, recommendedOnly: recommendedOnly, page: page, sort: sort)
        case final uri
        when uri.scheme != 'https' ||
            uri.host != 'addons.mozilla.org' ||
            uri.path != '/api/v5/addons/search/' ||
            !mapEquals(uri.queryParameters, want))
      label,
];

/// Planted mistake: a search that forgets it looks for extensions only.
Uri _forgetsType(
  String text, {
  required bool recommendedOnly,
  required int page,
  required AmoSort sort,
}) {
  final real = amoSearchQuery(
    text,
    recommendedOnly: recommendedOnly,
    page: page,
    sort: sort,
  );
  return real.replace(
    queryParameters: {...real.queryParameters}..remove('type'),
  );
}

typedef _Fit = WebKitFit Function({required Set<String>? permissions});

/// Each row: what a listing says an extension asks for, and its fit.
const _fitRows = <(String, Set<String>?, WebKitFit)>[
  ('nothing listed is unknown', null, WebKitFit.unknown),
  ('nothing asked for works', {}, WebKitFit.works),
  (
    'permissions an extension may hold work',
    {'storage', 'tabs', 'scripting', 'declarativeNetRequest'},
    WebKitFit.works,
  ),
  (
    'host patterns are not permissions',
    {
      'storage',
      '<all_urls>',
      'https://*/*',
      '*://*.youtube.com/*',
      'file://*/*',
      'ws://*/*',
      'https://www.qwant.com/',
    },
    WebKitFit.works,
  ),
  (
    'webRequestBlocking runs in part',
    {'webRequest', 'webRequestBlocking', '<all_urls>'},
    WebKitFit.partly,
  ),
  (
    'native messaging runs in part',
    {'storage', 'nativeMessaging'},
    WebKitFit.partly,
  ),
  (
    'one permission WebKit lacks among many it has',
    {'storage', 'tabs', 'privacy'},
    WebKitFit.partly,
  ),
];

List<String> _fitMisses(_Fit fit) => [
  for (final (label, permissions, want) in _fitRows)
    if (fit(permissions: permissions) != want) label,
];

/// Planted mistake: a host pattern taken for an API permission.
WebKitFit _hostPatternsAsPermissions({required Set<String>? permissions}) =>
    switch (permissions) {
      null => WebKitFit.unknown,
      final asked =>
        asked.every(grantablePermissions.contains)
            ? WebKitFit.works
            : WebKitFit.partly,
    };

/// Planted mistake: a listing that names nothing taken as asking for
/// nothing.
WebKitFit _nothingListedWorks({required Set<String>? permissions}) =>
    webKitFitOf(permissions: permissions ?? const {});

/// What [read] lists, a line per result, then whether more follow.
List<String> _lines(SearchRead read) => switch (read) {
  SearchRefused(:final why) => ['refused ${why.name}'],
  SearchFound(:final results, :final more) => [
    for (final r in results)
      '${r.source.slug} "${r.name}" users=${r.users}'
          '${r.recommended ? ' recommended' : ''} ${r.fit.name} ${r.listing}',
    if (more) 'more',
  ],
};

/// A result shaped like the reply's, its fields replaced by [changes] and
/// those named in [without] left out.
Map<String, Object?> _result(
  Map<String, Object?> changes, {
  Set<String> without = const {},
}) => {
  ...{
    'id': 1,
    'average_daily_users': 100,
    'current_version': {
      'file': {
        'host_permissions': <String>[],
        'optional_permissions': <String>[],
        'permissions': ['storage'],
      },
      'version': '1.0',
    },
    'name': {'en-US': 'Example'},
    'promoted': <Object?>[],
    'slug': 'example',
    'summary': {'en-US': 'Does one thing.'},
    'type': 'extension',
    'url': 'https://addons.mozilla.org/en-US/firefox/addon/example/',
  },
  ...changes,
}..removeWhere((key, _) => without.contains(key));

Object? _reply(List<Object?> results, {Object? next}) =>
    _decoded({'count': results.length, 'next': next, 'results': results});

Object? _withFile(Map<String, Object?> file) => _reply([
  _result({
    'current_version': {'file': file, 'version': '1.0'},
  }),
]);

const _listing = 'https://addons.mozilla.org/en-US/firefox/addon/example/';
const _built = 'https://addons.mozilla.org/firefox/addon/example/';

/// Each row: a reply and the lines it reads as.
final _readRows = <(String, Object?, List<String>)>[
  (
    'the real reply, in its order, partly ones kept',
    _decoded(amoSearchReply),
    [
      'ublock-origin "uBlock Origin" users=11346172 recommended partly '
          'https://addons.mozilla.org/en-US/firefox/addon/ublock-origin/',
      'adblock-plus "Adblock Plus" users=2838520 partly '
          'https://addons.mozilla.org/en-US/firefox/addon/adblock-plus/',
      'sponsorblock "SponsorBlock - Skip Sponsorships on YouTube" '
          'users=815669 recommended works '
          'https://addons.mozilla.org/en-US/firefox/addon/sponsorblock/',
      'qwantcom-for-firefox "Qwant - Search engine & tracker blocker" '
          'users=63704 works '
          'https://addons.mozilla.org/en-US/firefox/addon/qwantcom-for-firefox/',
      'more',
    ],
  ),
  ('a body that did not decode', null, ['refused notJson']),
  ('a list, not an object', _decoded(<Object?>[]), ['refused notJson']),
  ('no results', _decoded({'count': 0}), ['refused noResults']),
  (
    'results not a list',
    _decoded({'results': <String, Object?>{}}),
    ['refused noResults'],
  ),
  ('an empty page', _reply([]), []),
  (
    'a last page',
    _reply([_result({})]),
    ['example "Example" users=100 works $_listing'],
  ),
  (
    'a next that is not a link is the last page',
    _reply([_result({})], next: 2),
    ['example "Example" users=100 works $_listing'],
  ),
  (
    'entries that are not objects are skipped',
    _reply(['example', 3, null, _result({})]),
    ['example "Example" users=100 works $_listing'],
  ),
  (
    'a theme is skipped',
    _reply([
      _result({'type': 'statictheme'}),
    ]),
    [],
  ),
  (
    'a type that is not a string is kept',
    _reply([
      _result({'type': 3}),
    ]),
    ['example "Example" users=100 works $_listing'],
  ),
  (
    'no type is kept',
    _reply([
      _result({}, without: {'type'}),
    ]),
    ['example "Example" users=100 works $_listing'],
  ),
  (
    'no slug is skipped',
    _reply([
      _result({}, without: {'slug'}),
    ]),
    [],
  ),
  (
    'a slug with a slash is skipped',
    _reply([
      _result({'slug': 'a/b'}),
    ]),
    [],
  ),
  (
    'a slug of dots is skipped',
    _reply([
      _result({'slug': '..'}),
    ]),
    [],
  ),
  (
    'a slug not a string is skipped',
    _reply([
      _result({'slug': 7}),
    ]),
    [],
  ),
  (
    'a slug outside ASCII, as AMO has, is skipped',
    _reply([
      _result({'slug': 'pestañas-publicidad-pordede'}),
    ]),
    [],
  ),
  (
    'a name as a string',
    _reply([
      _result({'name': 'Plain'}),
    ]),
    ['example "Plain" users=100 works $_listing'],
  ),
  (
    'a name in English first',
    _reply([
      _result({
        'name': {'de': 'Werbeblocker', 'en-US': 'Ad blocker'},
      }),
    ]),
    ['example "Ad blocker" users=100 works $_listing'],
  ),
  (
    'a name in the listing\'s own locale, as lang sends it',
    _reply([
      _result({
        'name': {
          'de': 'mobile.de Extractor & AdCleaner',
          'en-US': null,
          '_default': 'de',
        },
      }),
    ]),
    ['example "mobile.de Extractor & AdCleaner" users=100 works $_listing'],
  ),
  (
    'a name in any locale',
    _reply([
      _result({
        'name': {'fr': 'Bloqueur'},
      }),
    ]),
    ['example "Bloqueur" users=100 works $_listing'],
  ),
  (
    'a name with no text is the slug, never the locale it names',
    _reply([
      _result({
        'name': {'en-US': null, '_default': 'de'},
      }),
    ]),
    ['example "example" users=100 works $_listing'],
  ),
  (
    'a name that is not text is the slug',
    _reply([
      _result({'name': 3}),
    ]),
    ['example "example" users=100 works $_listing'],
  ),
  (
    'users that are not a number are unknown',
    _reply([
      _result({'average_daily_users': '100'}),
    ]),
    ['example "Example" users=null works $_listing'],
  ),
  (
    'users below zero are unknown',
    _reply([
      _result({'average_daily_users': -1}),
    ]),
    ['example "Example" users=null works $_listing'],
  ),
  (
    'recommended for Firefox',
    _reply([
      _result({
        'promoted': [
          {
            'category': 'recommended',
            'apps': ['firefox'],
          },
        ],
      }),
    ]),
    ['example "Example" users=100 recommended works $_listing'],
  ),
  (
    'recommended only for Android is not',
    _reply([
      _result({
        'promoted': [
          {
            'category': 'recommended',
            'apps': ['android'],
          },
        ],
      }),
    ]),
    ['example "Example" users=100 works $_listing'],
  ),
  (
    'promoted in another category is not recommended',
    _reply([
      _result({
        'promoted': [
          {
            'category': 'spotlight',
            'apps': ['firefox'],
          },
        ],
      }),
    ]),
    ['example "Example" users=100 works $_listing'],
  ),
  (
    'a promotion as an object, not a list, reads as none',
    _reply([
      _result({
        'promoted': {
          'category': 'recommended',
          'apps': ['firefox'],
        },
      }),
    ]),
    ['example "Example" users=100 works $_listing'],
  ),
  (
    'a promotion that is not an object reads as none',
    _reply([
      _result({
        'promoted': ['recommended'],
      }),
    ]),
    ['example "Example" users=100 works $_listing'],
  ),
  (
    'a listing over plain http is built from the slug',
    _reply([
      _result({
        'url': 'http://addons.mozilla.org/en-US/firefox/addon/example/',
      }),
    ]),
    ['example "Example" users=100 works $_built'],
  ),
  (
    'no listing is built from the slug',
    _reply([
      _result({}, without: {'url'}),
    ]),
    ['example "Example" users=100 works $_built'],
  ),
  (
    'no current version is unknown',
    _reply([
      _result({}, without: {'current_version'}),
    ]),
    ['example "Example" users=100 unknown $_listing'],
  ),
  (
    'permission lists that are not lists are unknown',
    _withFile({'permissions': 'storage', 'host_permissions': 1}),
    ['example "Example" users=100 unknown $_listing'],
  ),
  (
    'only host permissions listed',
    _withFile({
      'host_permissions': ['https://*/*'],
    }),
    ['example "Example" users=100 works $_listing'],
  ),
  (
    'entries that are not strings are dropped',
    _withFile({
      'permissions': ['storage', 3, null],
    }),
    ['example "Example" users=100 works $_listing'],
  ),
  (
    'webRequestBlocking is partly, and still listed',
    _withFile({
      'permissions': ['webRequest', 'webRequestBlocking', '<all_urls>'],
    }),
    ['example "Example" users=100 partly $_listing'],
  ),
  (
    'an optional permission WebKit lacks is not asked for',
    _withFile({
      'permissions': ['storage'],
      'optional_permissions': ['nativeMessaging'],
    }),
    ['example "Example" users=100 works $_listing'],
  ),
];

typedef _Reader = SearchRead Function(Object? json);

List<String> _readMisses(_Reader read) => [
  for (final (label, json, want) in _readRows)
    if (!listEquals(_lines(read(json)), want)) label,
];

/// Planted mistake: results WebKit runs only in part hidden.
SearchRead _dropsPartly(Object? json) => switch (readAmoSearch(json)) {
  SearchFound(:final results, :final more) => SearchFound(
    results: [
      for (final r in results)
        if (r.fit != WebKitFit.partly) r,
    ],
    more: more,
  ),
  final SearchRefused refused => refused,
};

AmoResult _one(Map<String, Object?> changes) =>
    (readAmoSearch(_reply([_result(changes)])) as SearchFound).results.single;

const _amo64 = 'https://addons.mozilla.org/user-media/addon_icons/1/1-64.png';
const _amo128 = 'https://addons.mozilla.org/user-media/addon_icons/1/1-128.png';

/// Each row: a description as a listing writes it, and the text its page
/// shows.
const _plainRows = <(String, String, String)>[
  ('paragraphs are lines', '<p>One</p><p>Two</p>', 'One\nTwo'),
  ('emphasis is its text', '<strong>What</strong> it does', 'What it does'),
  (
    'a list keeps its items',
    '<ol><li>One</li><li>Two</li></ol>',
    '• One\n• Two',
  ),
  ('a link is the text it shows', '<a href="https://x.org">x.org</a>', 'x.org'),
  ('entities read back', 'a &amp; b &lt;c&gt; &quot;d&quot;', 'a & b <c> "d"'),
  ('an escaped entity stays escaped', '&amp;lt;', '&lt;'),
  ('blank runs close up', 'Line\n\n\n\nNext', 'Line\n\nNext'),
  ('a break is a line', 'One<br>Two<br/>Three', 'One\nTwo\nThree'),
];

List<String> _plainMisses(String Function(String) plain) => [
  for (final (label, html, want) in _plainRows)
    if (plain(html) != want) label,
];

/// Planted mistake: entities read before the escaped ampersand's turn, so
/// `&amp;lt;` reads twice.
String _decodesTwice(String html) => plainText(html.replaceAll('&amp;', '&'));

/// Planted mistake: markup kept.
String _keepsMarkup(String html) => html.trim();

final _youTube = (
  id: SiteId.parse('youtube')!,
  name: 'YouTube',
  claims: [DomainClaim.baseDomain('youtube.com')],
);
final _gitHub = (
  id: SiteId.parse('github')!,
  name: 'GitHub',
  claims: [DomainClaim.exactHost('github.com')],
);
final _tube = (
  id: SiteId.parse('tube')!,
  name: 'Tube',
  claims: [DomainClaim.baseDomain('tube.com')],
);
final List<ExtensionSite> _sites = [_youTube, _gitHub, _tube];

String _reachLine(SiteReach reach) =>
    '${[for (final s in reach.runsOn) s.name].join(',')}'
    '${reach.everySite ? ' every' : ''}'
    ' | ${reach.unclaimed.join(',')}';

/// Each row: the hosts a listing asks for, and where it runs among
/// [_sites] with the hosts no site claims.
const _reachRows = <(String, Set<String>, String)>[
  (
    "SponsorBlock runs on YouTube, and names its own server as no site's",
    {
      'storage',
      'https://sponsor.ajay.app/*',
      'https://*.youtube.com/*',
      'https://www.youtube-nocookie.com/embed/*',
    },
    'YouTube | sponsor.ajay.app,www.youtube-nocookie.com',
  ),
  (
    'every page runs on every site',
    {'<all_urls>'},
    'YouTube,GitHub,Tube every | ',
  ),
  (
    'a pattern over every host runs on every site',
    {'*://*/*'},
    'YouTube,GitHub,Tube every | ',
  ),
  ('no host runs nowhere', {'storage'}, ' | '),
  (
    "a subdomain of a site's exact host is not that site's",
    {'https://gist.github.com/*'},
    ' | gist.github.com',
  ),
  (
    'a domain covers a site claiming its host',
    {'*://*.github.com/*'},
    'GitHub | ',
  ),
  (
    'a domain on a dot boundary only',
    {'https://*.youtube.com/*'},
    'YouTube | ',
  ),
];

typedef _Reach =
    SiteReach Function(
      Iterable<String> hosts, {
      required List<ExtensionSite> sites,
    });

List<String> _reachMisses(_Reach reach) => [
  for (final (label, hosts, want) in _reachRows)
    if (_reachLine(reach(hosts, sites: _sites)) != want) label,
];

/// Planted mistake: a site matched by the text of its claim, so tube.com
/// takes youtube.com's pages.
SiteReach _matchesByText(
  Iterable<String> hosts, {
  required List<ExtensionSite> sites,
}) {
  final real = siteReach(hosts, sites: sites);
  return (
    runsOn: [
      for (final site in sites)
        if (site.claims.any((c) => hosts.any((h) => h.contains(c.value))) ||
            real.everySite)
          site,
    ],
    everySite: real.everySite,
    unclaimed: real.unclaimed,
  );
}

/// Planted mistake: every site's pattern counted as a host no site claims.
SiteReach _everySiteUnclaimed(
  Iterable<String> hosts, {
  required List<ExtensionSite> sites,
}) {
  final real = siteReach(hosts, sites: sites);
  return (
    runsOn: real.runsOn,
    everySite: real.everySite,
    unclaimed: [...real.unclaimed, if (real.everySite) '*'],
  );
}

void main() {
  group('WEBEXT-019 a search of addons.mozilla.org', () {
    test('every query row asks for what it should', () {
      expect(_queryMisses(amoSearchQuery), isEmpty);
    });

    test('every fit row labels what it should', () {
      expect(_fitMisses(webKitFitOf), isEmpty);
    });

    test('every reply row reads as it should', () {
      expect(_readMisses(readAmoSearch), isEmpty);
    });

    test('a result asking for webRequestBlocking is labelled as running in '
        'part, and is still offered', () {
      final found = readAmoSearch(_decoded(amoSearchReply)) as SearchFound;
      final uBlock = found.results.singleWhere(
        (r) => r.source.slug == 'ublock-origin',
      );
      expect(uBlock.fit, WebKitFit.partly);
    });

    test('a summary is read as a name is, and empty when absent', () {
      String summaryOf(Object? summary) =>
          ((readAmoSearch(
                    _reply([
                      _result({'summary': summary}),
                    ]),
                  )
                  as SearchFound)
              .results
              .single
              .summary);
      expect(summaryOf({'en-US': 'Blocks ads.'}), 'Blocks ads.');
      expect(summaryOf('Blocks ads.'), 'Blocks ads.');
      expect(
        summaryOf({'en-US': null, 'ru': 'Без рекламы', '_default': 'ru'}),
        'Без рекламы',
      );
      expect(summaryOf(null), '');
      expect(summaryOf(['Blocks ads.']), '');
    });
  });

  group('WEBEXT-019 a result names its authors, icon and rating', () {
    test('the larger icon on addons.mozilla.org, and none elsewhere', () {
      expect(
        _one({
          'icons': {'64': _amo64, '128': _amo128},
        }).icon,
        Uri.parse(_amo128),
      );
      expect(
        _one({
          'icons': {'128': 'https://evil.example/icon.png'},
          'icon_url': _amo64,
        }).icon,
        Uri.parse(_amo64),
      );
      expect(
        _one({'icon_url': 'http://addons.mozilla.org/x.png'}).icon,
        isNull,
      );
      expect(_one({}).icon, isNull);
    });

    test('a rating out of range or mistyped reads as none', () {
      expect(
        _one({
          'ratings': {'average': 4.8, 'count': 3256},
        }).rating,
        (average: 4.8, count: 3256),
      );
      expect(
        _one({
          'ratings': {'average': 4, 'count': 1},
        }).rating,
        (average: 4.0, count: 1),
      );
      expect(
        _one({
          'ratings': {'average': 7, 'count': 1},
        }).rating,
        isNull,
      );
      expect(
        _one({
          'ratings': {'average': 4.1, 'count': '3'},
        }).rating,
        isNull,
      );
    });

    test('only named authors are read', () {
      expect(
        _one({
          'authors': [
            {'name': 'Ajay'},
            {'name': ''},
            3,
          ],
        }).authors,
        ['Ajay'],
      );
    });

    test('what is never given leads with blocking requests', () {
      final result = _one({
        'current_version': {
          'file': {
            'permissions': [
              'storage',
              'privacy',
              'identity',
              'webRequestBlocking',
              '<all_urls>',
              'https://*.youtube.com/*',
            ],
          },
        },
      });
      expect(result.refused, ['webRequestBlocking', 'identity', 'privacy']);
      expect(result.hosts, {'<all_urls>', 'https://*.youtube.com/*'});
    });
  });

  group('WEBEXT-019 a listing is read for its page', () {
    test('every field the page shows', () {
      final listing = (readAmoListing(amoAddonReply()) as ListingFound).listing;
      expect(listing.result.name, 'AdNauseam');
      expect(listing.result.authors, ['Daniel C. Howe']);
      expect(listing.result.rating, (average: 4.4, count: 512));
      expect(listing.version, '3.24.2');
      expect(listing.size, 3895342);
      expect(listing.licence, 'GNU General Public License v3.0');
      expect(listing.homepage, Uri.parse('https://adnauseam.io'));
      expect(listing.updated, DateTime.utc(2025, 2, 11, 10, 2, 41));
      expect(listing.description, startsWith('AdNauseam quietly clicks'));
      expect(listing.screenshots, isEmpty);
    });

    test('screenshots elsewhere are dropped, and a link is never the '
        'redirect addons.mozilla.org wraps it in', () {
      final reply = {...amoAddonReply()! as Map<String, Object?>}
        ..['previews'] = [
          {
            'image_url':
                'https://addons.mozilla.org/user-media/previews/full/1/1.png',
          },
          {'image_url': 'https://evil.example/shot.png'},
          {'caption': 'no image'},
        ]
        ..['support_url'] = {
          'url': {'en-US': 'https://support.example'},
          'outgoing': {
            'en-US': 'https://prod.outgoing.prod.webservices.mozgcp.net/v1/x',
          },
        };
      final listing = (readAmoListing(reply) as ListingFound).listing;
      expect(listing.screenshots, [
        Uri.parse(
          'https://addons.mozilla.org/user-media/previews/full/1/1.png',
        ),
      ]);
      expect(listing.support, Uri.parse('https://support.example'));
    });

    test('a reply that is not a listing is refused', () {
      expect(readAmoListing(null), isA<ListingRefused>());
      expect(
        (readAmoListing({'name': 'no slug'}) as ListingRefused).why,
        SearchProblem.noResults,
      );
    });

    test('every description row reads as its page shows it', () {
      expect(_plainMisses(plainText), isEmpty);
    });
  });

  group('WEBEXT-019 where a listing would run among the user\'s sites', () {
    test('every reach row lands where it should', () {
      expect(_reachMisses(siteReach), isEmpty);
    });
  });

  group('WEBEXT-019 planted mistakes are caught', () {
    test('a description read twice misses the escaped entity', () {
      expect(_plainMisses(_decodesTwice), ['an escaped entity stays escaped']);
    });

    test('a description with its markup kept misses rows', () {
      expect(
        _plainMisses(_keepsMarkup),
        containsAll(['paragraphs are lines', 'a list keeps its items']),
      );
    });

    test('a site matched by its claim\'s text misses the dot boundary', () {
      expect(
        _reachMisses(_matchesByText),
        contains('a domain on a dot boundary only'),
      );
    });

    test('every site counted as unclaimed misses the every-site rows', () {
      expect(
        _reachMisses(_everySiteUnclaimed),
        containsAll([
          'every page runs on every site',
          'a pattern over every host runs on every site',
        ]),
      );
    });

    test('a query that forgets type=extension misses every row', () {
      expect(_queryMisses(_forgetsType), hasLength(_queryRows.length));
    });

    test('a fit that takes host patterns for permissions misses a row', () {
      expect(
        _fitMisses(_hostPatternsAsPermissions),
        contains('host patterns are not permissions'),
      );
    });

    test('a fit that reads nothing listed as works misses a row', () {
      expect(
        _fitMisses(_nothingListedWorks),
        contains('nothing listed is unknown'),
      );
    });

    test('a reader that drops partly results misses a row', () {
      expect(
        _readMisses(_dropsPartly),
        containsAll([
          'the real reply, in its order, partly ones kept',
          'webRequestBlocking is partly, and still listed',
        ]),
      );
    });
  });
}
