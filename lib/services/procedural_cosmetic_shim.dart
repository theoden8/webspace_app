// Procedural cosmetic shim runner.
//
// adblock-rust's `UrlSpecificResources.procedural_actions` returns a
// list of JSON strings, each describing one uBO procedural filter:
// a chain of selector operators (`##div.feed-item:has-text(Sponsored)
// :upward(2)`) and a terminal action (default = hide, also `:remove()`,
// `:style(...)`, `:remove-attr(...)`, `:remove-class(...)`).
//
// JSON shape (serde-derived from adblock-rust's
// `ProceduralOrActionFilter`):
//
//   {
//     "selector": [
//       {"type": "css-selector", "arg": ".feed-item"},
//       {"type": "has-text",     "arg": "Sponsored"},
//       {"type": "upward",       "arg": "2"}
//     ],
//     "action": "remove"  // OR omitted for default hide
//                         // OR {"type": "style", "arg": "..."}
//                         // OR {"type": "remove-attr", "arg": "x"}
//                         // OR {"type": "remove-class", "arg": "y"}
//   }
//
// The shim consumes the actions list at DOCUMENT_END and re-runs the
// chain on every DOM mutation that adds nodes — the same debounce
// envelope as `generic_cosmetic_shim`. Operators we DON'T handle
// (`xpath`, `matches-css`, `matches-attr`, etc.) cause the whole rule
// to be skipped silently; the user just sees the hide not fire, never
// a JS error.

import 'dart:convert';

