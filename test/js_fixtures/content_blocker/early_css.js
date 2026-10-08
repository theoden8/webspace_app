(function() {
  var ID = '_webspace_content_blocker_style';
  if (document.getElementById(ID)) return;
  var s = document.createElement('style');
  s.id = ID;
  s.textContent = ".ad-banner { display: none !important; } .sponsored { display: none !important; } #sidebar-ad { display: none !important; } div[data-ad-slot] { display: none !important; } a[href*=\"track.example.com\"] { display: none !important; } ";
  function put() { (document.head || document.documentElement).appendChild(s); }
  if (document.documentElement) { put(); return; }
  new MutationObserver(function(_, o) {
    if (!document.documentElement) return;
    o.disconnect();
    if (!document.getElementById(ID)) put();
  }).observe(document, { childList: true });
})();
