// Always-on Do Not Track / Global Privacy Control JS shim.
//
// Surfaces every common signal a site (or fingerprinting probe) checks:
//   - navigator.doNotTrack       -> '1'   (current spec, all evergreen browsers)
//   - window.doNotTrack          -> '1'   (legacy Safari / old Firefox)
//   - navigator.msDoNotTrack     -> '1'   (legacy IE / pre-Chromium Edge)
//   - navigator.globalPrivacyControl -> true  (GPC, https://globalprivacycontrol.org)
//   - Navigator.prototype.globalPrivacyControl -> true (so prototype checks pass)
//
// Must be injected at DOCUMENT_START, before any site script reads the
// property — the override sets `configurable: true` so a page can replace
// it (rare) but defines the getter on the prototype to avoid leaking an
// own-property a fingerprinter could look for.

const String _doNotTrackShimSource = '''
(function() {
  try {
    function defineGetter(obj, name, value) {
      try {
        Object.defineProperty(obj, name, {
          configurable: true,
          enumerable: true,
          get: function() { return value; },
        });
      } catch (e) {}
    }
    var NavProto = (typeof Navigator !== 'undefined' && Navigator.prototype)
        ? Navigator.prototype
        : null;
    if (NavProto) {
      defineGetter(NavProto, 'doNotTrack', '1');
      defineGetter(NavProto, 'msDoNotTrack', '1');
      defineGetter(NavProto, 'globalPrivacyControl', true);
    }
    if (typeof window !== 'undefined') {
      defineGetter(window, 'doNotTrack', '1');
    }
  } catch (e) {}
})();
''';

/// JS source that installs the always-on DNT / GPC overrides. Pure-Dart
/// constant so the shim string is reachable from `tool/dump_shim_js.dart`
/// and the drift check.
String buildDoNotTrackShim() => _doNotTrackShimSource;
