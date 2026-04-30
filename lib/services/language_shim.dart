// Per-site language override JavaScript shim.
//
// Sets `navigator.language`, `navigator.languages`, and
// `Intl.DateTimeFormat().resolvedOptions().locale` so client-rendered SPAs
// (React i18n, date formatters) see the per-site language instead of the
// OS locale. The Accept-Language header on the wire is a separate axis;
// these JS surfaces don't follow it. Must be injected at DOCUMENT_START to
// beat the page's own JS read.

import 'dart:convert';

/// Build the language-override shim for [language] (e.g. `'en'`, `'fr-FR'`).
/// Pure-Dart so the shim string is reachable from `tool/dump_shim_js.dart`
/// and the drift check.
String buildLanguageShim(String language) {
  final encoded = jsonEncode(language);
  return '''
(function() {
  try {
    var lang = $encoded;
    var langs = Object.freeze([lang]);
    Object.defineProperty(Navigator.prototype, 'language', {
      configurable: true, get: function() { return lang; }
    });
    Object.defineProperty(Navigator.prototype, 'languages', {
      configurable: true, get: function() { return langs; }
    });
    if (typeof Intl !== 'undefined' && Intl.DateTimeFormat) {
      var proto = Intl.DateTimeFormat.prototype;
      var orig = proto.resolvedOptions;
      proto.resolvedOptions = function() {
        var r = orig.apply(this, arguments);
        r.locale = lang;
        return r;
      };
    }
  } catch (e) {}
})();
''';
}
