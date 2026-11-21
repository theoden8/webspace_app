/// A search of addons.mozilla.org, and whether WebKit is expected to run
/// each extension it finds (WEBEXT-019).
///
/// The reply is untrusted JSON, read by patterns: a wrong-typed field reads
/// as absent.
library;

import 'package:webspace/services/web_extension_grants_engine.dart'
    show refusedPermissions;
import 'package:webspace/settings/web_extension_source.dart';

const _host = 'addons.mozilla.org';
const _app = 'firefox';
const _locale = 'en-US';

/// The order a search lists its results in.
enum AmoSort {
  /// The most used on an average day first.
  users,

  /// The best rated first.
  rating,

  /// The most recently updated first.
  updated,
}

/// The request for [page], from 1, of the extensions listed for Firefox
/// that match [text], in [sort]'s order.
Uri amoSearchQuery(
  String text, {
  required bool recommendedOnly,
  required int page,
  required AmoSort sort,
}) {
  final q = text.trim();
  assert(q.isNotEmpty, 'a search names what it looks for');
  assert(page >= 1, 'pages count from 1: $page');
  return Uri.https(_host, '/api/v5/addons/search/', {
    'q': q,
    'type': 'extension',
    'app': _app,
    'sort': sort.name,
    'page': '$page',
    'page_size': '20',
    'lang': _locale,
    if (recommendedOnly) 'promoted': 'recommended',
  });
}

/// Whether WebKit is expected to run an extension.
enum WebKitFit {
  /// Every API permission it asks for is one an extension may hold here.
  works,

  /// It asks for an API permission an extension may not hold here
  /// (WEBEXT-015), so what needs that permission does not run.
  partly,

  /// Its listing names no permissions.
  unknown,
}

/// The fit of an extension asking for [permissions], API permissions and
/// host patterns together; null when its listing names none.
WebKitFit webKitFitOf({required Set<String>? permissions}) {
  if (permissions == null) return WebKitFit.unknown;
  return refusedPermissions(permissions).isEmpty
      ? WebKitFit.works
      : WebKitFit.partly;
}

/// How a listing's users rated it.
typedef AmoRating = ({double average, int count});

/// An extension a search found.
final class AmoResult {
  AmoResult._({
    required this.source,
    required this.name,
    required this.summary,
    required this.authors,
    required this.icon,
    required this.users,
    required this.rating,
    required this.recommended,
    required this.asked,
    required this.listing,
  }) : assert(listing.isScheme('https'), 'a listing opens over https'),
       assert(
         icon == null || _isAmoMedia(icon),
         'an icon is fetched from addons.mozilla.org only: $icon',
       );

  /// Where it is added from, as a link to its listing adds it (WEBEXT-017).
  final AmoSource source;
  final String name;

  /// Empty where the listing has none.
  final String summary;

  /// Its authors' names, as the listing gives them.
  final List<String> authors;

  /// Its icon on addons.mozilla.org, where the listing names one there.
  final Uri? icon;

  /// How many use it on an average day, where the listing says.
  final int? users;

  /// How its users rated it, where the listing says.
  final AmoRating? rating;

  /// Whether Mozilla recommends it for Firefox.
  final bool recommended;

  /// What its current version asks for as it installs, API permissions and
  /// host patterns together; null when its listing names nothing.
  final Set<String>? asked;
  final Uri listing;

  WebKitFit get fit => webKitFitOf(permissions: asked);

  /// The API permissions it asks for that no extension is given here
  /// (WEBEXT-015), blocking requests first, as the one most extensions miss,
  /// then by name.
  List<String> get refused {
    final names = refusedPermissions(asked ?? const {}).toList()..sort();
    return [if (names.remove(_blocking)) _blocking, ...names];
  }

  /// The host patterns it asks for, `<all_urls>` among them.
  Set<String> get hosts => {
    for (final permission in asked ?? const <String>{})
      if (permission == '<all_urls>' || permission.contains('://')) permission,
  };
}

const _blocking = 'webRequestBlocking';

/// What a search's reply lists.
sealed class SearchRead {
  const SearchRead();
}

final class SearchFound extends SearchRead {
  SearchFound({required List<AmoResult> results, required this.more})
    : results = List.unmodifiable(results);

