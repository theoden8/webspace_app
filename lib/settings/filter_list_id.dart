/// A list id names the list's cached files, so an imported backup must not
/// smuggle path metacharacters in one.
final RegExp _kFilterListIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// A content-blocker filter list's identity: a built-in list's fixed name
/// (`easylist`), or `custom_<stamp>` for one the user added. A site's
/// switched-off lists are a set of these.
extension type const FilterListId._(String raw) implements String {
  /// An id the app made or handed out before.
  factory FilterListId(String raw) {
    assert(_kFilterListIdPattern.hasMatch(raw), 'a list id is path-safe: $raw');
    return FilterListId._(raw);
  }

  /// [raw] when it is a path-safe token; null otherwise.
  static FilterListId? parse(Object? raw) =>
      raw is String && _kFilterListIdPattern.hasMatch(raw)
          ? FilterListId._(raw)
          : null;
}
