/// Media-session bridge shim (BGAUDIO-006, Android only).
///
/// Injected at DOCUMENT_START (all frames) on sites with `backgroundAudioEnabled`.
/// It watches every `<audio>`/`<video>` element plus `navigator.mediaSession`
/// metadata and reports `{playing, title, artist, album, artwork}` to Dart
/// via the `wsMediaSession` handler, coalesced on a short debounce. Dart uses
/// that to raise / refresh / tear down the foreground media notification.
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

  function mediaEls() {
    return Array.prototype.slice.call(document.querySelectorAll('audio,video'));
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

  var lastKey = '';
  function report() {
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
    if (!el || el.__wsMediaAttached) return;
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
