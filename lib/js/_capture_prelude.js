// The prelude every capture shim shares (camera_stream.js,
// microphone_stream.js, screen_share.js), included first in the shim's IIFE.
//
// The bridge handler is CONFIG.requestHandler, the constant the Dart side
// registers (CaptureKind.requestHandler), so the two cannot drift apart. It
// leaves the kind's code these names: `md`, `DEVICE_LABEL`, `DEVICE_ID`, `GROUP_ID`,
// `asNative`, `notAllowed`, `fetchDecision`, `_syntheticTracks`,
// `presentSynthetic(track, meta)` (with `meta.release()` freeing the
// stream's source), `overrideTrack(name, wrap)`, `defineOnProto`,
// `patchTarget`, `rememberRealTracks`, and for a device kind `fetchMode`,
// `_servedStream`, `callOrigGum` and `withoutSyntheticDeviceId`.
//
// CONFIG.deviceLabel is what the page reads as the substituted track's
// `label`, and as the published device's.
  var GUARD = '__ws_' + CONFIG.shimGroup + '_shim__';
  if (globalThis[GUARD]) return;
  globalThis[GUARD] = true;

  // `mediaDevices` is window-only; in a worker there is nothing to patch.
  var md = globalThis.navigator && globalThis.navigator.mediaDevices;
  if (!md) return;

  var DEVICE_LABEL = CONFIG.deviceLabel;
  // Stable per-session id. Real implementations rotate these per origin and
  // per session, so a fixed constant would itself be a marker.
  var DEVICE_ID = (function() {
    var b = new Uint8Array(32);
    (globalThis.crypto && globalThis.crypto.getRandomValues)
      ? globalThis.crypto.getRandomValues(b)
      : (function() { for (var i = 0; i < b.length; i++) b[i] = (Math.random() * 256) | 0; })();
    var s = '';
    for (var i = 0; i < b.length; i++) s += ('0' + b[i].toString(16)).slice(-2);
    return s;
  })();
  var GROUP_ID = DEVICE_ID.slice(0, 32);

  // Shared Function.prototype.toString funnel (same WeakMap as the other
  // shims) so every wrapper stringifies as `[native code]`.
  var _origFnToString = Function.prototype.toString;
  var _stubs = globalThis.__wsFnStubs || new WeakMap();
  globalThis.__wsFnStubs = _stubs;
  function asNative(fn, name) {
    try { _stubs.set(fn, 'function ' + name + '() { [native code] }'); } catch (e) {}
    return fn;
  }
  if (!globalThis.__wsFnToStringPatched) {
    globalThis.__wsFnToStringPatched = true;
    var patched = function toString() {
      var stub = _stubs.get(this);
      return stub !== undefined ? stub : _origFnToString.call(this);
    };
    try { _stubs.set(patched, 'function toString() { [native code] }'); } catch (e) {}
    try { Function.prototype.toString = patched; } catch (e) {}
  }

  function notAllowed(message) {
    var err;
    try {
      err = new DOMException(message || 'Permission denied', 'NotAllowedError');
    } catch (e) {
      err = new Error(message || 'Permission denied');
      err.name = 'NotAllowedError';
    }
    return err;
  }

  // Asks Dart for this site's decision: {mode, source?}. The origin the popup
  // names is read from the webview in Dart, never from here (CAM-013).
  //
  // Coalesced: a page that retries in a burst (capture libraries do) must not
  // stack popups. The Dart side also coalesces; doing it here too keeps the
  // extra round trips off the bridge entirely.
  var _decisionInFlight = null;
  function fetchDecision() {
    if (_decisionInFlight) return _decisionInFlight;
    var iaw = globalThis.flutter_inappwebview;
    // No bridge: fail closed. Without the per-site decision there is no way to
    // tell a site the user allowed from one they did not (CAM-009, MIC-010).
    if (!iaw || !iaw.callHandler) return Promise.resolve({ mode: 'block' });
    _decisionInFlight = iaw.callHandler(CONFIG.requestHandler).then(function(res) {
      _decisionInFlight = null;
      if (!res || typeof res !== 'object') return { mode: 'block' };
      return res;
    }, function() {
      _decisionInFlight = null;
      return { mode: 'block' };
    });
    return _decisionInFlight;
  }

  // Substituted track -> what this shim reports for it. A WeakMap so a
  // dropped stream is collectable.
  var _syntheticTracks = new WeakMap();

  // Shared across every capture shim: the tracks any of them substituted, and
  // the DEVICE tracks any of them handed over. A combined audio+video request
  // is served by two shims, so each has to recognise the other's tracks, and
  // the deactivation stop (CAM-012 / MIC-012) has to end the device half of
  // such a stream while leaving the substituted half running.
  // Shared device-capture track registry for the capture shims (CAM-012 /
  // MIC-012).
  //
  // Every shim that can hand the page a **device** track registers it here, and
  // the `__wsStopRealCapture()` hook Dart calls on deactivation ends whatever
  // is in the registry. Tracks a shim substituted are skipped: those are local
  // files the user picked, nothing is being observed, and ending them would
  // drop a half-finished scan or stop playback the user comes back to.
  //
  // Why this is shared rather than one copy per shim: the hook lives on
  // `globalThis` under a single name, so the second shim to define its own
  // would silently replace the first and which capture survives a site switch
  // would depend on injection order. The registry and the hook are therefore
  // installed idempotently, and every shim reaches the same one.
  //
  // **The state is closed over, and the hook cannot be replaced.** Dart can only
  // call the hook by name, so the name is page-reachable and that much is
  // unavoidable; everything reachable through it is not. The page cannot empty
  // the registry, re-point the hook at a no-op, or launder a device track into
  // the skip list — all three ended a real capture that the app then reported as
  // stopped (MIC-014). Three properties carry that:
  //
  //   * the hook is installed non-writable and non-configurable, so an
  //     assignment or a `delete` cannot displace it;
  //   * the track lists live in this closure and no accessor for them escapes,
  //     so `__wsRealTracks = []` no longer means anything;
  //   * `markSynthetic` refuses a track already registered as a device track.
  //     A device track is registered while the `getUserMedia` promise is still
  //     resolving, so the page cannot reach one before the registry does, and a
  //     page calling this to launder its own capture finds it already real;
  //   * every platform primitive the hook leans on — `WeakRef`,
  //     `MediaStreamTrack.prototype.stop`, its `readyState` getter,
  //     `MediaStream.prototype.getTracks` — is captured inside the install block
  //     and called with `.call()`. These are resolved when the hook RUNS, which
  //     is long after page script has, so a bare lookup lets the page neuter the
  //     stop from the outside without ever touching the hook: a `WeakRef` whose
  //     `deref` returns null empties the registry, and a no-op `stop` makes the
  //     hook report a stop it never performed.
  //
  // A clone is a live, independently-stoppable track, so a page that clones its
  // device track before deactivation would otherwise keep capturing through the
  // clone. `MediaStreamTrack.clone` and `MediaStream.clone` are wrapped to carry
  // registration onto the copy.
  //
  // Dart evaluates in the main frame only, and the capture shims are injected
  // `forMainFrameOnly: false`, so a cross-origin subframe granted a device track
  // keeps a registry of its own that the main frame's hook cannot see. The hook
  // therefore relays the stop down the frame tree, walking children by index
  // rather than through `frames`/`length` — both are `[Replaceable]`, so either
  // one hides every subframe behind a single assignment — and delivering by both
  // a direct hook call and `postMessage`, since each path alone is tamperable
  // from a different side. A relay message the page forges only ends capture,
  // never starts it.
  //
  // This block exposes `rememberRealTracks(stream)` and `markSyntheticTrack(track)` in
  // that scope.
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


  // Patch the PROTOTYPE, not the `navigator.mediaDevices` instance. Assigning
  // to the instance leaves the overrides visible in
  // Object.getOwnPropertyNames(navigator.mediaDevices), where a real browser
  // defines them only on MediaDevices.prototype: an own-property leak the
  // repo's lie-detection tier probes for on every shim. Never fall back to
  // Object.prototype: on a platform with no MediaDevices class (or a stubbed
  // mediaDevices that owns its methods) that would install the override
  // globally. Patch the instance there instead.
  var MDCtor = globalThis.MediaDevices;
  var mdProto = (MDCtor && MDCtor.prototype && md instanceof MDCtor)
    ? MDCtor.prototype
    : null;
  var patchTarget = mdProto || md;
  function defineOnProto(name, fn) {
    try {
      var prev = Object.getOwnPropertyDescriptor(patchTarget, name);
      Object.defineProperty(patchTarget, name, {
        value: fn,
        writable: prev ? prev.writable !== false : true,
        enumerable: prev ? prev.enumerable : false,
        configurable: true,
      });
    } catch (e) {}
  }

  // MediaStreamTrack.prototype methods answer for this shim's tracks only;
  // every other track reaches the method they replaced, which may be another
  // shim's. Assigning onto a track instance instead would leave the override
  // in Object.getOwnPropertyNames(track), where a real track has none.
  var trackProto = globalThis.MediaStreamTrack && globalThis.MediaStreamTrack.prototype;
  function overrideTrack(name, wrap) {
    if (!trackProto || typeof trackProto[name] !== 'function') return;
    try { trackProto[name] = asNative(wrap(trackProto[name]), name); } catch (e) {}
  }

  // Registers a substituted track. A clone joins its original (see the clone
  // override below), and `meta.release()` frees the stream's source once
  // every track presenting it has stopped or ended: stopping a clone must not
  // silence the original, any more than it does a device track. A track that
  // ends without stop() releases too, or a page that drops the stream leaks
  // the source for the document's lifetime.
  function presentSynthetic(track, meta) {
    meta.live = (meta.live || []).concat([track]);
    _syntheticTracks.set(track, meta);
    markSyntheticTrack(track);
    try {
      track.addEventListener('ended', function() { stopSynthetic(track); });
    } catch (e) {}
  }
  function stopSynthetic(track) {
    var meta = _syntheticTracks.get(track);
    if (!meta || meta.released) return;
    meta.live = meta.live.filter(function(t) { return t !== track; });
    if (meta.live.length) return;
    meta.released = true;
    meta.release();
  }

  (function patchLabel() {
    var desc = trackProto && Object.getOwnPropertyDescriptor(trackProto, 'label');
    if (!desc || !desc.get) return;
    var origGet = desc.get;
    // Named 'get label' so Function.prototype.toString reports
    // `function get label() { [native code] }`, matching a real accessor.
    var get = asNative(function label() {
      return _syntheticTracks.has(this) ? DEVICE_LABEL : origGet.call(this);
    }, 'get label');
    try {
      Object.defineProperty(trackProto, 'label', {
        get: get,
        set: desc.set,
        enumerable: desc.enumerable,
        configurable: true,
      });
    } catch (e) {}
  })();

  // A clone keeps presenting as the same device, and stays exempt from the
  // deactivation stop; otherwise it would report an empty label and the
  // underlying track's settings, betraying the original.
  overrideTrack('clone', function(orig) {
    return function clone() {
      var copy = orig.apply(this, arguments);
      var meta = _syntheticTracks.get(this);
      if (meta && copy) presentSynthetic(copy, meta);
      return copy;
    };
  });

  overrideTrack('stop', function(orig) {
    return function stop() {
      stopSynthetic(this);
      return orig.call(this);
    };
  });

  overrideTrack('getConstraints', function(orig) {
    return function getConstraints() {
      var meta = _syntheticTracks.get(this);
      return meta && meta.constraints ? meta.constraints : orig.call(this);
    };
  });

