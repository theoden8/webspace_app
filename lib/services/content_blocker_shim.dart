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

/// Build the early-injection shim that inserts a CSS `display: none`
/// stylesheet at DOCUMENT_START. Returns `null` when [selectors] is
/// empty (caller should skip injection entirely).
String? buildContentBlockerEarlyCssShim(List<String> selectors) {
  if (selectors.isEmpty) return null;
  final cssText = _buildCssText(selectors);
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

/// Build the post-load cosmetic shim — the early CSS tag, plus
/// runtime querySelectorAll passes (batched to survive a single bad
/// selector), plus a MutationObserver that re-runs both passes on DOM
/// changes. Returns `null` when both [selectors] and [textRules] are
/// empty.
String? buildContentBlockerCosmeticShim({
  required List<String> selectors,
  required List<ContentBlockerTextRule> textRules,
}) {
  if (selectors.isEmpty && textRules.isEmpty) return null;
  final cssText = _buildCssText(selectors);

  // Batch selectors so a single malformed entry only blocks its
  // batch, not every other selector. 20 per batch matches what
  // ContentBlockerService used historically.
  final escaped = selectors.map(_escapeForJsString).toList();
  final batches = <String>[];
  for (var i = 0; i < escaped.length; i += 20) {
    final end = (i + 20 < escaped.length) ? i + 20 : escaped.length;
    batches.add(escaped.sublist(i, end).join(', '));
  }
  final batchArray = batches.map((b) => "'$b'").join(',');

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
  var BATCHES = [$batchArray];
  var TEXT_RULES = $textRulesJs;
  function hideCSS() {
    for (var i = 0; i < BATCHES.length; i++) {
      try { document.querySelectorAll(BATCHES[i]).forEach(function(el) { el.style.display = 'none'; }); } catch(e) {}
    }
  }
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
  function hide() { hideCSS(); hideText(); }
  hide();
  var t = null;
  var obs = new MutationObserver(function() {
    if (t) clearTimeout(t);
    t = setTimeout(hide, 50);
  });
  if (document.body) {
    obs.observe(document.body, { childList: true, subtree: true });
  } else {
    document.addEventListener('DOMContentLoaded', function() {
      hide();
      if (document.body) obs.observe(document.body, { childList: true, subtree: true });
    });
  }
})();
''';
}

String _buildCssText(List<String> selectors) {
  final cssRules = StringBuffer();
  for (final s in selectors) {
    final escaped = _escapeForJsString(s);
    cssRules.write('$escaped { display: none !important; } ');
  }
  return cssRules.toString();
}

String _escapeForJsString(String input) =>
    input.replaceAll('\\', '\\\\').replaceAll("'", "\\'");
