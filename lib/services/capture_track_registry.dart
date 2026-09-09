/// Shared device-capture track registry for the capture shims (CAM-012 /
/// MIC-012).
///
/// Every shim that can hand the page a **device** track registers it here, and
/// the `__wsStopRealCapture()` hook Dart calls on deactivation ends whatever
/// is in the registry. Tracks a shim substituted are skipped: those are local
/// files the user picked, nothing is being observed, and ending them would
/// drop a half-finished scan or stop playback the user comes back to.
///
/// Why this is shared rather than one copy per shim: the hook lives on
/// `globalThis` under a single name, so the second shim to define its own
/// would silently replace the first and which capture survives a site switch
/// would depend on injection order. The registry and the hook are therefore
/// installed idempotently, and every shim reaches the same one.
///
/// **The state is closed over, and the hook cannot be replaced.** Dart can only
/// call the hook by name, so the name is page-reachable and that much is
/// unavoidable; everything reachable through it is not. The page cannot empty
/// the registry, re-point the hook at a no-op, or launder a device track into
/// the skip list — all three ended a real capture that the app then reported as
/// stopped (MIC-014). Three properties carry that:
///
///   * the hook is installed non-writable and non-configurable, so an
///     assignment or a `delete` cannot displace it;
///   * the track lists live in this closure and no accessor for them escapes,
///     so `__wsRealTracks = []` no longer means anything;
///   * `markSynthetic` refuses a track already registered as a device track.
///     A device track is registered while the `getUserMedia` promise is still
///     resolving, so the page cannot reach one before the registry does, and a
///     page calling this to launder its own capture finds it already real.
///
/// A clone is a live, independently-stoppable track, so a page that clones its
/// device track before deactivation would otherwise keep capturing through the
/// clone. `MediaStreamTrack.clone` and `MediaStream.clone` are wrapped to carry
/// registration onto the copy.
///
/// Dart evaluates in the main frame only, and the capture shims are injected
/// `forMainFrameOnly: false`, so a cross-origin subframe granted a device track
/// keeps a registry of its own that the main frame's hook cannot see. The hook
/// therefore relays the stop down the frame tree. A relay message the page
/// forges only ends capture, never starts it.
///
/// Emits an expression-free block meant to be pasted inside each shim's IIFE,
/// exposing `rememberRealTracks(stream)` and `markSyntheticTrack(track)` in
/// that scope.
String buildRealCaptureRegistry() => '''
  if (typeof globalThis.__wsStopRealCapture !== 'function') {
    (function() {
      var RELAY = '__wsStopRealCapture';
      var real = [];
      var synthetic = new WeakSet();

      // WeakRef where available, so a page that churns streams doesn't pin dead
      // tracks for the document's lifetime.
      function trackRef(t) {
        return typeof WeakRef === 'function'
          ? new WeakRef(t)
          : { deref: function() { return t; } };
      }
      function isReal(t) {
        for (var i = 0; i < real.length; i++) {
          if (real[i].deref() === t) return true;
        }
        return false;
      }
      function addReal(t) {
        if (!t || synthetic.has(t) || isReal(t)) return;
        real.push(trackRef(t));
      }
      function remember(stream) {
        try {
          var tracks = (stream && stream.getTracks) ? stream.getTracks() : [];
          for (var i = 0; i < tracks.length; i++) addReal(tracks[i]);
        } catch (e) {}
        return stream;
      }
      function markSynthetic(track) {
        try { if (track && !isReal(track)) synthetic.add(track); } catch (e) {}
        return track;
      }
      function stopLocal() {
        var stopped = 0;
        for (var i = 0; i < real.length; i++) {
          var t = real[i].deref();
          if (!t) continue;
          try {
            if (t.readyState !== 'ended') { t.stop(); stopped++; }
          } catch (e) {}
        }
        real.length = 0;
        return stopped;
      }
      function relay() {
        try {
          var fs = globalThis.frames;
          var n = fs ? fs.length : 0;
          for (var i = 0; i < n; i++) {
            try { fs[i].postMessage(RELAY, '*'); } catch (e) {}
          }
        } catch (e) {}
      }
      if (typeof globalThis.addEventListener === 'function') {
        globalThis.addEventListener('message', function(e) {
          if (e && e.data === RELAY) { stopLocal(); relay(); }
        });
      }

      // Carry registration onto a clone: stopping the original leaves an
      // independently live copy capturing otherwise.
      function wrapTrackClone() {
        var MST = globalThis.MediaStreamTrack;
        if (!MST || !MST.prototype || typeof MST.prototype.clone !== 'function') return;
        var orig = MST.prototype.clone;
        MST.prototype.clone = asNative(function clone() {
          var out = orig.apply(this, arguments);
          try {
            if (synthetic.has(this)) markSynthetic(out);
            else if (isReal(this)) addReal(out);
          } catch (e) {}
          return out;
        }, 'clone');
      }
      // `MediaStream.clone()` clones each track by the spec's own algorithm,
      // which need not run through the JS-visible track `clone`. Match the
      // copies to the source by kind.
      function wrapStreamClone() {
        var MS = globalThis.MediaStream;
        if (!MS || !MS.prototype || typeof MS.prototype.clone !== 'function') return;
        var orig = MS.prototype.clone;
        MS.prototype.clone = asNative(function clone() {
          var out = orig.apply(this, arguments);
          try {
            var kinds = {};
            var src = this.getTracks();
            for (var i = 0; i < src.length; i++) {
              if (isReal(src[i])) kinds[src[i].kind] = 1;
            }
            var got = out.getTracks();
            for (var j = 0; j < got.length; j++) {
              if (kinds[got[j].kind]) addReal(got[j]);
            }
          } catch (e) {}
          return out;
        }, 'clone');
      }
      try { wrapTrackClone(); } catch (e) {}
      try { wrapStreamClone(); } catch (e) {}

      var hook = asNative(function stopRealCapture() {
        var stopped = stopLocal();
        relay();
        return stopped;
      }, 'stopRealCapture');
      // Non-enumerable siblings so the shim injected after this one reaches the
      // same lists. Both are safe in a page's hands: one only adds tracks to be
      // stopped, the other refuses a device track.
      function hide(name, value) {
        try {
          Object.defineProperty(hook, name, {
            value: value, writable: false, enumerable: false, configurable: false,
          });
        } catch (e) {}
      }
      hide('r', remember);
      hide('s', markSynthetic);
      try {
        Object.defineProperty(globalThis, '__wsStopRealCapture', {
          value: hook,
          writable: false,
          enumerable: false,
          configurable: false,
        });
      } catch (e) {}
    })();
  }

  var _wsCapture = globalThis.__wsStopRealCapture;
  function rememberRealTracks(stream) {
    try { return _wsCapture.r(stream); } catch (e) { return stream; }
  }
  function markSyntheticTrack(track) {
    try { return _wsCapture.s(track); } catch (e) { return track; }
  }
''';
