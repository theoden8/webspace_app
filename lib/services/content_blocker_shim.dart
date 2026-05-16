// Content-blocker JavaScript shims (cosmetic CSS hiding + text-match
// hiding) extracted from ContentBlockerService for testability.
//
// Two outputs:
//   * buildEarlyCssShim — runs at DOCUMENT_START. Inserts a <style>
//     tag with `display: none !important` rules before the page
//     paints, so blocked elements never flash on-screen.
//   * buildCosmeticShim — runs after page load. Same <style> tag,
//     plus a MutationObserver that re-applies hiding when the DOM
//     mutates (SPA frameworks, lazy-rendered ads), plus a
//     text-match pass for elements whose visibility is gated on
//     content rather than CSS selector.
//
// These take pure-Dart inputs (no Flutter imports) so the dumper at
// `tool/dump_shim_js.dart` can register them and the drift check
// keeps the committed fixtures byte-identical to runtime output.

/// A text-based hiding rule. Mirrors `TextHideRule` from
/// `abp_filter_parser.dart` without depending on it (the parser
/// imports flutter/foundation.dart, which the dumper avoids).
typedef ContentBlockerTextRule = ({String selector, List<String> patterns});

/// A uBO `:style()` rule mirror — apply [declarations] to elements
/// matching [selector] instead of `display: none`.
typedef ContentBlockerStyleRule = ({String selector, String declarations});

/// Build the early-injection shim that inserts a CSS `display: none`
/// stylesheet at DOCUMENT_START. Returns `null` when both [selectors]
/// and [styleRules] are empty (caller should skip injection entirely).
String? buildContentBlockerEarlyCssShim({
  required List<String> selectors,
  List<ContentBlockerStyleRule> styleRules = const [],
}) {
  if (selectors.isEmpty && styleRules.isEmpty) return null;
  final cssText = _buildCssText(selectors, styleRules);
  return '''
(function() {
  var ID = '_webspace_content_blocker_style';
  if (document.getElementById(ID)) return;
  var s = document.createElement('style');
  s.id = ID;
  s.textContent = '$cssText';
  (document.head || document.documentElement || document).appendChild(s);
})();
''';
}

/// Build the post-load cosmetic shim — the early CSS `<style>` tag
/// (handles every selector-based hide via the browser's CSS engine,
/// including dynamically-added or class-flipped elements) plus a
/// debounced MutationObserver running text-content rules (CSS can't
/// match on text content, so those need JS). Returns `null` when
/// [selectors], [styleRules], and [textRules] are all empty.
///
/// Equivalence with the previous shape (which also ran a runtime
/// `querySelectorAll` sweep writing inline `style.display = 'none'`
/// for selector matches) is asserted in
/// `test/js/content_blocker_shim_equivalence.test.js` and
/// `test/browser/content_blocker_shim_equivalence.test.js` —
/// computed-style is identical for every selector match the old
/// shape covered.
String? buildContentBlockerCosmeticShim({
  required List<String> selectors,
  required List<ContentBlockerTextRule> textRules,
  List<ContentBlockerStyleRule> styleRules = const [],
}) {
  if (selectors.isEmpty && styleRules.isEmpty && textRules.isEmpty) {
    return null;
  }
  final cssText = _buildCssText(selectors, styleRules);

  final textRulesJs = StringBuffer('[');
  for (var i = 0; i < textRules.length; i++) {
    if (i > 0) textRulesJs.write(',');
    final r = textRules[i];
    final sel = _escapeForJsString(r.selector);
    final pats = r.patterns.map((p) => "'${_escapeForJsString(p)}'").join(',');
    textRulesJs.write("{sel:'$sel',pats:[$pats]}");
  }
  textRulesJs.write(']');

  return '''
(function() {
  var ID = '_webspace_content_blocker_style';
  if (!document.getElementById(ID)) {
    var s = document.createElement('style');
    s.id = ID;
    s.textContent = '$cssText';
    (document.head || document.documentElement).appendChild(s);
  }
  // Selector-based hiding is handled entirely by the early <style>
  // tag above. The browser's CSS engine matches the rules (with
  // !important) against every element, present and future, with no
  // JS work — including elements that LATER gain a matching class or
  // attribute (something the prior runtime querySelectorAll sweep
  // could not catch since it only observed childList mutations).
  // Equivalence asserted via test/js/content_blocker_shim_equivalence.test.js
  // and test/browser/content_blocker_shim_equivalence.test.js.
  //
  // Text-content rules (#?# / :-abp-contains) cannot be expressed in
  // CSS, so they keep a debounced MutationObserver that re-runs the
  // text scan on DOM bursts.
  var TEXT_RULES = $textRulesJs;
  function hideText() {
    for (var i = 0; i < TEXT_RULES.length; i++) {
      var r = TEXT_RULES[i];
      try {
        document.querySelectorAll(r.sel).forEach(function(el) {
          var text = el.textContent || '';
          for (var j = 0; j < r.pats.length; j++) {
            if (text.indexOf(r.pats[j]) !== -1) {
              el.style.display = 'none';
              break;
            }
          }
        });
      } catch(e) {}
    }
  }
  hideText();
  if (TEXT_RULES.length > 0) {
    var t = null;
    var obs = new MutationObserver(function() {
      if (t) clearTimeout(t);
      t = setTimeout(hideText, 50);
    });
    if (document.body) {
      obs.observe(document.body, { childList: true, subtree: true });
    } else {
      document.addEventListener('DOMContentLoaded', function() {
        hideText();
        if (document.body) obs.observe(document.body, { childList: true, subtree: true });
      });
    }
  }
})();
''';
}

String _buildCssText(
  List<String> selectors,
  List<ContentBlockerStyleRule> styleRules,
) {
  final cssRules = StringBuffer();
  for (final s in selectors) {
    final escaped = _escapeForJsString(s);
    cssRules.write('$escaped { display: none !important; } ');
  }
  for (final r in styleRules) {
    final sel = _escapeForJsString(r.selector);
    final decls = _escapeForJsString(r.declarations);
    cssRules.write('$sel { $decls } ');
  }
  return cssRules.toString();
}

String _escapeForJsString(String input) =>
    input.replaceAll('\\', '\\\\').replaceAll("'", "\\'");
