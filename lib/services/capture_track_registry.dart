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
///     page calling this to launder its own capture finds it already real;
///   * every platform primitive the hook leans on — `WeakRef`,
///     `MediaStreamTrack.prototype.stop`, its `readyState` getter,
///     `MediaStream.prototype.getTracks` — is captured inside the install block
///     and called with `.call()`. These are resolved when the hook RUNS, which
///     is long after page script has, so a bare lookup lets the page neuter the
///     stop from the outside without ever touching the hook: a `WeakRef` whose
///     `deref` returns null empties the registry, and a no-op `stop` makes the
///     hook report a stop it never performed.
///
/// A clone is a live, independently-stoppable track, so a page that clones its
/// device track before deactivation would otherwise keep capturing through the
/// clone. `MediaStreamTrack.clone` and `MediaStream.clone` are wrapped to carry
/// registration onto the copy.
///
/// Dart evaluates in the main frame only, and the capture shims are injected
/// `forMainFrameOnly: false`, so a cross-origin subframe granted a device track
/// keeps a registry of its own that the main frame's hook cannot see. The hook
/// therefore relays the stop down the frame tree, walking children by index
/// rather than through `frames`/`length` — both are `[Replaceable]`, so either
/// one hides every subframe behind a single assignment — and delivering by both
/// a direct hook call and `postMessage`, since each path alone is tamperable
/// from a different side. A relay message the page forges only ends capture,
/// never starts it.
///
/// Emits an expression-free block meant to be pasted inside each shim's IIFE,
/// exposing `rememberRealTracks(stream)` and `markSyntheticTrack(track)` in
/// that scope.
String buildRealCaptureRegistry() => '''
  if (typeof globalThis.__wsStopRealCapture !== 'function') {
    (function() {
      var RELAY = '__wsStopRealCapture';
      var MAX_FRAMES = 1024;
      var real = [];
      var synthetic = new WeakSet();

      // Every primitive the hook leans on is captured HERE, inside the install
      // block at document start, and invoked with `.call()`. Closing the state
      // over this scope is only half the job: left as a bare lookup, each of
      // these is an ordinary writable global that page script replaces to
      // neuter the stop from the outside without touching the hook at all. A
      // `WeakRef` whose `deref` returns null empties the registry; a no-op
      // `MediaStreamTrack.prototype.stop` makes the hook report a stop it
      // never performed; a `MediaStream.prototype.getTracks` returning `[]`
      // means nothing is ever registered, while `getVideoTracks` keeps working
      // for the page. All three run after this block, when the hook is called.
      var WeakRefCtor =
        typeof globalThis.WeakRef === 'function' ? globalThis.WeakRef : null;
      var origIsProtoOf = Object.prototype.isPrototypeOf;
      var MST = globalThis.MediaStreamTrack;
      var MS = globalThis.MediaStream;
      var origTrackStop = (MST && MST.prototype) ? MST.prototype.stop : null;
      var origGetTracks = (MS && MS.prototype) ? MS.prototype.getTracks : null;
      var origReadyState = (function() {
        try {
          var d = (MST && MST.prototype)
            ? Object.getOwnPropertyDescriptor(MST.prototype, 'readyState')
            : null;
          return d ? d.get : null;
        } catch (e) { return null; }
      })();

      function trackRef(t) {
        // WeakRef where available, so a page that churns streams doesn't pin
        // dead tracks for the document's lifetime.
        return WeakRefCtor
          ? new WeakRefCtor(t)
          : { deref: function() { return t; } };
      }
      // The captured originals are only correct for genuine platform objects:
      // invoked on anything else they throw `Illegal invocation`, and a shim's
      // own stand-in stream carries nothing device-backed to hide anyway. Test
      // membership through a captured `isPrototypeOf` rather than `instanceof`,
      // which a page redirects with `Symbol.hasInstance`; a real device track's
      // prototype chain is not page-writable.
      function isPlatform(proto, o) {
        try { return !!proto && !!o && origIsProtoOf.call(proto, o); }
        catch (e) { return false; }
      }
      function tracksOf(stream) {
        if (!stream) return [];
        if (origGetTracks && isPlatform(MS && MS.prototype, stream)) {
          return origGetTracks.call(stream);
        }
        return stream.getTracks ? stream.getTracks() : [];
      }
      function hasEnded(t) {
        try {
          if (origReadyState && isPlatform(MST && MST.prototype, t)) {
            return origReadyState.call(t) === 'ended';
          }
          return t.readyState === 'ended';
        } catch (e) { return false; }
      }
      function endTrack(t) {
        if (origTrackStop && isPlatform(MST && MST.prototype, t)) {
          origTrackStop.call(t);
        } else {
          t.stop();
        }
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
          var tracks = tracksOf(stream);
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
            if (!hasEnded(t)) { endTrack(t); stopped++; }
          } catch (e) {}
        }
        real.length = 0;
        return stopped;
      }
      function relay() {
        // Never `globalThis.frames` or its `length`: both are [Replaceable] on
        // Window, so `window.frames = {length: 0}` — or `window.length = 0`
        // alone — hides every subframe behind one assignment. Indexed access on
        // the WindowProxy is not forgeable: its [[DefineOwnProperty]] rejects
        // array indices, so `window[0]` is always the real child.
        //
        // Both delivery paths are tried for each child, because each one alone
        // is tamperable from a different side: a SAME-ORIGIN child can null its
        // own `postMessage`, and a frame our shim never reached could define a
        // hostile `__wsStopRealCapture`. A cross-origin child can do neither —
        // its `postMessage` resolves to the original built-in and its hook is
        // unreadable. Stopping twice is a no-op, so trying both costs nothing.
        for (var i = 0; i < MAX_FRAMES; i++) {
          var f;
          try { f = globalThis[i]; } catch (e) { break; }
          if (!f) break;
          try {
            var hook = f.__wsStopRealCapture;
            if (typeof hook === 'function') hook();
          } catch (e) {}
          try { f.postMessage(RELAY, '*'); } catch (e) {}
        }
      }
      if (typeof globalThis.addEventListener === 'function') {
        globalThis.addEventListener('message', function(e) {
          if (e && e.data === RELAY) { stopLocal(); relay(); }
        });
      }

      // Carry registration onto a clone: stopping the original leaves an
      // independently live copy capturing otherwise.
      function wrapTrackClone() {
        var origIsProtoOf = Object.prototype.isPrototypeOf;
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
            var src = tracksOf(this);
            for (var i = 0; i < src.length; i++) {
              if (isReal(src[i])) kinds[src[i].kind] = 1;
            }
            var got = tracksOf(out);
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
