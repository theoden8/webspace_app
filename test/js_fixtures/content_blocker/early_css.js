(function() {
  var ID = '_webspace_content_blocker_style';
  if (document.getElementById(ID)) return;
  var s = document.createElement('style');
  s.id = ID;
  s.textContent = '.ad-banner { display: none !important; } .sponsored { display: none !important; } #sidebar-ad { display: none !important; } div[data-ad-slot] { display: none !important; } a[href*="track.example.com"] { display: none !important; } ';
  (document.head || document.documentElement || document).appendChild(s);
})();
