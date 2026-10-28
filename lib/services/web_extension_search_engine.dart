/// A search of addons.mozilla.org, and whether WebKit is expected to run
/// each extension it finds (WEBEXT-019).
///
/// The reply is untrusted JSON, read by patterns: a wrong-typed field reads
/// as absent.
library;

import 'package:webspace/services/web_extension_grants_engine.dart'
    show grantablePermissions;
import 'package:webspace/settings/web_extension_source.dart';

const _host = 'addons.mozilla.org';
const _app = 'firefox';
const _locale = 'en-US';

/// The request for [page], from 1, of the extensions listed for Firefox
/// that match [text], the most used first.
Uri amoSearchQuery(
  String text, {
  required bool recommendedOnly,
  required int page,
}) {
  final q = text.trim();
  assert(q.isNotEmpty, 'a search names what it looks for');
  assert(page >= 1, 'pages count from 1: $page');
  return Uri.https(_host, '/api/v5/addons/search/', {
    'q': q,
    'type': 'extension',
    'app': _app,
    'sort': 'users',
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
  final api = permissions.where((p) => p != '<all_urls>' && !p.contains('://'));
  return api.every(grantablePermissions.contains)
      ? WebKitFit.works
      : WebKitFit.partly;
}

/// An extension a search found.
final class AmoResult {
  AmoResult._({
    required this.source,
    required this.name,
    required this.summary,
    required this.users,
    required this.recommended,
    required this.fit,
    required this.listing,
  }) : assert(listing.isScheme('https'), 'a listing opens over https');

  /// Where it is added from, as a link to its listing adds it (WEBEXT-017).
  final AmoSource source;
  final String name;

  /// Empty where the listing has none.
  final String summary;

  /// How many use it on an average day, where the listing says.
  final int? users;

  /// Whether Mozilla recommends it for Firefox.
  final bool recommended;
  final WebKitFit fit;
  final Uri listing;
}

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
    users: switch (addon['average_daily_users']) {
      final int users when users >= 0 => users,
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
    fit: webKitFitOf(permissions: _asked(addon['current_version'])),
    listing: _https(addon['url']) ?? Uri.https(_host, '/$_app/addon/$slug/'),
  );
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
