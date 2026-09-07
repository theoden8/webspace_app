/// Shared device-capture track registry for the capture shims (CAM-012 /
/// MIC-012).
///
/// Every shim that can hand the page a **device** track registers it here, and
/// the `__wsStopRealCapture()` hook Dart calls on deactivation ends whatever
/// is in the shared registry. Tracks in `globalThis.__wsSyntheticTracks` are
/// skipped: those are local files the user picked, nothing is being observed,
/// and ending them would drop a half-finished scan or stop playback the user
/// comes back to.
///
/// Why this is shared rather than one copy per shim: the hook lives on
/// `globalThis` under a single name, so the second shim to define its own
/// would silently replace the first and which capture survives a site switch
/// would depend on injection order. The registry and the hook are therefore
/// installed idempotently, and both shims append to the same array.
///
/// Emits an expression-free block meant to be pasted inside each shim's IIFE,
/// exposing `rememberRealTracks(stream)` in that scope.
String buildRealCaptureRegistry() => '''
  var _wsSynthetic = globalThis.__wsSyntheticTracks || new WeakSet();
  globalThis.__wsSyntheticTracks = _wsSynthetic;

  // WeakRef where available, so a page that churns streams doesn't pin dead
  // tracks for the document's lifetime.
  var _realTracks = globalThis.__wsRealTracks || [];
  globalThis.__wsRealTracks = _realTracks;
  function trackRef(t) {
    return typeof WeakRef === 'function'
      ? new WeakRef(t)
      : { deref: function() { return t; } };
  }
  function rememberRealTracks(stream) {
    try {
      var tracks = (stream && stream.getTracks) ? stream.getTracks() : [];
      for (var i = 0; i < tracks.length; i++) {
        if (_wsSynthetic.has(tracks[i])) continue;
        _realTracks.push(trackRef(tracks[i]));
      }
    } catch (e) {}
    return stream;
  }

  if (typeof globalThis.__wsStopRealCapture !== 'function') {
    try {
      Object.defineProperty(globalThis, '__wsStopRealCapture', {
        value: function stopRealCapture() {
          var reg = globalThis.__wsRealTracks || [];
          var stopped = 0;
          var live = [];
          for (var i = 0; i < reg.length; i++) {
            var t = reg[i].deref();
            if (!t) continue;
            if (_wsSynthetic.has(t)) { live.push(reg[i]); continue; }
            try {
              if (t.readyState !== 'ended') { t.stop(); stopped++; }
            } catch (e) {}
          }
          reg.length = 0;
          for (var j = 0; j < live.length; j++) reg.push(live[j]);
          return stopped;
        },
        writable: true,
        enumerable: false,
        configurable: true,
      });
    } catch (e) {}
  }
''';
