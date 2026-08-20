// Web half of the adblock engine seam.
//
// The engine is Brave's adblock-rust behind dart:ffi, which the web target
// cannot load at all. Every constructor returns null, exactly as the native
// half does when the shared library is missing for the running arch, so
// callers already handle this state: the content blocker reports "not
// configured" rather than silently passing traffic through unfiltered.
//
// Instance methods are unreachable (no instance can exist) and throw rather
// than answering, so a future call path that assumes an engine fails loudly
// instead of pretending nothing is blocked.

import 'dart:typed_data';

class AdblockEngine {
  AdblockEngine._();

  static AdblockEngine? load(String rulesText, {bool enableUboResources = true}) => null;

  static AdblockEngine? loadFromSerialized(Uint8List bytes,
          {bool enableUboResources = true}) =>
      null;

  static List<Map<String, dynamic>> depLicenses() => const [];

  static String? filterListToAppleContentBlockingJson(String rulesText) => null;

  Never _unavailable() =>
      throw UnsupportedError('the adblock engine is unavailable on web');

  /// Engine library version string, for diagnostics.
  String get version => _unavailable();

  Uint8List? serialize() => _unavailable();

  bool shouldBlock(String url,
          {String sourceUrl = '', String requestType = 'other'}) =>
      _unavailable();

  List<String> hiddenClassIdSelectors(Set<String> classes, Set<String> ids,
          {Set<String> exceptions = const <String>{}}) =>
      _unavailable();

  String? redirectFor(String url,
          {String sourceUrl = '', String requestType = 'other'}) =>
      _unavailable();

  String? rewrittenUrl(String url,
          {String sourceUrl = '', String requestType = 'other'}) =>
      _unavailable();

  String? cspFor(String url,
          {String sourceUrl = '', String requestType = 'other'}) =>
      _unavailable();

  Map<String, dynamic>? cosmeticResources(String url) => _unavailable();

  void dispose() {}
}
