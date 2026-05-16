// JS shim that does the page-side half of the generic-cosmetic
// pipeline introduced in phase 5 of the adblock-rust integration.
//
// uBO splits its cosmetic ruleset two ways: domain-scoped rules
// (`linkedin.com##.feed-promo`) live with `url_cosmetic_resources`
// and ride the existing content_blocker_shim. Generic rules
// (`##.ad-banner`) are the long tail — tens of thousands of selectors
// in EasyList alone — and would be wasteful to inject blanket-style.
// Instead the engine exposes them via `hidden_class_id_selectors`,
// gated on what classes/ids the loaded page actually uses.
//
// This shim:
//   1. Waits for DOMContentLoaded so the body has been parsed.
//   2. Scans every element for unique class names + ids.
//   3. Sends them across the InAppWebView bridge as JSON.
//   4. Receives back a list of CSS selectors and appends them to a
//      `<style>` tag with `display: none !important`.
//
// The shim is no-op when the bridge handler isn't registered (i.e.
// when the Rust engine isn't active for this site) — caller should
// only inject this when [kUseRustEngineForNetwork] is true and the
// engine loaded.

/// Build the generic-cosmetic scanner JS as a self-contained string.
/// `handlerName` is the JavaScript-bridge handler the Dart side
/// registers via `addJavaScriptHandler` to receive the scan result.
///
/// The shim fires once on DOMContentLoaded, then installs a debounced
/// MutationObserver that picks up classes/ids appearing on new
/// elements OR added to existing ones (className change). Each scan
/// only sends the DELTA — classes/ids we haven't queried before —
/// so a long-lived SPA stays cheap regardless of how much it
/// re-renders. Without this, pages that build their UI in the inline
/// `<script>` at the bottom of `<body>` (every Flutter probe page,
/// every React/Vue/Angular app) end up with all the dynamically-
/// appended elements missing every generic cosmetic rule.
String buildGenericCosmeticScannerShim({String handlerName = 'genericCosmeticScan'}) {
  return '''
(function() {
  var STYLE_ID = '_webspace_generic_cosmetic_style';

  // Dedup what we've already asked the engine about so the
  // observer's re-fires are O(new tokens), not O(DOM size).
  var seenClasses = new Set();
  var seenIds = new Set();

  // Walk the live DOM once and collect the DELTA of class/id tokens
  // since the last scan. classList carries the canonical token list
  // (no need to split id strings or anything weird), and id is a
  // single string. Limit total per-call to avoid pathological pages
  // with millions of unique tokens — the engine's lookup is roughly
  // O(classes + ids), and a runaway scan would freeze the bridge
  // call. 50k is comfortably above any realistic page.
  function scanDelta(root) {
    var classes = [];
    var ids = [];
    var nodes = (root || document).querySelectorAll('*');
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i];
      if (n.id && !seenIds.has(n.id)) {
        seenIds.add(n.id);
        ids.push(n.id);
      }
      var cl = n.classList;
      if (cl && cl.length) {
        for (var j = 0; j < cl.length; j++) {
          var c = cl[j];
          if (!seenClasses.has(c)) {
            seenClasses.add(c);
            classes.push(c);
          }
        }
      }
      if (classes.length + ids.length > 50000) break;
    }
    return { classes: classes, ids: ids };
  }

  function inject(selectors) {
    if (!selectors || selectors.length === 0) return;
    var existing = document.getElementById(STYLE_ID);
    var rules = '';
    for (var i = 0; i < selectors.length; i++) {
      var sel = String(selectors[i]).replace(/\\\\/g, '\\\\\\\\').replace(/'/g, "\\\\'");
      rules += sel + ' { display: none !important; } ';
    }
    if (existing) {
      existing.appendChild(document.createTextNode(rules));
      return;
    }
    var s = document.createElement('style');
    s.id = STYLE_ID;
    s.textContent = rules;
    (document.head || document.documentElement).appendChild(s);
  }

  function query(payload) {
    if (!payload || (payload.classes.length === 0 && payload.ids.length === 0)) return;
    if (!window.flutter_inappwebview || !window.flutter_inappwebview.callHandler) return;
    window.flutter_inappwebview.callHandler('$handlerName', payload)
      .then(function(selectors) { inject(selectors); })
      .catch(function() {});
  }

  function fullScan() {
    query(scanDelta(document));
  }

  // Debounced re-scan triggered by MutationObserver — coalesces a
  // burst of DOM appends (typical of SPA route changes) into one
  // engine roundtrip. 50ms matches the cosmetic-shim observer.
  var pending = false;
  var debounceTimer = null;
  function scheduleRescan() {
    if (pending) return;
    pending = true;
    if (debounceTimer) clearTimeout(debounceTimer);
    debounceTimer = setTimeout(function() {
      pending = false;
      fullScan();
    }, 50);
  }

  function installObserver() {
    if (!document.body) return;
    var obs = new MutationObserver(scheduleRescan);
    obs.observe(document.body, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['class', 'id'],
    });
  }

  function fire() {
    fullScan();
    installObserver();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', fire);
  } else {
    fire();
  }
})();
''';
}