  /// In the order the reply ranks them, whatever their fit.
  final List<AmoResult> results;

  /// Whether a later page lists more.
  final bool more;
}

final class SearchRefused extends SearchRead {
  const SearchRefused(this.why);
  final SearchProblem why;
}

enum SearchProblem {
  /// The reply is not a JSON object.
  notJson,

  /// The reply holds no list of results.
  noResults,
}

/// [json], the decoded reply to an [amoSearchQuery]. The caller passes null
/// for a body that did not decode.
SearchRead readAmoSearch(Object? json) {
  if (json is! Map<String, Object?>) {
    return const SearchRefused(SearchProblem.notJson);
  }
  final listed = json['results'];
  if (listed is! List<Object?>) {
    return const SearchRefused(SearchProblem.noResults);
  }
  return SearchFound(
    results: [
      for (final entry in listed)
        if (entry case final Map<String, Object?> addon) ?_result(addon),
    ],
    more: json['next'] is String,
  );
}

/// [addon] as a result; null when it has no slug a source can name, or is
/// not an extension.
AmoResult? _result(Map<String, Object?> addon) {
  final slug = SourceName.parse(addon['slug']);
  if (slug == null) return null;
  if (addon['type'] case final String type when type != 'extension') {
    return null;
  }
  return AmoResult._(
    source: AmoSource(slug: slug),
    name: _translated(addon['name']) ?? slug,
    summary: _translated(addon['summary']) ?? '',
    authors: [
      if (addon['authors'] case final List<Object?> authors)
        for (final author in authors)
          if (author case {'name': final String name} when name.isNotEmpty)
            name,
    ],
    icon: _iconOf(addon),
    users: switch (addon['average_daily_users']) {
      final int users when users >= 0 => users,
      _ => null,
    },
    rating: switch (addon['ratings']) {
      {'average': final num average, 'count': final int count}
          when average >= 0 && average <= 5 && count >= 0 =>
        (average: average.toDouble(), count: count),
      _ => null,
    },
    recommended: switch (addon['promoted']) {
      final List<Object?> promotions => promotions.any(
        (p) => switch (p) {
          {'category': 'recommended', 'apps': final List<Object?> apps} =>
            apps.contains(_app),
          _ => false,
        },
      ),
      _ => false,
    },
    asked: _asked(addon['current_version']),
    listing: _https(addon['url']) ?? Uri.https(_host, '/$_app/addon/$slug/'),
  );
}

/// The largest icon [addon] names on addons.mozilla.org, up to 128 pixels.
Uri? _iconOf(Map<String, Object?> addon) {
  final icons = switch (addon['icons']) {
    final Map<String, Object?> sizes => [sizes['128'], sizes['64']],
    _ => const <Object?>[],
  };
  return [
    ...icons,
    addon['icon_url'],
  ].map(_https).nonNulls.where(_isAmoMedia).firstOrNull;
}

bool _isAmoMedia(Uri url) => url.isScheme('https') && url.host == _host;

/// An extension's listing, read for its page before it is added
/// (WEBEXT-019): what a search result says, and the rest of the listing.
final class AmoListing {
  AmoListing._({
    required this.result,
    required this.description,
    required this.screenshots,
    required this.version,
    required this.size,
    required this.updated,
    required this.licence,
    required this.homepage,
    required this.support,
  }) : assert(
         screenshots.every(_isAmoMedia),
         'a screenshot is fetched from addons.mozilla.org only',
       );

  final AmoResult result;

  /// Its description as plain text, its markup dropped; empty where it has
  /// none.
  final String description;

  /// Its screenshots on addons.mozilla.org, in the listing's order.
  final List<Uri> screenshots;

  /// Its current version, and that version's package size in bytes.
  final String? version;
  final int? size;
  final DateTime? updated;

  /// Its licence's name.
  final String? licence;
  final Uri? homepage;
  final Uri? support;
}

/// What a listing's reply holds.
sealed class ListingRead {
  const ListingRead();
}

final class ListingFound extends ListingRead {
  const ListingFound(this.listing);
  final AmoListing listing;
}

final class ListingRefused extends ListingRead {
  const ListingRefused(this.why);
  final SearchProblem why;
}

