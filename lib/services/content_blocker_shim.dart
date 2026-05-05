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

  // Per-batch try/catch isolates a malformed selector to its own batch.
  // `root` is either `document` (one-shot install sweep) or a freshly
  // added subtree (mutation handler). When it's an Element we also
  // test the root itself — `querySelectorAll` only walks descendants.
  function applyCss(root) {
    var rootIsEl = root.nodeType === 1;
    for (var i = 0; i < BATCHES.length; i++) {
      var b = BATCHES[i];
      try {
        if (rootIsEl && root.matches(b)) root.style.display = 'none';
        var els = root.querySelectorAll(b);
        for (var j = 0; j < els.length; j++) els[j].style.display = 'none';
      } catch(e) {}
    }
  }
  function applyText(root) {
    var rootIsEl = root.nodeType === 1;
    for (var i = 0; i < TEXT_RULES.length; i++) {
      var r = TEXT_RULES[i];
      try {
        if (rootIsEl && root.matches(r.sel)) {
          var t0 = root.textContent || '';
          for (var p0 = 0; p0 < r.pats.length; p0++) {
            if (t0.indexOf(r.pats[p0]) !== -1) { root.style.display = 'none'; break; }
          }
        }
        var els = root.querySelectorAll(r.sel);
        for (var j = 0; j < els.length; j++) {
          var el = els[j];
          var t = el.textContent || '';
          for (var p = 0; p < r.pats.length; p++) {
            if (t.indexOf(r.pats[p]) !== -1) { el.style.display = 'none'; break; }
          }
        }
      } catch(e) {}
    }
  }
  // Skip subtrees inside [contenteditable=true]. Typing in editors
  // generates DOM churn that the cosmetic shim cannot usefully act on
  // and which dominated keystroke wall-clock when the runtime sweep
  // re-queried the whole document.
  function isInsideEditable(el) {
    var n = el;
    while (n && n.nodeType === 1) {
      if (n.isContentEditable === true) return true;
      if (n.getAttribute) {
        var ce = n.getAttribute('contenteditable');
        if (ce === '' || ce === 'true' || ce === 'plaintext-only') return true;
      }
      n = n.parentNode;
    }
    return false;
  }
  function applyBoth(root) {
    if (root.nodeType === 1 && isInsideEditable(root)) return;
    applyCss(root);
    applyText(root);
  }

  // One full-document sweep at install. Subsequent work is scoped to
  // added subtrees only — pre-2026 the runtime sweep re-queried the
  // whole document on every mutation burst, which on a 1.7k-element
  // discussion page with 13.6k EasyList selectors cost seconds per
  // typing pause.
  applyCss(document);
  applyText(document);

  var pending = [];
  var t = null;
  function flush() {
    t = null;
    var roots = pending;
    pending = [];
    for (var i = 0; i < roots.length; i++) {
      if (roots[i].isConnected) applyBoth(roots[i]);
    }
  }
  function startObserving() {
    if (!document.body) {
      document.addEventListener('DOMContentLoaded', startObserving);
      return;
    }
    var obs = new MutationObserver(function(mutations) {
      var added = false;
      for (var m = 0; m < mutations.length; m++) {
        var nodes = mutations[m].addedNodes;
        for (var n = 0; n < nodes.length; n++) {
          var node = nodes[n];
          if (node.nodeType !== 1) continue;
          pending.push(node);
          added = true;
        }
      }
      if (!added) return;
      if (t != null) clearTimeout(t);
      t = setTimeout(flush, 50);
    });
    obs.observe(document.body, { childList: true, subtree: true });
  }
  startObserving();
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
