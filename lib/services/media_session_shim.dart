/// Media-session bridge shim (BGAUDIO-006).
///
/// Injected at DOCUMENT_START (all frames) on sites with
/// `backgroundAudioEnabled`, on every platform with a native media session
/// behind the channel (Android's foreground service, iOS's Now Playing info —
/// see `MediaSessionService.isSupported`).
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
    // Remembered so the background watchdog can tell "the page stopped this
    // while we were not looking" from "this never played".
    el.addEventListener('playing', function() { el.__wsWasPlaying = true; }, true);
    el.addEventListener('ended', function() { el.__wsWasPlaying = false; }, true);
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

  // A transport control that reaches nothing is silent otherwise: the page
  // looks idle, the OS controls stay up, and no log says whether the element
  // was missing or the engine refused to start playback (WebKit rejects
  // play() with NotAllowedError in cases the user experiences as "I hit play
  // and nothing happened"). Reported only on failure, so the ordinary
  // playing/paused report sequence is unchanged.
  function reportControl(action, error) {
    try {
      window.flutter_inappwebview.callHandler('wsMediaSession', {
        frame: frameId, control: action, error: error,
      });
    } catch (e) {}
  }

  // Dart -> page. Driving the media element directly fires the same
  // play/pause the site listens to, so its own MediaSession stays in sync.
  window.__wsMediaControl = function(action) {
    try {
      var el = primaryMedia();
      if (!el) {
        reportControl(action, 'no-media-element');
        return;
      }
      if (action === 'play') {
        var p = el.play();
        if (p && p.catch) {
          p.catch(function(e) {
            reportControl('play', (e && e.name) || 'unknown');
          });
        }
      } else if (action === 'pause' || action === 'stop') {
        // The user asked for silence: the watchdog must not fight it.
        var all = mediaEls();
        for (var i = 0; i < all.length; i++) all[i].__wsWasPlaying = false;
        el.pause();
      }
    } catch (e) {
      reportControl(action, (e && e.name) || 'unknown');
    }
    schedule();
  };

  // BGAUDIO-012: keeping the app alive is not enough for a site that stops
  // itself. A backgrounded app's page is told it is hidden, and players built
  // for a tab (YouTube among them) pause on `visibilitychange` / `pagehide` by
  // their own choice. While the app is backgrounded with this site's toggle on,
  // report the page as visible, swallow those events before the page's own
  // handlers see them, and re-issue play() if something paused anyway.
  var bgActive = false;
  var resumeTries = 0;
  var watchTimer = null;

  function realGetter(name) {
    var d = Object.getOwnPropertyDescriptor(Document.prototype, name);
    return d && d.get ? d.get : null;
  }
  function maskVisibility() {
    ['hidden', 'webkitHidden'].forEach(function(name) {
      var real = realGetter(name);
      try {
        Object.defineProperty(document, name, {
          configurable: true,
          get: function() {
            if (bgActive) return false;
            return real ? real.call(document) : false;
          },
        });
      } catch (e) {}
    });
    ['visibilityState', 'webkitVisibilityState'].forEach(function(name) {
      var real = realGetter(name);
      try {
        Object.defineProperty(document, name, {
          configurable: true,
          get: function() {
            if (bgActive) return 'visible';
            return real ? real.call(document) : 'visible';
          },
        });
      } catch (e) {}
    });
  }
  maskVisibility();

  // Capture phase on window runs before anything the page registers on
  // document or window, so its own pause-on-hide handler never runs.
  ['visibilitychange', 'webkitvisibilitychange', 'pagehide', 'freeze', 'blur']
    .forEach(function(type) {
      var swallow = function(e) {
        if (!bgActive) return;
        e.stopImmediatePropagation();
      };
      try { window.addEventListener(type, swallow, true); } catch (e) {}
      try { document.addEventListener(type, swallow, true); } catch (e) {}
    });

  function watchdog() {
    if (!bgActive) return;
    var els = mediaEls();
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      if (!el.__wsWasPlaying || !el.paused || el.ended) continue;
      if (resumeTries >= 8) continue;
      resumeTries++;
      try {
        var p = el.play();
        if (p && p.catch) {
          p.catch(function(e) {
            reportControl('background-resume', (e && e.name) || 'unknown');
          });
        }
      } catch (e) {
        reportControl('background-resume', (e && e.name) || 'unknown');
      }
    }
  }

  function setBackground(on) {
    on = !!on;
    if (on === bgActive) { relayBackground(on); return; }
    bgActive = on;
    resumeTries = 0;
    if (watchTimer) { clearInterval(watchTimer); watchTimer = null; }
    if (on) watchTimer = setInterval(watchdog, 1000);
    relayBackground(on);
    schedule();
  }

  // `evaluateJavascript` reaches the main frame only, so the state has to be
  // handed down. A frame that fakes this message can only make its own page
  // report itself visible, on a site the user opted into background audio for.
  function relayBackground(on) {
    try {
      for (var i = 0; i < window.frames.length; i++) {
        try {
          window.frames[i].postMessage({ __wsMediaBackground: !!on }, '*');
        } catch (e) {}
      }
    } catch (e) {}
  }
  window.addEventListener('message', function(ev) {
    var d = ev && ev.data;
    if (d && typeof d === 'object' && '__wsMediaBackground' in d) {
      setBackground(d.__wsMediaBackground);
    }
  }, true);

  window.__wsMediaBackground = setBackground;

  // Reconcile periodically: covers `ended` via currentTime, SPA route swaps,
  // and metadata set after the first report.
  setInterval(schedule, 3000);
})();
''';

/// BGAUDIO-009: pause every playing media element in a page.
///
/// Evaluated on a site WITHOUT the background-audio toggle when it loses the
/// screen. Neither pause stops the media pipeline (it runs independently of
/// the JS thread), so without this the site keeps sounding — and keeps the OS
/// transport surface up — after the user moved on.
///
/// Same-origin iframes are walked too: a player in one is common and
/// `evaluateJavascript` reaches only the main frame. Cross-origin frames and
/// elements that never entered the DOM (`new Audio(src).play()`) are out of
/// reach without a shim injected on every site; that gap is documented in the
/// background-audio spec.
String buildMediaPauseJs() => r"""
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
""";
