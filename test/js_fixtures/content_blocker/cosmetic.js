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
