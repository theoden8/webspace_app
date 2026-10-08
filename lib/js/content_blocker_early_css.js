// Cosmetic filtering before first paint: one <style> tag, inserted at
// DOCUMENT_START, so a blocked element never flashes on screen.
//
// The `onLoadStart` copy can run after commit but before the parser has
// made `<html>`, so the shim waits for the root: a node appended to the
// document itself becomes the root, and the parser then drops the whole
// page (CB-019, BUG-031).
(function() {
  // @include _content_blocker_css.js
  var ID = '_webspace_content_blocker_style';
  if (document.getElementById(ID)) return;
  var s = document.createElement('style');
  s.id = ID;
  s.textContent = contentBlockerCss(CONFIG.selectors, CONFIG.styleRules);
  function put() { (document.head || document.documentElement).appendChild(s); }
  if (document.documentElement) { put(); return; }
  new MutationObserver(function(_, o) {
    if (!document.documentElement) return;
    o.disconnect();
    if (!document.getElementById(ID)) put();
  }).observe(document, { childList: true });
})();
