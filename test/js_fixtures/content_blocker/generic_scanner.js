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
      var sel = String(selectors[i]).replace(/\\/g, '\\\\').replace(/'/g, "\\'");
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
    window.flutter_inappwebview.callHandler('genericCosmeticScan', payload)
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
