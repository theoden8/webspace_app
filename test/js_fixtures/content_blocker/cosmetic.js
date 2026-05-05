(function() {
  var ID = '_webspace_content_blocker_style';
  if (!document.getElementById(ID)) {
    var s = document.createElement('style');
    s.id = ID;
    s.textContent = '.ad-banner { display: none !important; } .sponsored { display: none !important; } #sidebar-ad { display: none !important; } div[data-ad-slot] { display: none !important; } a[href*="track.example.com"] { display: none !important; } ';
    (document.head || document.documentElement).appendChild(s);
  }
  var BATCHES = ['.ad-banner, .sponsored, #sidebar-ad, div[data-ad-slot], a[href*="track.example.com"]'];
  var TEXT_RULES = [{sel:'div.article > p',pats:['Sponsored content']}];

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
