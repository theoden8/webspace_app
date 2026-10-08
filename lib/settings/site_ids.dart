import 'dart:math';

String generateSiteId() {
  final now = DateTime.now().microsecondsSinceEpoch;
  final random = Random().nextInt(999999);
  final id = '${now.toRadixString(36)}-${random.toRadixString(36)}';
  assert(_kSiteIdPattern.hasMatch(id), 'a minted siteId is path-safe');
  return id;
}

/// A siteId is concatenated into filesystem paths (HTML/import/nav-state cache
/// filenames, native container names) and secure-storage keys, so an imported
/// backup must not smuggle path metacharacters. Accept only a path-safe token;
/// anything else (including `../…` traversal) returns null so the caller mints
/// a fresh id.
final RegExp _kSiteIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

String? sanitizedSiteId(Object? raw) {
  if (raw is! String) return null;
  return _kSiteIdPattern.hasMatch(raw) ? raw : null;
}
