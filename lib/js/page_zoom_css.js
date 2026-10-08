// Per-site page zoom through CSS `zoom`, for the engines that ignore the
// viewport meta (desktop) or where desktop mode owns it. Chromium and
// WebKit 17+ / WPE 2.40+ reflow the layout to fill the window.
(function(){
  var id='__webspace_page_zoom__';
  var css='html{zoom:'+CONFIG.zoomPercent+'% !important;}';
  // @include _zoom_style.js
  // Root `zoom` applied at document start can leave Blink on a blank
  // frame until a layout invalidation lands; force one.
  function relayout(){
    apply();
    try{void document.documentElement.offsetHeight;}catch(e){}
    try{window.dispatchEvent(new Event('resize'));}catch(e){}
  }
  window.addEventListener('DOMContentLoaded',relayout);
  window.addEventListener('load',relayout);
})();
