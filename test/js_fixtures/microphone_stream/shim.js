(function() {
  'use strict';
  if (globalThis.__ws_microphone_stream_shim__) return;
  globalThis.__ws_microphone_stream_shim__ = true;

  // `mediaDevices` is window-only; in a worker there is nothing to patch.
  var md = globalThis.navigator && globalThis.navigator.mediaDevices;
  if (!md) return;

  var DEVICE_LABEL = "Microphone Array";
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
    _decisionInFlight = iaw.callHandler("webMicrophoneRequest").then(function(res) {
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

  // Per spec a device label is only exposed once the page holds a capture
  // permission; flipped the first time this shim serves a stream.
  var _servedStream = false;

  // Reads the site's CURRENT mode without ever prompting. enumerateDevices
  // must not pop a permission dialog (no browser does), but it does need to
  // know whether this site is substituting the device. Cached for the
  // document: the mode only changes from per-site settings, which rebuilds
  // the webview.
  var _modePromise = null;
  function fetchMode() {
    if (_modePromise) return _modePromise;
    var iaw = globalThis.flutter_inappwebview;
    if (!iaw || !iaw.callHandler) return Promise.resolve('block');
    _modePromise = iaw.callHandler("webMicrophoneMode").then(function(m) {
      return typeof m === 'string' ? m : 'block';
    }, function() {
      return 'block';
    });
    return _modePromise;
  }

  var _origGumFn = typeof patchTarget.getUserMedia === 'function'
    ? patchTarget.getUserMedia
    : (md.getUserMedia || null);
  // `this` is the live MediaDevices when called through the prototype; fall
  // back to the captured instance for a detached call.
  function callOrigGum(self, constraints) {
    if (!_origGumFn) return null;
    return _origGumFn.call(self || md, constraints);
  }

  // A page that enumerated while the synthetic device was published may hold
  // its deviceId. Once the site is on the real device, passing that id through
  // would make the platform reject the request as overconstrained, so drop
  // just that constraint from the [key] half and let the OS pick.
  function withoutSyntheticDeviceId(constraints, key) {
    var c = constraints && constraints[key];
    if (!c || c === true || !c.deviceId) return constraints;
    var d = c.deviceId;
    var wanted = typeof d === 'string' ? d : (d.exact || d.ideal);
    if (wanted !== DEVICE_ID) return constraints;
    var half = {};
    for (var k in c) {
      if (k !== 'deviceId' && Object.prototype.hasOwnProperty.call(c, k)) half[k] = c[k];
    }
    var out = {};
    for (var o in constraints) {
      if (Object.prototype.hasOwnProperty.call(constraints, o)) out[o] = constraints[o];
    }
    out[key] = half;
    return out;
  }

  function wantsAudio(constraints) {
    return !!(constraints && constraints.audio);
  }
  function wantsVideo(constraints) {
    return !!(constraints && constraints.video);
  }

  // Shallow copy of `constraints` without the `drop` half.
  function without(constraints, drop) {
    var out = {};
    for (var k in constraints) {
      if (k !== drop && Object.prototype.hasOwnProperty.call(constraints, k)) {
        out[k] = constraints[k];
      }
    }
    return out;
  }

  // Honours ideal/exact/min/max shapes on a numeric audio constraint.
  function pickNumber(spec, fallback) {
    if (typeof spec === 'number') return spec;
    if (spec && typeof spec === 'object') {
      var v = spec.ideal !== undefined ? spec.ideal
            : spec.exact !== undefined ? spec.exact
            : spec.max !== undefined ? spec.max
            : spec.min;
      if (typeof v === 'number') return v;
    }
    return fallback;
  }
  function pickBoolean(spec, fallback) {
    if (typeof spec === 'boolean') return spec;
    if (spec && typeof spec === 'object') {
      var v = spec.ideal !== undefined ? spec.ideal : spec.exact;
      if (typeof v === 'boolean') return v;
    }
    return fallback;
  }
  // A real capture track reports the processing flags it negotiated. Mirror
  // whatever the page asked for, defaulting the way a phone microphone does.
  function requestedAudioOptions(constraints) {
    var a = constraints && constraints.audio;
    if (!a || a === true) a = {};
    return {
      channelCount: Math.max(1, Math.min(2, Math.round(pickNumber(a.channelCount, 1)))),
      echoCancellation: pickBoolean(a.echoCancellation, true),
      autoGainControl: pickBoolean(a.autoGainControl, true),
      noiseSuppression: pickBoolean(a.noiseSuppression, true),
    };
  }

  var AudioCtx = globalThis.AudioContext || globalThis.webkitAudioContext;

  // Decode the `data:` payload without fetch(): a page's connect-src CSP can
  // block `fetch('data:...')`, and XHR on a data URL is inconsistent across
  // engines. atob + Uint8Array is neither.
  function dataUrlToArrayBuffer(dataUrl) {
    var marker = ';base64,';
    var at = dataUrl.indexOf(marker);
    if (at < 0) throw notAllowed('Unsupported audio source');
    var bin = atob(dataUrl.slice(at + marker.length));
    var buf = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
    return buf.buffer;
  }

  function decodeAudio(ctx, arrayBuffer) {
    // Promise form is the modern signature; older WebKit only has the
    // callback form and returns undefined.
    var p;
    try {
      p = ctx.decodeAudioData(arrayBuffer);
    } catch (e) {
      p = null;
    }
    if (p && typeof p.then === 'function') return p;
    return new Promise(function(resolve, reject) {
      ctx.decodeAudioData(arrayBuffer, resolve, function() {
        reject(notAllowed('Could not decode the selected audio'));
      });
    });
  }

  // An AudioContext created without a user gesture can start suspended, which
  // would hand the page a silent track. Resume immediately and, if the engine
  // refuses, again on the first gesture.
  function ensureRunning(ctx) {
    function resume() {
      try {
        var r = ctx.resume();
        if (r && r.catch) r.catch(function() {});
      } catch (e) {}
    }
    resume();
    if (ctx.state !== 'suspended') return;
    var events = ['pointerdown', 'touchstart', 'keydown'];
    var onGesture = function() {
      resume();
      for (var i = 0; i < events.length; i++) {
        try { globalThis.removeEventListener(events[i], onGesture, true); } catch (e) {}
      }
    };
    for (var j = 0; j < events.length; j++) {
      try { globalThis.addEventListener(events[j], onGesture, true); } catch (e) {}
    }
  }

  function virtualAudioStream(source, constraints) {
    if (!source || !source.dataUrl) {
      return Promise.reject(notAllowed('No microphone source selected'));
    }
    if (!AudioCtx) {
      return Promise.reject(notAllowed('Audio capture is unavailable'));
    }
    var opts = requestedAudioOptions(constraints);
    var ctx;
    try {
      ctx = new AudioCtx();
    } catch (e) {
      return Promise.reject(notAllowed('Audio capture is unavailable'));
    }
    return Promise.resolve()
      .then(function() { return decodeAudio(ctx, dataUrlToArrayBuffer(source.dataUrl)); })
      .then(function(buffer) {
        var dest;
        // The channel count is fixed at construction; the option bag form is
        // the only way to ask for mono, which is what a phone mic reports.
        try {
          dest = new globalThis.MediaStreamAudioDestinationNode(ctx, {
            channelCount: opts.channelCount,
          });
        } catch (e) {
          dest = ctx.createMediaStreamDestination();
        }
        var src = ctx.createBufferSource();
        src.buffer = buffer;
        src.loop = true;
        src.connect(dest);
        src.start(0);
        ensureRunning(ctx);

        var stream = dest.stream;
        var track = stream.getAudioTracks()[0];
        if (track) {
          // Engines cap how many AudioContexts a document may hold, so the
          // graph goes with the last track presenting it.
          presentSynthetic(track, {
            sampleRate: ctx.sampleRate,
            channelCount: opts.channelCount,
            echoCancellation: opts.echoCancellation,
            autoGainControl: opts.autoGainControl,
            noiseSuppression: opts.noiseSuppression,
            constraints: (constraints && constraints.audio === true)
              ? {} : ((constraints && constraints.audio) || {}),
            release: function() {
              try { src.stop(); } catch (e) {}
              try { ctx.close(); } catch (e) {}
            },
          });
        }
        return stream;
      })
      .catch(function(err) {
        try { ctx.close(); } catch (e) {}
        throw err;
      });
  }

  // Stops every track in a stream. Used when the other half of a combined
  // audio+video request fails: handing back nothing while an AudioContext
  // keeps running is a leak the page cannot clean up.
  function abandon(stream) {
    if (!stream || !stream.getTracks) return;
    var tracks = stream.getTracks();
    for (var i = 0; i < tracks.length; i++) {
      try { tracks[i].stop(); } catch (e) {}
    }
  }

  overrideTrack('getSettings', function(orig) {
    return function getSettings() {
      var s = orig.call(this) || {};
      var meta = _syntheticTracks.get(this);
      if (!meta) return s;
      s.deviceId = DEVICE_ID;
      s.groupId = GROUP_ID;
      s.sampleRate = meta.sampleRate;
      s.sampleSize = 16;
      s.channelCount = meta.channelCount;
      s.echoCancellation = meta.echoCancellation;
      s.autoGainControl = meta.autoGainControl;
      s.noiseSuppression = meta.noiseSuppression;
      // Reported in seconds; a software capture path lands in this range.
      s.latency = 0.01;
      return s;
    };
  });

  overrideTrack('getCapabilities', function(orig) {
    return function getCapabilities() {
      var meta = _syntheticTracks.get(this);
      if (!meta) return orig.call(this);
      return {
        deviceId: DEVICE_ID,
        groupId: GROUP_ID,
        echoCancellation: [true, false],
        autoGainControl: [true, false],
        noiseSuppression: [true, false],
        channelCount: { min: 1, max: 2 },
        sampleRate: { min: meta.sampleRate, max: meta.sampleRate },
        sampleSize: { min: 16, max: 16 },
        latency: { min: 0.01, max: 0.02 },
      };
    };
  });

  overrideTrack('applyConstraints', function(orig) {
    return function applyConstraints(c) {
      var meta = _syntheticTracks.get(this);
      if (!meta) return orig.call(this, c);
      // A real microphone accepts a re-negotiation of the processing flags;
      // the underlying WebAudio track would reject it as overconstrained.
      var opts = requestedAudioOptions({ audio: c || {} });
      meta.echoCancellation = opts.echoCancellation;
      meta.autoGainControl = opts.autoGainControl;
      meta.noiseSuppression = opts.noiseSuppression;
      meta.constraints = c || {};
      return Promise.resolve();
    };
  });

  // The video half of a combined request goes back through the LIVE public
  // entry point rather than the function captured at install time, so a
  // virtual camera shim installed either before or after this one still gets
  // to serve it. Re-entering this wrapper is safe and terminates: a
  // video-only request always takes the pass-through branch.
  function delegateVideo(self, constraints) {
    var live = md.getUserMedia;
    if (typeof live === 'function') return live.call(self || md, constraints);
    return callOrigGum(self, constraints);
  }

  function combine(audioStream, videoStream) {
    var tracks = [];
    var i;
    var v = videoStream && videoStream.getTracks ? videoStream.getTracks() : [];
    for (i = 0; i < v.length; i++) tracks.push(v[i]);
    var a = audioStream.getTracks ? audioStream.getTracks() : [];
    for (i = 0; i < a.length; i++) tracks.push(a[i]);
    try {
      return new globalThis.MediaStream(tracks);
    } catch (e) {
      // No MediaStream constructor (very old WebKit): graft the audio onto
      // the video stream instead of failing the request.
      for (i = 0; i < a.length; i++) {
        try { videoStream.addTrack(a[i]); } catch (e2) {}
      }
      return videoStream;
    }
  }

  var getUserMedia = function getUserMedia(constraints) {
    var self = this && this.getUserMedia ? this : md;
    // Video-only (or empty) requests are none of this shim's business: hand
    // them down the chain untouched.
    if (!wantsAudio(constraints)) {
      var passthrough = callOrigGum(self, constraints);
      return passthrough || Promise.reject(notAllowed('getUserMedia is unavailable'));
    }
    var alsoVideo = wantsVideo(constraints);
    return fetchDecision().then(function(decision) {
      var real = decision.mode === 'real';
      if (!real && decision.mode !== 'virtual') {
        // Blocked. Per spec a request fails as a whole when any requested
        // kind cannot be provided, so a combined request is rejected too
        // rather than silently downgraded to video.
        throw notAllowed('Permission denied');
      }
      // The audio half. `real` goes to the platform as an AUDIO-ONLY request
      // even when the page asked for video too, so the video half stays the
      // camera shim's decision (MIC-004) and the platform never sees the
      // combined resource it cannot half-grant. Dart still denies that
      // resource defensively (MIC-003) for a page this shim did not reach.
      var audioPromise = real
        ? Promise.resolve(callOrigGum(
              self, withoutSyntheticDeviceId(without(constraints, 'video'), 'audio')))
            .then(function(stream) {
              if (!stream) throw notAllowed('getUserMedia is unavailable');
              return rememberRealTracks(stream);
            })
        : virtualAudioStream(decision.source, constraints);
      return audioPromise.then(function(audioStream) {
        // Gates the synthetic device label behind a served stream. Only the
        // substituted device has a label to reveal; a real grant exposes the
        // platform's own list unmasked.
        if (!real) _servedStream = true;
        if (!alsoVideo) return audioStream;
        return Promise.resolve(delegateVideo(self, without(constraints, 'audio')))
          .then(function(videoStream) {
            return combine(audioStream, videoStream);
          }, function(err) {
            // Never leave the audio half running behind a request the page
            // saw fail: stops a device track, and tears down the WebAudio
            // graph through the prototype `stop` override for a synthetic one.
            abandon(audioStream);
            throw err;
          });
      });
    });
  };
  defineOnProto('getUserMedia', asNative(getUserMedia, 'getUserMedia'));

  // Legacy callback API. Some older bundles still feature-detect it, and
  // leaving it unpatched would route them past every shim. Routed through the
  // live public entry point so it stays correct whichever capture shim
  // installed last.
  var nav = globalThis.navigator;
  if (nav && (nav.getUserMedia || nav.webkitGetUserMedia || nav.mozGetUserMedia)) {
    var legacy = function getUserMedia(constraints, success, failure) {
      Promise.resolve().then(function() {
        return md.getUserMedia(constraints);
      }).then(
        function(s) { if (success) success(s); },
        function(e) { if (failure) failure(e); });
    };
    ['getUserMedia', 'webkitGetUserMedia', 'mozGetUserMedia'].forEach(function(name) {
      if (!nav[name]) return;
      try { nav[name] = asNative(legacy, name); } catch (e) {}
    });
  }

  // In VIRTUAL mode: hide the real devices of this kind (getUserMedia will not
  // open them, so listing them is a lie the page could catch by selecting one
  // by deviceId) and publish exactly one synthetic device.
  //
  // In ASK mode on a device with NONE of this kind, publish the synthetic one
  // too: otherwise a page that enumerates first concludes there is no device
  // and never calls getUserMedia, so the user is never offered the "use a
  // file" popup at all.
  //
  // In REAL and BLOCK mode (and ASK where a real device exists): pass the
  // platform list through untouched. Masking there would break the common
  // "pick a device" UI, and in REAL mode would misreport the hardware the
  // user chose to expose (MIC-009).
  //
  // Per spec, labels are only exposed once the page holds a capture
  // permission, so the label is blank until this shim has served a stream.
  var _origEnumerateFn = typeof patchTarget.enumerateDevices === 'function'
    ? patchTarget.enumerateDevices
    : (md.enumerateDevices || null);
  var enumerateDevices = function enumerateDevices() {
    var self = this && this.enumerateDevices ? this : md;
    var base = _origEnumerateFn
      ? _origEnumerateFn.call(self)
      : Promise.resolve([]);
    return Promise.all([Promise.resolve(base), fetchMode()]).then(function(r) {
      var list = r[0] || [];
      var mode = r[1];
      var hasReal = false;
      for (var i = 0; i < list.length; i++) {
        if (list[i] && list[i].kind === 'audioinput') hasReal = true;
      }
      var publishSynthetic = mode === 'virtual' || (mode === 'ask' && !hasReal);
      if (!publishSynthetic) return list;

      var out = [];
      for (var j = 0; j < list.length; j++) {
        if (list[j] && list[j].kind !== 'audioinput') out.push(list[j]);
      }
      var info = {
        deviceId: DEVICE_ID,
        kind: 'audioinput',
        label: _servedStream ? DEVICE_LABEL : '',
        groupId: GROUP_ID,
      };
      info.toJSON = function toJSON() {
        return {
          deviceId: info.deviceId,
          kind: info.kind,
          label: info.label,
          groupId: info.groupId,
        };
      };
      out.push(info);
      return out;
    });
  };
  defineOnProto('enumerateDevices', asNative(enumerateDevices, 'enumerateDevices'));

})();
