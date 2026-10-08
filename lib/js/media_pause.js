// BGAUDIO-009: pause every playing media element in a page.
//
// Evaluated on a site WITHOUT the background-audio toggle when it loses the
// screen. Neither pause stops the media pipeline (it runs independently of
// the JS thread), so without this the site keeps sounding — and keeps the OS
// transport surface up — after the user moved on.
//
// Same-origin iframes are walked too: a player in one is common and
// `evaluateJavascript` reaches only the main frame. Cross-origin frames and
// elements that never entered the DOM (`new Audio(src).play()`) are out of
// reach without a shim injected on every site; that gap is documented in the
// background-audio spec.
(function() {
  var docs = [document];
  try {
    for (var f = 0; f < window.frames.length; f++) {
      try {
        var d = window.frames[f].document;
        if (d) docs.push(d);
      } catch (e) {}
    }
  } catch (e) {}
  for (var i = 0; i < docs.length; i++) {
    try {
      var els = docs[i].querySelectorAll('audio,video');
      for (var j = 0; j < els.length; j++) {
        try {
          if (!els[j].paused) els[j].pause();
        } catch (e) {}
      }
    } catch (e) {}
  }
})();
