import 'dart:math';

/// Wide enough for `site_` plus a 128-character siteId, the id of a tile
/// pinned before shortcut ids existed.
final RegExp _kShortcutIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,160}$');

/// An Android home screen tile's own identity (HS-017): fixed when the tile
/// is pinned, while the site it opens can change. A tile pinned before
/// shortcut ids existed keeps `site_<siteId>` of the site it was pinned for.
extension type const ShortcutId._(String raw) implements String {
  /// A fresh id for a tile about to be pinned.
  factory ShortcutId.mint() {
    final now = DateTime.now().microsecondsSinceEpoch;
    final random = Random().nextInt(999999);
    return ShortcutId._(
        'tile_${now.toRadixString(36)}-${random.toRadixString(36)}');
  }

  /// [raw] when it is a token native code could have handed out; null
  /// otherwise.
  static ShortcutId? parse(Object? raw) =>
      raw is String && _kShortcutIdPattern.hasMatch(raw)
          ? ShortcutId._(raw)
          : null;
}
