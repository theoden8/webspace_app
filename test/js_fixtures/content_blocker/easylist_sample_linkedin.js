(function() {
  var ID = '_webspace_content_blocker_style';
  if (!document.getElementById(ID)) {
    var s = document.createElement('style');
    s.id = ID;
    s.textContent = '.advert { display: none !important; } .ad-banner { display: none !important; } .sponsored-content { display: none !important; } div[data-ad-slot] { display: none !important; } a[href*="doubleclick.net"] { display: none !important; } div.article:has(div.adsbygoogle) { display: none !important; } div.feed-item:has(.ad-tag) { display: none !important; } div.fp_probe_proc_remove_attr[data-tracker]:remove-attr(data-tracker) { display: none !important; } div.fp_probe_proc_remove_class.fp_probe_remove_me:remove-class(fp_probe_remove_me) { display: none !important; } .fp_probe_class { display: none !important; } div[fp-probe-attr] { display: none !important; } a[href*="fp.probe.example"] { display: none !important; } div.fp_probe_article:has(div.fp_probe_descendant) { display: none !important; } div.fp_probe_feed:has(.fp_probe_tag) { display: none !important; } .feed-shared-update-v2--ad { display: none !important; } div.feed-shared-update-v2:has(.feed-shared-actor__sub-description) { display: none !important; } .fp_probe_styled_banner { height: 1px !important } div.fp_probe_proc_style:has-text(Sponsored) { outline: 2px solid red !important } .fp_probe_styled_promo { opacity: 0.1 !important } ';
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
  var TEXT_RULES = [{sel:'span.notice',pats:['Sponsored']},{sel:'p.story-body',pats:['Advertisement']},{sel:'div.fp_probe_proc_remove',pats:['REMOVE-ME']},{sel:'div.fp_probe_proc_upward',pats:['LEAF']},{sel:'span.fp_probe_notice',pats:['FpProbeMagicNeedle']},{sel:'div.feed-shared-actor',pats:['Promoted','Sponsored']}];
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
