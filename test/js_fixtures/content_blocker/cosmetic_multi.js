(function() {
  var ID = '_webspace_content_blocker_style';
  if (!document.getElementById(ID)) {
    var s = document.createElement('style');
    s.id = ID;
    s.textContent = '.batch1-a { display: none !important; } .batch1-b { display: none !important; } .batch1-c { display: none !important; } .batch1-d { display: none !important; } .batch1-e { display: none !important; } .batch1-f { display: none !important; } .batch1-g { display: none !important; } .batch1-h { display: none !important; } .batch1-i { display: none !important; } .batch1-j { display: none !important; } .batch1-k { display: none !important; } .batch1-l { display: none !important; } .batch1-m { display: none !important; } .batch1-n { display: none !important; } .batch1-o { display: none !important; } .batch1-p { display: none !important; } .batch1-q { display: none !important; } .batch1-r { display: none !important; } .batch1-s { display: none !important; } .batch1-t { display: none !important; } >>>invalid<<< { display: none !important; } .batch2-b { display: none !important; } .batch2-c { display: none !important; } .batch2-d { display: none !important; } .batch2-e { display: none !important; } ';
    (document.head || document.documentElement).appendChild(s);
  }
  var BATCHES = ['.batch1-a, .batch1-b, .batch1-c, .batch1-d, .batch1-e, .batch1-f, .batch1-g, .batch1-h, .batch1-i, .batch1-j, .batch1-k, .batch1-l, .batch1-m, .batch1-n, .batch1-o, .batch1-p, .batch1-q, .batch1-r, .batch1-s, .batch1-t','>>>invalid<<<, .batch2-b, .batch2-c, .batch2-d, .batch2-e'];
  var TEXT_RULES = [{sel:'p.notice',pats:['Promoted','Sponsored']},{sel:'div.bio',pats:['Editor']}];
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
