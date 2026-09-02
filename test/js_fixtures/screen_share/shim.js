(function() {
  'use strict';
  if (globalThis.__ws_screen_share_shim__) return;
  globalThis.__ws_screen_share_shim__ = true;

  // `mediaDevices` is window-only; in a worker there is nothing to patch.
  var md = globalThis.navigator && globalThis.navigator.mediaDevices;
  if (!md) return;

  var SURFACE_LABEL = "Screen";
  // Stable per-session id, like the camera's. A fixed constant would itself
  // be a marker.
  var SURFACE_ID = (function() {
    var b = new Uint8Array(32);
    (globalThis.crypto && globalThis.crypto.getRandomValues)
      ? globalThis.crypto.getRandomValues(b)
      : (function() { for (var i = 0; i < b.length; i++) b[i] = (Math.random() * 256) | 0; })();
    var s = '';
    for (var i = 0; i < b.length; i++) s += ('0' + b[i].toString(16)).slice(-2);
    return s;
  })();

  // Whether this realm is the top-level document. The plugin's
  // forMainFrameOnly:true already keeps the shim out of subframes (on Android
  // by wrapping the source in this very test, on iOS/macOS natively), so this
  // is the second reading of the same guard rather than the only one — and the
  // one that still holds if a future platform stops honouring the flag.
  var IS_TOP = (function() {
    try { return globalThis.top === globalThis; } catch (e) { return false; }
  })();

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

  // `getDisplayMedia()` with no argument means video, as does `{video: true}`
  // and any video constraint object. Only an explicit `video: false` opts out,
  // and the spec makes that a TypeError rather than an audio-only capture.
  function wantsVideo(constraints) {
    if (!constraints) return true;
    return constraints.video !== false;
  }

  function pickDimension(spec) {
    if (typeof spec === 'number') return Math.round(spec);
    if (spec && typeof spec === 'object') {
      var v = spec.max !== undefined ? spec.max
            : spec.ideal !== undefined ? spec.ideal
            : spec.exact !== undefined ? spec.exact
            : spec.min;
      if (typeof v === 'number') return Math.round(v);
    }
    return 0;
  }

  // A display capture reports the surface's own size; constraints are advisory
  // and only cap it (you cannot ask a monitor to be 640x480). So the served
  // frame is the source's natural size, scaled down to fit any max the page
  // asked for, never cropped — a shared screen shows the whole surface.
  function surfaceSize(constraints, natW, natH) {
    var w = natW > 0 ? natW : 1280;
    var h = natH > 0 ? natH : 720;
    var v = constraints && constraints.video;
    var maxW = (v && v !== true) ? pickDimension(v.width) : 0;
    var maxH = (v && v !== true) ? pickDimension(v.height) : 0;
    var scale = 1;
    if (maxW > 0 && w > maxW) scale = Math.min(scale, maxW / w);
    if (maxH > 0 && h > maxH) scale = Math.min(scale, maxH / h);
    return {
      width: Math.max(1, Math.round(w * scale)),
      height: Math.max(1, Math.round(h * scale)),
    };
  }

  function requestedFrameRate(constraints) {
    var v = constraints && constraints.video;
    var fps = (v && v !== true) ? pickDimension(v.frameRate) : 0;
    if (!(fps > 0) || fps > 60) fps = 30;
    return fps;
  }

  // --- source decision ----------------------------------------------------

  // Asks Dart for this site's screen-sharing decision. Returns a promise
  // resolving to {mode: 'virtual'|'block', source?: {kind, dataUrl}}.
  //
  // Coalesced: a page that retries the share button must not stack popups.
  // The Dart side also coalesces; doing it here too keeps the extra round
  // trips off the bridge entirely.
  var _decisionInFlight = null;
  function fetchDecision() {
    if (_decisionInFlight) return _decisionInFlight;
    var iaw = globalThis.flutter_inappwebview;
    if (!iaw || !iaw.callHandler) {
      // No bridge: fail closed. There is nothing to fall through to anyway,
      // so denying is also the only honest answer available.
      return Promise.resolve({ mode: 'block' });
    }
    // The origin is read from the webview in Dart, never from here (SHARE-013);
    // this argument exists so the handler shape matches the other capture
    // bridges, and the Dart side ignores it.
    var origin = '';
    try { origin = (globalThis.location && globalThis.location.origin) || ''; } catch (e) {}
    _decisionInFlight = iaw.callHandler('webScreenShareRequest', origin).then(function(res) {
      _decisionInFlight = null;
      if (!res || typeof res !== 'object') return { mode: 'block' };
      return res;
    }, function() {
      _decisionInFlight = null;
      return { mode: 'block' };
    });
    return _decisionInFlight;
  }

  // --- synthetic surface --------------------------------------------------

  function loadImage(dataUrl) {
    return new Promise(function(resolve, reject) {
      var img = new Image();
      img.onload = function() { resolve(img); };
      img.onerror = function() { reject(notAllowed('Could not decode the selected image')); };
      img.src = dataUrl;
    });
  }

  function loadVideo(dataUrl) {
    return new Promise(function(resolve, reject) {
      var vid = document.createElement('video');
      vid.muted = true;
      vid.defaultMuted = true;
      vid.loop = true;
      vid.playsInline = true;
      vid.setAttribute('playsinline', '');
      vid.oncanplay = function() {
        var p = vid.play();
        if (p && p.catch) p.catch(function() {});
        resolve(vid);
      };
      vid.onerror = function() { reject(notAllowed('Could not decode the selected video')); };
      vid.src = dataUrl;
      try { vid.load(); } catch (e) {}
    });
  }

  // Synthetic surface track -> its paint loop + reported settings. A WeakMap
  // so a dropped stream is collectable.
  var _syntheticTracks = new WeakMap();

  // Every track ANY WebSpace capture shim substituted, shared across shims.
  // The camera's deactivation stop (CAM-012) skips anything in this set, so a
  // simulated surface is not torn down when the user switches sites — it is a
  // local file drawn onto a canvas, with nothing being observed.
  var _wsSynthetic = globalThis.__wsSyntheticTracks || new WeakSet();
  globalThis.__wsSyntheticTracks = _wsSynthetic;

  // Draws `media` (an <img> or a looping <video>) onto a canvas at `fps` and
  // returns the canvas's captured MediaStream. The canvas is kept out of the
  // document: captureStream() does not require the element to be rendered,
  // and inserting it would let the page see it in the DOM.
  function streamFromMedia(media, isVideo, constraints) {
    var natW = isVideo ? (media.videoWidth || 0) : (media.naturalWidth || 0);
    var natH = isVideo ? (media.videoHeight || 0) : (media.naturalHeight || 0);
    var size = surfaceSize(constraints, natW, natH);
    var fps = requestedFrameRate(constraints);

    var canvas = document.createElement('canvas');
    canvas.width = size.width;
    canvas.height = size.height;
    var ctx = canvas.getContext('2d');

    // Whole surface, scaled to the canvas. No cover-crop: the camera crops
    // because a sensor fills its frame, but a shared screen is shown entire.
    function draw() {
      if (!ctx) return;
      var sw = isVideo ? (media.videoWidth || natW) : natW;
      var sh = isVideo ? (media.videoHeight || natH) : natH;
      if (!sw || !sh) return;
      ctx.drawImage(media, 0, 0, canvas.width, canvas.height);
    }

    draw();
    var stream = canvas.captureStream(fps);

    // Keep painting so a page sampling frames over time keeps seeing the
    // surface. A still image still needs the repaint: captureStream(fps) only
    // emits a frame when the canvas is touched, and a stream that stops
    // producing frames after the first one stalls consumers that wait for
    // several.
    var timer = setInterval(draw, Math.max(1000 / fps, 16));

    var track = stream.getVideoTracks()[0];
    if (track) {
      // Register the track; the prototype-level overrides installed below read
      // this map. Assigning label/getSettings onto the track instance instead
      // would leave them enumerable in Object.getOwnPropertyNames(track),
      // where a real MediaStreamTrack has none — a giveaway a fingerprinter
      // checks for.
      _syntheticTracks.set(track, {
        timer: timer,
        media: media,
        isVideo: isVideo,
        width: canvas.width,
        height: canvas.height,
        fps: fps,
        constraints: (constraints && constraints.video && constraints.video !== true)
          ? constraints.video
          : {},
      });
      try { _wsSynthetic.add(track); } catch (e) {}
      // A canvas track is a CanvasCaptureMediaStreamTrack; a display capture
      // track is not. Re-point the prototype so the class matches. Internal
      // slots live on the instance, so the track keeps working; if any engine
      // disagrees, the try/catch leaves the honest prototype in place.
      try {
        if (globalThis.MediaStreamTrack &&
            Object.getPrototypeOf(track) !== globalThis.MediaStreamTrack.prototype) {
          Object.setPrototypeOf(track, globalThis.MediaStreamTrack.prototype);
        }
      } catch (e) {}
      // A track that ends must also drop the paint loop, else a page that
      // discards the stream without calling stop() leaks a timer for the
      // lifetime of the document.
      try {
        track.addEventListener('ended', function() { clearInterval(timer); });
      } catch (e) {}
    }
    return stream;
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
        return _syntheticTracks.has(this) ? SURFACE_LABEL : origLabelGet.call(this);
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
        // The shape a display capture reports, which is NOT the camera's:
        // no facingMode or groupId, and displaySurface/logicalSurface/cursor
        // instead. A page that branches on these must see a coherent surface.
        s.deviceId = SURFACE_ID;
        s.displaySurface = 'monitor';
        s.logicalSurface = true;
        s.cursor = 'never';
        s.resizeMode = 'none';
        s.width = meta.width;
        s.height = meta.height;
        s.aspectRatio = meta.height > 0 ? meta.width / meta.height : 0;
        if (typeof s.frameRate !== 'number') s.frameRate = meta.fps;
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
          deviceId: SURFACE_ID,
          displaySurface: 'monitor',
          cursor: ['never'],
          width: { max: meta.width },
          height: { max: meta.height },
          frameRate: { max: meta.fps },
          aspectRatio: {
            max: meta.height > 0 ? meta.width / meta.height : 0,
            min: meta.height > 0 ? meta.width / meta.height : 0,
          },
          resizeMode: ['none'],
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
        // A real display capture accepts a downscale re-negotiation; the
        // underlying canvas track would reject it as overconstrained.
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
        // A clone must keep presenting as the same surface; without this it
        // would report an empty label and canvas settings, betraying the
        // original. It also has to stay exempt from the camera's stop.
        if (meta && copy) {
          _syntheticTracks.set(copy, meta);
          try { _wsSynthetic.add(copy); } catch (e) {}
        }
        return copy;
      }, 'clone');
      try { proto.clone = clone; } catch (e) {}
    }

    if (typeof proto.stop === 'function') {
      var origStop = proto.stop;
      var stop = asNative(function stop() {
        var meta = _syntheticTracks.get(this);
        if (meta) {
          clearInterval(meta.timer);
          if (meta.isVideo) { try { meta.media.pause(); } catch (e) {} }
        }
        return origStop.call(this);
      }, 'stop');
      try { proto.stop = stop; } catch (e) {}
    }
  })();

  function virtualSurface(source, constraints) {
    if (!source || !source.dataUrl) {
      return Promise.reject(notAllowed('No shared surface selected'));
    }
    var isVideo = source.kind === 'video';
    var loader = isVideo ? loadVideo(source.dataUrl) : loadImage(source.dataUrl);
    return loader.then(function(media) {
      return streamFromMedia(media, isVideo, constraints);
    });
  }

  // --- getDisplayMedia patch ---------------------------------------------

  // Patch the PROTOTYPE, not the `navigator.mediaDevices` instance. Assigning
  // to the instance leaves getDisplayMedia visible in
  // Object.getOwnPropertyNames(navigator.mediaDevices), where a real browser
  // defines it only on MediaDevices.prototype — an own-property leak the
  // repo's lie-detection tier probes for on every shim.
  // Never fall back to Object.prototype: on a platform with no MediaDevices
  // class (or a stubbed mediaDevices that owns its methods) that would install
  // the override globally. Patch the instance there instead.
  var MDCtor = globalThis.MediaDevices;
  var mdProto = (MDCtor && MDCtor.prototype && md instanceof MDCtor)
    ? MDCtor.prototype
    : null;
  var patchTarget = mdProto || md;

  var getDisplayMedia = function getDisplayMedia(constraints) {
    // Per spec an audio-only display capture is a TypeError, not a denial.
    // Answering it as one keeps a feature-detecting page on its normal path.
    if (!wantsVideo(constraints)) {
      return Promise.reject(new TypeError(
        "Failed to execute 'getDisplayMedia' on 'MediaDevices': video must be requested"));
    }
    // A subframe is not who the user answered the popup for. Deny before the
    // bridge is touched, so a frame cannot even raise the prompt.
    if (!IS_TOP) {
      return Promise.reject(notAllowed('Permission denied'));
    }
    return fetchDecision().then(function(decision) {
      if (decision.mode === 'virtual') {
        return virtualSurface(decision.source, constraints);
      }
      // There is no 'real' branch to reach: no mode grants a display surface,
      // so every other answer is a denial. The page sees exactly what it would
      // see if the user had dismissed a real browser's surface picker.
      throw notAllowed('Permission denied');
    });
  };

  // Defined whether or not the engine has one of its own. Where it does
  // (WebKit on desktop), overriding is what guarantees the platform picker is
  // never reached; where it does not (Android WebView, iOS), defining it is
  // what lets a site's share flow proceed on a file the user chose instead of
  // dead-ending. The cost is that the API is present on an engine that lacks
  // it — the same trade the camera shim makes by publishing a synthetic
  // videoinput on a camera-less device.
  try {
    var prev = Object.getOwnPropertyDescriptor(patchTarget, 'getDisplayMedia');
    Object.defineProperty(patchTarget, 'getDisplayMedia', {
      value: asNative(getDisplayMedia, 'getDisplayMedia'),
      writable: prev ? prev.writable !== false : true,
      enumerable: prev ? prev.enumerable : false,
      configurable: true,
    });
  } catch (e) {}
})();
