// The OS text size on WebKit, which has no `textZoom` setting:
// `-webkit-text-size-adjust` scales text without resizing images. A site
// that pins it to 100% still wins.
(function(){
  var id='__webspace_text_zoom__';
  var css='html{-webkit-text-size-adjust:'+CONFIG.zoomPercent+'% !important;}';
  // @include _zoom_style.js
})();
