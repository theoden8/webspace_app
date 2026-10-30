/// Where an extension added from a link comes from, kept with its library
/// entry so its updates are read from the same place (WEBEXT-017).
library;

final RegExp _kSourceNamePattern = RegExp(r'^[A-Za-z0-9._-]+$');

bool _isSourceName(String raw) =>
    _kSourceNamePattern.hasMatch(raw) && raw.replaceAll('.', '').isNotEmpty;

/// One path segment of a source's links and API: an addon's slug on
/// addons.mozilla.org, a GitHub owner or repository. It is written into the
/// release query's path, so it is never a dot segment and never needs
/// escaping.
extension type const SourceName._(String raw) implements String {
  factory SourceName(String raw) {
    assert(
      _isSourceName(raw),
      'a source name is letters, digits, dots, dashes and underscores, '
      'not only dots: $raw',
    );
    return SourceName._(raw);
  }

  /// [raw] when it is a source name; null otherwise.
  static SourceName? parse(Object? raw) =>
      raw is String && _isSourceName(raw) ? SourceName._(raw) : null;
}

/// Where an extension's releases are read from.
sealed class ExtensionSource {
  const ExtensionSource();

  Map<String, Object?> toJson();

  /// The source as a person reads it, a link without its scheme.
  String get label;

  /// Null when [json] names no source; a wrong-typed field reads as absent.
  static ExtensionSource? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    return switch (json['from']) {
      _amo => switch (SourceName.parse(json['slug'])) {
        final slug? => AmoSource(slug: slug),
        null => null,
      },
      _gitHub => switch ((
        SourceName.parse(json['owner']),
        SourceName.parse(json['repo']),
      )) {
        (final owner?, final repo?) => GitHubSource(
          owner: owner,
          repo: repo,
          asset: switch (json['asset']) {
            final String asset when asset.isNotEmpty => asset,
            _ => null,
          },
        ),
        _ => null,
      },
      _ => null,
    };
  }
}

const _amo = 'amo';
const _gitHub = 'github';

/// An addon listed on addons.mozilla.org.
final class AmoSource extends ExtensionSource {
  const AmoSource({required this.slug});

  final SourceName slug;

  @override
  Map<String, Object?> toJson() => {'from': _amo, 'slug': slug};

  @override
  String get label => 'addons.mozilla.org/firefox/addon/$slug';
}

/// A GitHub repository's latest release.
final class GitHubSource extends ExtensionSource {
  const GitHubSource({
    required this.owner,
    required this.repo,
    required this.asset,
  }) : assert(asset != '', 'an asset pattern names a file');

  final SourceName owner;
  final SourceName repo;

  /// The name of the asset the user picked with its version as `*`
  /// (`ext-*.crx`), so an update picks the same kind of file; null until
  /// one is picked.
  final String? asset;

  @override
  Map<String, Object?> toJson() => {
    'from': _gitHub,
    'owner': owner,
    'repo': repo,
    'asset': ?asset,
  };

  @override
  String get label => 'github.com/$owner/$repo';
}

final RegExp _kLocalePattern = RegExp(r'^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$');

/// The source [link] names: an addons.mozilla.org listing, with or without
/// its locale, or a GitHub repository, its releases or one of them, read as
/// the repository's latest release. Null for any other link.
ExtensionSource? parseExtensionSource(String link) {
  final uri = Uri.tryParse(link.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      (uri.hasPort && uri.port != 443)) {
    return null;
  }
  final segments = [...uri.pathSegments];
  if (segments.isNotEmpty && segments.last.isEmpty) segments.removeLast();
  if (segments.any((s) => s.isEmpty)) return null;
  return switch (uri.host) {
    'addons.mozilla.org' => _amoListing(segments),
    'github.com' => _gitHubRepository(segments),
    _ => null,
  };
}

ExtensionSource? _amoListing(List<String> segments) {
  final listed = switch (segments) {
    [final app, 'addon', final slug, ...] when _isAmoApp(app) => slug,
    [final locale, final app, 'addon', final slug, ...]
        when _kLocalePattern.hasMatch(locale) && _isAmoApp(app) =>
      slug,
    _ => null,
  };
  return switch (SourceName.parse(listed)) {
    final slug? => AmoSource(slug: slug),
    null => null,
  };
}

bool _isAmoApp(String segment) => segment == 'firefox' || segment == 'android';

ExtensionSource? _gitHubRepository(List<String> segments) => switch (segments) {
  [final owner, final repo] ||
  [final owner, final repo, 'releases'] ||
  [final owner, final repo, 'releases', 'latest'] ||
  [final owner, final repo, 'releases', 'tag', _, ...] => switch ((
    SourceName.parse(owner),
    SourceName.parse(repo),
  )) {
    (final ownerName?, final repoName?) => GitHubSource(
      owner: ownerName,
      repo: repoName,
      asset: null,
    ),
    _ => null,
  },
  _ => null,
};