/// [json], the decoded reply to an addons.mozilla.org source's listing
/// request (`releaseQuery`). The caller passes null for a body that did not decode.
ListingRead readAmoListing(Object? json) {
  if (json is! Map<String, Object?>) {
    return const ListingRefused(SearchProblem.notJson);
  }
  final result = _result(json);
  if (result == null) return const ListingRefused(SearchProblem.noResults);
  final file = switch (json['current_version']) {
    {'file': final Map<String, Object?> file} => file,
    _ => const <String, Object?>{},
  };
  return ListingFound(
    AmoListing._(
      result: result,
      description: plainText(_translated(json['description']) ?? ''),
      screenshots: [
        if (json['previews'] case final List<Object?> previews)
          for (final preview in previews)
            if (preview case {'image_url': final Object? url})
              if (_https(url) case final shot? when _isAmoMedia(shot)) shot,
      ],
      version: switch (json['current_version']) {
        {'version': final String version} when version.isNotEmpty => version,
        _ => null,
      },
      size: switch (file['size']) {
        final int size when size >= 0 => size,
        _ => null,
      },
      updated: switch (json['last_updated']) {
        final String at => DateTime.tryParse(at),
        _ => null,
      },
      licence: switch (json['current_version']) {
        {'license': {'name': final Object? name}} => _translated(name),
        _ => null,
      },
      homepage: _linkOf(json['homepage']),
      support: _linkOf(json['support_url']),
    ),
  );
}

/// A listing's link, the site's own address and never the tracking
/// redirect addons.mozilla.org wraps it in.
Uri? _linkOf(Object? link) => switch (link) {
  {'url': final Object? url} => _https(_translated(url)),
  _ => null,
};

final _tag = RegExp(r'<[^>]*>');
final _breakTag = RegExp(r'<(br\s*/?|/p|/li|/h\d)>', caseSensitive: false);
final _itemTag = RegExp(r'<li[^>]*>', caseSensitive: false);
final _blankRun = RegExp(r'\n{3,}');
const _entities = {
  '&lt;': '<',
  '&gt;': '>',
  '&quot;': '"',
  '&#39;': "'",
  '&#x27;': "'",
  '&nbsp;': ' ',
  '&amp;': '&',
};

/// [html], a listing's description, as text: its markup dropped, a break or
/// an item's end kept as a line, a list item led by a bullet, and the few
/// entities a listing writes read back.
String plainText(String html) {
  var text = html
      .replaceAll(_breakTag, '\n')
      .replaceAll(_itemTag, '• ')
      .replaceAll(_tag, '');
  for (final MapEntry(:key, :value) in _entities.entries) {
    text = text.replaceAll(key, value);
  }
  return text.replaceAll(_blankRun, '\n\n').trim();
}

/// A translated field's text. With `lang` the API sends a map holding the
/// asked locale, or its value null beside the listing's own locale named
/// by `_default`; an older reply, or one without `lang`, a string or every
/// locale.
String? _translated(Object? field) {
  if (field case final String text when text.isNotEmpty) return text;
  if (field is! Map<String, Object?>) return null;
  final texts = {...field}..remove('_default');
  return [
    texts[_locale],
    if (field['_default'] case final String fallback) texts[fallback],
    ...texts.values,
  ].whereType<String>().where((t) => t.isNotEmpty).firstOrNull;
}

/// What the current version's file asks for as it installs, as the release
/// read lists it (WEBEXT-017); null when it lists nothing. Its optional
/// permissions are left out: it runs without them until it asks.
Set<String>? _asked(Object? currentVersion) {
  final file = switch (currentVersion) {
    {'file': final Map<String, Object?> file} => file,
    _ => const <String, Object?>{},
  };
  final lists = [
    file['permissions'],
    file['host_permissions'],
  ].whereType<List<Object?>>();
  return lists.isEmpty
      ? null
      : {for (final list in lists) ...list.whereType<String>()};
}

Uri? _https(Object? url) => switch (url) {
  final String link => switch (Uri.tryParse(link)) {
    final uri? when uri.isScheme('https') && uri.host.isNotEmpty => uri,
    _ => null,
  },
  _ => null,
};
