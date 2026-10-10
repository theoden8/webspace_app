// Scans the page for classes and ids the generic cosmetic rules may hide. The
// scan result goes to the `genericCosmeticScan` bridge handler the Dart side
// registers via `addJavaScriptHandler`.
//
// The shim fires once on DOMContentLoaded, then installs a debounced
// MutationObserver that picks up classes/ids appearing on new
// elements OR added to existing ones (className change). Each rescan
// walks only what the observer reported and sends only the DELTA —
// classes/ids we haven't queried before — so a long-lived SPA stays
// cheap regardless of how much it re-renders. Without this, pages that build their UI in the inline
// `<script>` at the bottom of `<body>` (every Flutter probe page,
// every React/Vue/Angular app) end up with all the dynamically-
// appended elements missing every generic cosmetic rule.
(function() {
  var STYLE_ID = '_webspace_generic_cosmetic_style';

  // Dedup what we've already asked the engine about so the
  // observer's re-fires are O(new tokens), not O(DOM size).
  var seenClasses = new Set();
  var seenIds = new Set();

  // Collect the DELTA of class/id tokens since the last scan, from
  // [elements] and their descendants. classList carries the canonical
  // token list (no need to split id strings or anything weird), and id
  // is a single string. Limit total per-call to avoid pathological pages
  // with millions of unique tokens — the engine's lookup is roughly
  // O(classes + ids), and a runaway scan would freeze the bridge call.
  // 50k is comfortably above any realistic page.
  function scanDelta(elements, withDescendants) {
    var classes = [];
    var ids = [];
    function take(n) {
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
      return classes.length + ids.length > 50000;
    }
    for (var e = 0; e < elements.length; e++) {
      var el = elements[e];
      if (take(el)) break;
      if (!withDescendants) continue;
      var nodes = el.querySelectorAll('*');
      for (var i = 0; i < nodes.length; i++) {
        if (take(nodes[i])) break;
      }
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
    query(scanDelta([document.documentElement], true));
  }

  // A token can only appear on an element the page inserts or on one whose
  // class or id it changes, and the observer reports exactly those. So a
  // rescan walks the inserted subtrees and the changed elements, not the
  // document: on a page that re-renders as the user types, the full walk
  // cost a pass over every element per keystroke.
  var addedRoots = new Set();
  var changed = new Set();
  var debounceTimer = null;
  function onMutations(records) {
    for (var i = 0; i < records.length; i++) {
      var r = records[i];
      if (r.type === 'attributes') {
        changed.add(r.target);
        continue;
      }
      for (var a = 0; a < r.addedNodes.length; a++) {
        if (r.addedNodes[a].nodeType === 1) addedRoots.add(r.addedNodes[a]);
      }
    }
    if (debounceTimer || (addedRoots.size === 0 && changed.size === 0)) return;
    // Coalesces a burst of DOM appends (typical of SPA route changes) into
    // one engine roundtrip. 50ms matches the cosmetic-shim observer.
    debounceTimer = setTimeout(function() {
      debounceTimer = null;
      var roots = Array.from(addedRoots).filter(function(n) { return n.isConnected; });
      var targets = Array.from(changed).filter(function(n) { return n.isConnected; });
      addedRoots.clear();
      changed.clear();
      var fromRoots = scanDelta(roots, true);
      var fromTargets = scanDelta(targets, false);
      query({
        classes: fromRoots.classes.concat(fromTargets.classes),
        ids: fromRoots.ids.concat(fromTargets.ids),
      });
    }, 50);
  }

  // The whole document, not just body: an element a script appends to
  // <html> beside <body> renders too.
  function installObserver() {
    var obs = new MutationObserver(onMutations);
    obs.observe(document.documentElement, {
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
