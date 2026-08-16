/// Media-session bridge shim (BGAUDIO-006, Android only).
///
/// Injected at DOCUMENT_START (all frames) on sites with `backgroundAudioEnabled`.
/// It watches every `<audio>`/`<video>` element plus `navigator.mediaSession`
/// metadata and reports `{frame, playing, title, artist, album, artwork}` to
/// Dart via the `wsMediaSession` handler, coalesced on a short debounce. Dart
/// uses that to raise / refresh / tear down the foreground media notification.
///
/// Every frame of the site runs its own copy and they all share one handler,
/// so a report carries the frame token that produced it and a frame with no
/// media of its own stays silent (BGAUDIO-008).
///
/// The reverse direction — a transport control tapped in the notification or
/// on the lockscreen — arrives as `window.__wsMediaControl(action)` from Dart
/// and is applied to the primary media element (which fires the same
/// play/pause events the site itself listens to).
///
/// Pure Dart (no Flutter imports) so the string is reachable from tests.
String buildMediaSessionShim() => r'''
(function() {
  if (window.__wsMediaShim) return;
  window.__wsMediaShim = true;

  // `new Audio(src).play()` never enters the DOM, so querySelectorAll cannot
  // see it. The play() patch below registers those here; entries are dropped
  // once they finish (or get attached), and the list is capped so a page that
  // churns through one-shot elements cannot grow it without bound.
  var detached = [];
  var kMaxDetached = 8;
  function isInDoc(el) {
    return 'isConnected' in el ? el.isConnected : document.contains(el);
  }
  function trackDetached(el) {
    detached = detached.filter(function(e) {
      return e !== el && !isInDoc(e) && !e.ended;
    });
    if (!isInDoc(el)) detached.push(el);
    if (detached.length > kMaxDetached) {
      detached = detached.slice(detached.length - kMaxDetached);
    }
  }
  function mediaEls() {
    var els = Array.prototype.slice.call(
      document.querySelectorAll('audio,video'));
    for (var i = 0; i < detached.length; i++) {
      if (els.indexOf(detached[i]) === -1) els.push(detached[i]);
    }
    return els;
  }
  function anyPlaying() {
    var els = mediaEls();
    for (var i = 0; i < els.length; i++) {
      var e = els[i];
      if (!e.paused && !e.ended && e.currentTime > 0) return true;
    }
    return false;
  }
  function primaryMedia() {
    var els = mediaEls();
    for (var i = 0; i < els.length; i++) {
      if (!els[i].paused && !els[i].ended) return els[i];
    }
    return els[0] || null;
  }

  // Identifies this frame's reports to Dart. Every frame of the site shares
  // one `wsMediaSession` handler, so without it Dart cannot tell the frame
  // that is playing from any of the others.
  var frameId = 'f' + Math.random().toString(36).slice(2) +
                Date.now().toString(36);
  var everHadMedia = false;

  var lastKey = '';
  function report() {
    if (mediaEls().length) everHadMedia = true;
    // An ad / analytics / comments iframe has nothing to say about playback.
    // Letting it report `playing:false` would flip the site's notification to
    // paused moments after the main frame raised it.
    if (!everHadMedia) return;
    var playing = anyPlaying();
    var md = (navigator.mediaSession && navigator.mediaSession.metadata) || null;
    var title = (md && md.title) || document.title || '';
    var artist = (md && md.artist) || '';
    var album = (md && md.album) || '';
    var artwork = '';
    if (md && md.artwork && md.artwork.length) {
      // Largest declared artwork last, by MediaSession convention.
      artwork = md.artwork[md.artwork.length - 1].src ||
                md.artwork[0].src || '';
    }
    var key = playing + '|' + title + '|' + artist + '|' + artwork;
    if (key === lastKey) return;
    lastKey = key;
    try {
      window.flutter_inappwebview.callHandler('wsMediaSession', {
        frame: frameId,
        playing: playing, title: title, artist: artist,
        album: album, artwork: artwork,
      });
    } catch (e) {}
  }

  var timer = null;
  function schedule() {
    if (timer) return;
    timer = setTimeout(function() { timer = null; report(); }, 300);
  }

  function attach(el) {
    if (!el) return;
    trackDetached(el);
    if (el.__wsMediaAttached) return;
    el.__wsMediaAttached = true;
    ['play', 'playing', 'pause', 'ended', 'loadedmetadata', 'emptied']
      .forEach(function(ev) { el.addEventListener(ev, schedule, true); });
  }
  function scan() { mediaEls().forEach(attach); }

  // Catch elements created and played before they land in the DOM.
  try {
    var origPlay = HTMLMediaElement.prototype.play;
    HTMLMediaElement.prototype.play = function() {
      attach(this); schedule();
      return origPlay.apply(this, arguments);
    };
  } catch (e) {}

  function startObserver() {
    var root = document.documentElement || document.body;
    if (!root) return false;
    try {
      new MutationObserver(function() { scan(); schedule(); })
        .observe(root, { childList: true, subtree: true });
    } catch (e) {}
    return true;
  }
  if (!startObserver()) {
    document.addEventListener('DOMContentLoaded', function() {
      startObserver(); scan(); schedule();
    });
  }
  scan();

  // Dart -> page. Driving the media element directly fires the same
  // play/pause the site listens to, so its own MediaSession stays in sync.
  window.__wsMediaControl = function(action) {
    try {
      var el = primaryMedia();
      if (!el) return;
      if (action === 'play') el.play();
      else if (action === 'pause' || action === 'stop') el.pause();
    } catch (e) {}
    schedule();
  };

  // Reconcile periodically: covers `ended` via currentTime, SPA route swaps,
  // and metadata set after the first report.
  setInterval(schedule, 3000);
})();
''';
