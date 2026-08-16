(function() {
  'use strict';
  if (globalThis.__ws_microphone_shim__) return;
  globalThis.__ws_microphone_shim__ = true;

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

  // --- request shape ------------------------------------------------------

  function wantsAudio(constraints) {
    return !!(constraints && constraints.audio);
  }
  function wantsVideo(constraints) {
    return !!(constraints && constraints.video);
  }

  // Shallow copy of `constraints` with the audio half removed, for the video
  // request this shim re-issues.
  function videoOnly(constraints) {
    var out = {};
    for (var k in constraints) {
      if (k !== 'audio' && Object.prototype.hasOwnProperty.call(constraints, k)) {
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

  // --- source decision ----------------------------------------------------

  // Reads the site's CURRENT mode without ever prompting. enumerateDevices
  // must not pop a permission dialog (no browser does), but it does need to
  // know whether this site is on the virtual microphone. Cached for the
  // document: the mode only changes from per-site settings, which rebuilds
  // the webview.
  var _modePromise = null;
  function fetchMode() {
    if (_modePromise) return _modePromise;
    var iaw = globalThis.flutter_inappwebview;
    if (!iaw || !iaw.callHandler) return Promise.resolve('block');
    _modePromise = iaw.callHandler('webMicrophoneMode').then(function(m) {
      return typeof m === 'string' ? m : 'block';
    }, function() {
      return 'block';
    });
    return _modePromise;
  }

  // Asks Dart for this site's microphone decision. Returns a promise
  // resolving to {mode: 'virtual'|'block', source?: {dataUrl}}.
  //
  // Coalesced: a page that calls getUserMedia in a burst (retry loops are
  // common) must not stack popups. The Dart side also coalesces, but doing it
  // here too keeps the extra round trips off the bridge entirely.
  var _decisionInFlight = null;
  function fetchDecision() {
    if (_decisionInFlight) return _decisionInFlight;
    var iaw = globalThis.flutter_inappwebview;
    if (!iaw || !iaw.callHandler) {
      // No bridge: fail closed. There is no real-microphone mode to fall
      // through to, so denying is also the only honest answer.
      return Promise.resolve({ mode: 'block' });
    }
    var origin = '';
    try { origin = (globalThis.location && globalThis.location.origin) || ''; } catch (e) {}
    _decisionInFlight = iaw.callHandler('webMicrophoneRequest', origin).then(function(res) {
      _decisionInFlight = null;
      if (!res || typeof res !== 'object') return { mode: 'block' };
      return res;
    }, function() {
      _decisionInFlight = null;
      return { mode: 'block' };
    });
    return _decisionInFlight;
  }

  // --- synthetic stream ---------------------------------------------------

  // Synthetic track -> its WebAudio graph + reported settings. A WeakMap so a
  // dropped stream is collectable.
  var _syntheticTracks = new WeakMap();

  // Every track ANY WebSpace capture shim substituted, shared across shims.
  // The camera shim ends the device tracks it handed out when the site leaves
  // the screen (CAM-012) and skips substituted ones; a combined audio+video
  // request returns a stream carrying this shim's audio track through that
  // shim, so the exemption has to be readable from there. MIC-012 is why the
  // audio side has no stop of its own: there is no device to release.
  var _wsSynthetic = globalThis.__wsSyntheticTracks || new WeakSet();
  globalThis.__wsSyntheticTracks = _wsSynthetic;

  // Per spec a device label is only exposed once the page holds a capture
  // permission; flipped the first time this shim serves any stream.
  var _servedStream = false;

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
          // Register the track; the prototype-level overrides installed below
          // read this map. Assigning label/getSettings/stop onto the track
          // instance instead would leave them enumerable in
          // Object.getOwnPropertyNames(track), where a real MediaStreamTrack
          // has none — a giveaway a fingerprinter checks for.
          _syntheticTracks.set(track, {
            ctx: ctx,
            src: src,
            sampleRate: ctx.sampleRate,
            channelCount: opts.channelCount,
            echoCancellation: opts.echoCancellation,
            autoGainControl: opts.autoGainControl,
            noiseSuppression: opts.noiseSuppression,
            constraints: (constraints && constraints.audio === true)
              ? {} : ((constraints && constraints.audio) || {}),
          });
          try { _wsSynthetic.add(track); } catch (e) {}
          // A track that ends must also tear down the graph, else a page that
          // discards the stream without calling stop() leaks an AudioContext
          // (engines cap how many a document may hold) for the document's
          // lifetime.
          try {
            track.addEventListener('ended', function() { teardown(track); });
          } catch (e) {}
        }
        return stream;
      })
      .catch(function(err) {
        try { ctx.close(); } catch (e) {}
        throw err;
      });
  }

  function teardown(track) {
    var meta = _syntheticTracks.get(track);
    if (!meta || meta.torn) return;
    meta.torn = true;
    try { meta.src.stop(); } catch (e) {}
    try { meta.ctx.close(); } catch (e) {}
  }

  // Stops every synthetic track in a stream. Used when the other half of a
  // combined audio+video request fails: handing back nothing while an
  // AudioContext keeps running is a leak the page cannot clean up.
  function abandon(stream) {
    if (!stream || !stream.getTracks) return;
    var tracks = stream.getTracks();
    for (var i = 0; i < tracks.length; i++) {
      try { tracks[i].stop(); } catch (e) {}
    }
  }

  // --- prototype-level track overrides (installed once) -------------------

  (function patchTrackPrototype() {
    var MST = globalThis.MediaStreamTrack;
    if (!MST || !MST.prototype) return;
    var proto = MST.prototype;

    var labelDesc = Object.getOwnPropertyDescriptor(proto, 'label');
    if (labelDesc && labelDesc.get) {
      var origLabelGet = labelDesc.get;
      // Named 'get label' so Function.prototype.toString reports
      // `function get label() { [native code] }`, matching a real accessor.
      var labelGet = asNative(function label() {
        return _syntheticTracks.has(this) ? DEVICE_LABEL : origLabelGet.call(this);
      }, 'get label');
      try {
        Object.defineProperty(proto, 'label', {
          get: labelGet,
          set: labelDesc.set,
          enumerable: labelDesc.enumerable,
          configurable: true,
        });
      } catch (e) {}
    }

    if (typeof proto.getSettings === 'function') {
      var origGetSettings = proto.getSettings;
      var getSettings = asNative(function getSettings() {
        var s = origGetSettings.call(this) || {};
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
      }, 'getSettings');
      try { proto.getSettings = getSettings; } catch (e) {}
    }

    if (typeof proto.getCapabilities === 'function') {
      var origGetCapabilities = proto.getCapabilities;
      var getCapabilities = asNative(function getCapabilities() {
        var meta = _syntheticTracks.get(this);
        if (!meta) return origGetCapabilities.call(this);
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
      }, 'getCapabilities');
      try { proto.getCapabilities = getCapabilities; } catch (e) {}
    }

    if (typeof proto.getConstraints === 'function') {
      var origGetConstraints = proto.getConstraints;
      var getConstraints = asNative(function getConstraints() {
        var meta = _syntheticTracks.get(this);
        return meta ? meta.constraints : origGetConstraints.call(this);
      }, 'getConstraints');
      try { proto.getConstraints = getConstraints; } catch (e) {}
    }

    if (typeof proto.applyConstraints === 'function') {
      var origApply = proto.applyConstraints;
      var applyConstraints = asNative(function applyConstraints(c) {
        var meta = _syntheticTracks.get(this);
        if (!meta) return origApply.call(this, c);
        // A real microphone accepts a re-negotiation of the processing flags;
        // the underlying WebAudio track would reject it as overconstrained.
        var opts = requestedAudioOptions({ audio: c || {} });
        meta.echoCancellation = opts.echoCancellation;
        meta.autoGainControl = opts.autoGainControl;
        meta.noiseSuppression = opts.noiseSuppression;
        meta.constraints = c || {};
        return Promise.resolve();
      }, 'applyConstraints');
      try { proto.applyConstraints = applyConstraints; } catch (e) {}
    }

    if (typeof proto.clone === 'function') {
      var origClone = proto.clone;
      var clone = asNative(function clone() {
        var copy = origClone.call(this);
        var meta = _syntheticTracks.get(this);
        // A clone of a synthetic track must keep presenting as the same
        // device; without this it would report a real (empty) label and
        // settings, betraying the original.
        if (meta && copy) _syntheticTracks.set(copy, meta);
        return copy;
      }, 'clone');
      try { proto.clone = clone; } catch (e) {}
    }

    if (typeof proto.stop === 'function') {
      var origStop = proto.stop;
      var stop = asNative(function stop() {
        teardown(this);
        return origStop.call(this);
      }, 'stop');
      try { proto.stop = stop; } catch (e) {}
    }
  })();

  // --- getUserMedia patch -------------------------------------------------

  // Patch the PROTOTYPE, not the `navigator.mediaDevices` instance. Assigning
  // to the instance leaves getUserMedia/enumerateDevices visible in
  // Object.getOwnPropertyNames(navigator.mediaDevices), where a real browser
  // defines them only on MediaDevices.prototype — an own-property leak the
  // repo's lie-detection tier probes for on every shim.
  // Never fall back to Object.prototype: on a platform with no MediaDevices
  // class (or a stubbed mediaDevices that owns its methods) that would
  // install the override globally. Patch the instance there instead.
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

  var _origGumFn = typeof patchTarget.getUserMedia === 'function'
    ? patchTarget.getUserMedia
    : (md.getUserMedia || null);
  // `this` is the live MediaDevices when called through the prototype; fall
  // back to the captured instance for a detached call.
  function callOrigGum(self, constraints) {
    if (!_origGumFn) return null;
    return _origGumFn.call(self || md, constraints);
  }

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
      if (decision.mode !== 'virtual') {
        // Blocked. Per spec a request fails as a whole when any requested
        // kind cannot be provided, so a combined request is rejected too
        // rather than silently downgraded to video.
        throw notAllowed('Permission denied');
      }
      return virtualAudioStream(decision.source, constraints).then(function(audioStream) {
        if (!alsoVideo) {
          _servedStream = true;
          return audioStream;
        }
        return Promise.resolve(delegateVideo(self, videoOnly(constraints)))
          .then(function(videoStream) {
            _servedStream = true;
            return combine(audioStream, videoStream);
          }, function(err) {
            abandon(audioStream);
            throw err;
          });
      });
    });
  };
  defineOnProto('getUserMedia', asNative(getUserMedia, 'getUserMedia'));

  // Legacy callback API. Some older bundles still feature-detect it, and
  // leaving it unpatched would route them past every shim. Routed through the
  // live public entry point so this stays correct no matter which capture
  // shim installed last.
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

  // --- enumerateDevices patch --------------------------------------------

  // In VIRTUAL mode: hide the real microphones (getUserMedia will not open
  // them, so listing them is a lie the page could catch by selecting one by
  // deviceId) and publish exactly one synthetic audioinput.
  //
  // In ASK mode on a device with NO real microphone, publish the synthetic
  // one too: otherwise a page that enumerates first concludes there is no
  // microphone and never calls getUserMedia, so the user is never offered the
  // "use audio file" popup at all.
  //
  // In BLOCK mode (and ASK where a real microphone exists): pass the platform
  // list through untouched. Masking there would break the common "pick a
  // microphone" UI.
  //
  // Audio OUTPUT devices are left alone throughout — they are speakers, not
  // capture, and nothing here substitutes them.
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
      var hasRealMic = false;
      for (var i = 0; i < list.length; i++) {
        if (list[i] && list[i].kind === 'audioinput') hasRealMic = true;
      }
      var publishSynthetic =
        mode === 'virtual' || (mode === 'ask' && !hasRealMic);
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
