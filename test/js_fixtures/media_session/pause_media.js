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
