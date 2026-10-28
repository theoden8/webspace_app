import 'dart:convert';

import 'package:flutter/foundation.dart' show listEquals, mapEquals;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/web_extension_grants_engine.dart'
    show grantablePermissions;
import 'package:webspace/services/web_extension_search_engine.dart';

import 'helpers/amo_search_reply.dart';

/// [value] as `jsonDecode` hands a reply over.
Object? _decoded(Object? value) => jsonDecode(jsonEncode(value));

typedef _Query =
    Uri Function(
      String text, {
      required bool recommendedOnly,
      required int page,
    });

/// Each row: the text searched for, whether only recommended extensions
/// are asked for, the page, and the query the request carries.
const _queryRows = <(String, String, bool, int, Map<String, String>)>[
  (
    'every listing',
    'adblock',
    false,
    1,
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
];

List<String> _queryMisses(_Query query) => [
  for (final (label, text, recommendedOnly, page, want) in _queryRows)
    if (query(text, recommendedOnly: recommendedOnly, page: page) case final uri
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
}) {
  final real = amoSearchQuery(
    text,
    recommendedOnly: recommendedOnly,
    page: page,
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

  group('WEBEXT-019 planted mistakes are caught', () {
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
