(function() {
  var STYLE_ID = '_webspace_generic_cosmetic_style';

  // Walk the live DOM once. classList carries the canonical token
  // list (no need to split id strings or anything weird), and id is
  // a single string. Limit total entries to avoid pathological pages
  // with millions of unique tokens — the engine's lookup is roughly
  // O(classes + ids), and a runaway scan would freeze the bridge
  // call. 50k is comfortably above any realistic page.
  function scan() {
    var classes = new Set();
    var ids = new Set();
    var nodes = document.querySelectorAll('*');
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i];
      if (n.id) ids.add(n.id);
      var cl = n.classList;
      if (cl && cl.length) {
        for (var j = 0; j < cl.length; j++) classes.add(cl[j]);
      }
      if (classes.size + ids.size > 50000) break;
    }
    return { classes: Array.from(classes), ids: Array.from(ids) };
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

  function fire() {
    if (!window.flutter_inappwebview || !window.flutter_inappwebview.callHandler) return;
    var payload = scan();
    window.flutter_inappwebview.callHandler('genericCosmeticScan', payload)
      .then(function(selectors) { inject(selectors); })
      .catch(function() {});
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', fire);
  } else {
    fire();
  }
})();