/// Build the page-side JS shim that interprets [proceduralActions] —
/// a list of raw JSON strings from the engine — and applies each rule
/// at DOCUMENT_END + on subsequent DOM mutations.
///
/// Returns `null` when no procedural actions apply (caller skips
/// injection entirely; the shim itself is non-trivial JS).
String? buildProceduralCosmeticShim(List<String> proceduralActions) {
  if (proceduralActions.isEmpty) return null;
  // Pre-emit the rule array as a JS literal so the shim doesn't have
  // to parse JSON-of-JSON at runtime. Each element of `rules` is the
  // already-decoded object the engine produced.
  final decoded = <Map<String, dynamic>>[];
  for (final raw in proceduralActions) {
    try {
      final m = jsonDecode(raw);
      if (m is Map<String, dynamic>) decoded.add(m);
    } catch (_) {/* skip — adblock-rust may emit a shape we don't yet handle */}
  }
  if (decoded.isEmpty) return null;
  final rulesJson = jsonEncode(decoded);
  final rulesJsonEscaped = rulesJson.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
  return '''
(function() {
  var RULES;
  try { RULES = JSON.parse('$rulesJsonEscaped'); } catch (e) { return; }
  if (!RULES || !RULES.length) return;

  // Apply one operator to a candidate element set. Returns the
  // (possibly narrowed) array; or null when the operator isn't
  // supported, which skips the whole rule.
  function applyOp(elements, op) {
    var type = op && op.type;
    var arg = op && op.arg;
    if (type === 'css-selector') {
      // First operator: elements is null → query the whole document.
      // Subsequent css-selector ops: re-query inside each element.
      if (elements === null) {
        try { return Array.from(document.querySelectorAll(arg)); }
        catch (_) { return null; }
      }
      var out = [];
      for (var i = 0; i < elements.length; i++) {
        try {
          var found = elements[i].querySelectorAll(arg);
          for (var j = 0; j < found.length; j++) out.push(found[j]);
        } catch (_) {}
      }
      return out;
    }
    if (type === 'has-text') {
      if (elements === null) return null;
      // arg may be /regex/ or plain text; uBO supports both.
      var re = null;
      if (typeof arg === 'string' && arg.length > 2 &&
          arg.charAt(0) === '/' && arg.charAt(arg.length - 1) === '/') {
        try { re = new RegExp(arg.slice(1, -1)); } catch (_) { return null; }
      }
      return elements.filter(function(el) {
        var t = el.textContent || '';
        return re ? re.test(t) : t.indexOf(arg) >= 0;
      });
    }
    if (type === 'upward') {
      if (elements === null) return null;
      // Numeric arg = walk N parents. String arg = walk until ancestor
      // matches the CSS selector. uBO supports both; the engine's
      // string-typed arg disambiguates by digit check.
      var asInt = parseInt(arg, 10);
      var isInt = !isNaN(asInt) && /^\\d+\$/.test(arg);
      return elements.map(function(el) {
        if (isInt) {
          var p = el;
          for (var n = 0; n < asInt && p; n++) p = p.parentElement;
          return p;
        }
        var cur = el.parentElement;
        while (cur) {
          try { if (cur.matches(arg)) return cur; } catch (_) { return null; }
          cur = cur.parentElement;
        }
        return null;
      }).filter(function(el) { return el != null; });
    }
    if (type === 'min-text-length') {
      if (elements === null) return null;
      var n = parseInt(arg, 10);
      if (isNaN(n)) return null;
      return elements.filter(function(el) {
        return (el.textContent || '').length >= n;
      });
    }
    if (type === 'matches-path') {
      if (elements === null) return null;
      // Engine only includes the rule when the page URL matches, but
      // we still honour the operator here for safety. arg may be a
      // string or /regex/ literal (same as has-text).
      var path = location.pathname + location.search;
      var ok = false;
      if (typeof arg === 'string' && arg.length > 2 &&
          arg.charAt(0) === '/' && arg.charAt(arg.length - 1) === '/') {
        try { ok = new RegExp(arg.slice(1, -1)).test(path); } catch (_) {}
      } else {
        ok = path.indexOf(arg) >= 0;
      }
      return ok ? elements : [];
    }
    // matches-css / matches-css-before / matches-css-after / matches-attr
    // / xpath: unsupported. Drop the rule rather than ship a partial
    // match that might over-block.
    return null;
  }

  function applyAction(el, action) {
    // Default action (no `action` key) = hide.
    if (!action) {
      el.style.setProperty('display', 'none', 'important');
      return;
    }
    if (action === 'remove' || (action && action.type === 'remove')) {
      try { el.remove(); } catch (_) {}
      return;
    }
    if (action && action.type === 'style' && typeof action.arg === 'string') {
      try {
        var cur = el.getAttribute('style') || '';
        el.setAttribute('style', cur + ';' + action.arg);
      } catch (_) {}
      return;
    }
    if (action && action.type === 'remove-attr' &&
        typeof action.arg === 'string') {
      try { el.removeAttribute(action.arg); } catch (_) {}
      return;
    }
    if (action && action.type === 'remove-class' &&
        typeof action.arg === 'string') {
      try { el.classList.remove(action.arg); } catch (_) {}
      return;
    }
  }

  function runRule(rule) {
    var ops = rule.selector;
    if (!ops || !ops.length) return;
    var elements = null;
    for (var i = 0; i < ops.length; i++) {
      elements = applyOp(elements, ops[i]);
      if (elements === null) return;  // unsupported op → skip
      if (elements.length === 0) return;  // narrowed to empty
    }
    for (var k = 0; k < elements.length; k++) {
      applyAction(elements[k], rule.action);
    }
  }

  function runAll() {
    for (var i = 0; i < RULES.length; i++) {
      try { runRule(RULES[i]); } catch (_) {}
    }
  }

  // Debounced re-run on DOM bursts (SPA route changes, infinite
  // scroll). Same envelope the generic cosmetic shim uses so the
  // observer overhead stays predictable.
  var pending = false;
  function schedule() {
    if (pending) return;
    pending = true;
    setTimeout(function() {
      pending = false;
      runAll();
    }, 50);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function() {
      runAll();
      try {
        new MutationObserver(schedule).observe(document.body, {
          childList: true,
          subtree: true,
        });
      } catch (_) {}
    });
  } else {
    runAll();
    try {
      new MutationObserver(schedule).observe(document.body, {
        childList: true,
        subtree: true,
      });
    } catch (_) {}
  }
})();
''';
}
