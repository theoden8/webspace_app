import 'dart:math';

/// A siteId is concatenated into filesystem paths (HTML/import/nav-state cache
/// filenames, native container names) and secure-storage keys, so an imported
/// backup must not smuggle path metacharacters. It never begins with `__`,
/// the prefix of every reserved key that shares its namespace (the app-wide
/// proxy password, the proxy router's shared profile, Tor's app-wide tags), so
/// a backup cannot name a site after one (PWD-008).
final RegExp _kSiteIdPattern = RegExp(r'^(?!__)[A-Za-z0-9_-]{1,128}$');

/// A site's stable identity: the key of its cookies, container, stored state
/// and settings. A value of this type is a path-safe token, made by
/// [SiteId.mint] for a new site, [SiteId.parse] for one read from outside,
/// or [SiteId.new] for one already in hand; it is still a [String] wherever
/// one is expected, but a [String] is never a [SiteId] without saying so.
extension type const SiteId._(String raw) implements String {
  /// An id the app made or handed out before, such as one native code
  /// echoes back.
  factory SiteId(String raw) {
    assert(_kSiteIdPattern.hasMatch(raw), 'a siteId is path-safe: $raw');
    return SiteId._(raw);
  }

  /// A fresh id for a new site.
  factory SiteId.mint() {
    final now = DateTime.now().microsecondsSinceEpoch;
    final random = Random().nextInt(999999);
    return SiteId('${now.toRadixString(36)}-${random.toRadixString(36)}');
  }

  /// [raw] when it is a path-safe token that is no reserved key; null
  /// otherwise (`../` traversal included), so the caller mints a fresh id.
  static SiteId? parse(Object? raw) =>
      raw is String && _kSiteIdPattern.hasMatch(raw) ? SiteId._(raw) : null;
}
