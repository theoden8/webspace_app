(function() {
  var ID = '_webspace_content_blocker_style';
  if (!document.getElementById(ID)) {
    var s = document.createElement('style');
    s.id = ID;
    s.textContent = 'div.post:has(.ad-tag) { display: none !important; } .banner { display: none !important; } ';
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
  var TEXT_RULES = [{sel:'p.notice',pats:['Sponsored','Promoted']},{sel:'article',pats:['Advertisement']}];
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
