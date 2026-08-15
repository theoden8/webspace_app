(function() {
  'use strict';
  if (globalThis.__ws_camera_shim__) return;
  globalThis.__ws_camera_shim__ = true;

  // `mediaDevices` is window-only; in a worker there is nothing to patch.
  var md = globalThis.navigator && globalThis.navigator.mediaDevices;
  if (!md) return;

  var DEVICE_LABEL = "Integrated Camera";
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

  // Requested frame size, honouring ideal/exact/min/max shapes. Falls back
  // to 640x480 — the near-universal default a real camera negotiates to.
  function pickDimension(spec, fallback) {
    if (typeof spec === 'number') return Math.round(spec);
    if (spec && typeof spec === 'object') {
      var v = spec.ideal !== undefined ? spec.ideal
            : spec.exact !== undefined ? spec.exact
            : spec.max !== undefined ? spec.max
            : spec.min;
      if (typeof v === 'number') return Math.round(v);
    }
    return fallback;
  }
  function requestedSize(constraints) {
    var v = constraints && constraints.video;
    if (!v || v === true) return { width: 640, height: 480 };
    return {
      width: pickDimension(v.width, 640),
      height: pickDimension(v.height, 480),
    };
  }
  function requestedFrameRate(constraints) {
    var v = constraints && constraints.video;
    var fps = (v && v !== true) ? pickDimension(v.frameRate, 30) : 30;
    if (!(fps > 0) || fps > 60) fps = 30;
    return fps;
  }

  // --- source decision ----------------------------------------------------

  // Asks Dart for this site's camera decision. Returns a promise resolving
  // to {mode: 'real'|'virtual'|'block', source?: {kind, dataUrl}}.
  //
  // Coalesced: a page that calls getUserMedia in a burst (retry loops are
  // common in scanner libraries) must not stack popups. The Dart side also
  // coalesces, but doing it here too keeps the extra round trips off the
  // bridge entirely.
  // Reads the site's CURRENT mode without ever prompting. enumerateDevices
  // must not pop a permission dialog (no browser does), but it does need to
  // know whether this site is on the virtual camera. Cached for the document:
  // the mode only changes from per-site settings, which rebuilds the webview.
  var _modePromise = null;
  function fetchMode() {
    if (_modePromise) return _modePromise;
    var iaw = globalThis.flutter_inappwebview;
    if (!iaw || !iaw.callHandler) return Promise.resolve('block');
    _modePromise = iaw.callHandler('webCameraMode').then(function(m) {
      return typeof m === 'string' ? m : 'block';
    }, function() {
      return 'block';
    });
    return _modePromise;
  }

  var _decisionInFlight = null;
  function fetchDecision() {
    if (_decisionInFlight) return _decisionInFlight;
    var iaw = globalThis.flutter_inappwebview;
    if (!iaw || !iaw.callHandler) {
      // No bridge: fail closed rather than exposing the real camera.
      return Promise.resolve({ mode: 'block' });
    }
    var origin = '';
    try { origin = (globalThis.location && globalThis.location.origin) || ''; } catch (e) {}
    _decisionInFlight = iaw.callHandler('webCameraRequest', origin).then(function(res) {
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

  // Draws `media` (an <img> or a looping <video>) onto a canvas at `fps` and
  // returns the canvas's captured MediaStream. The canvas is kept out of the
  // document: captureStream() does not require the element to be rendered,
  // and inserting it would let the page see it in the DOM.
  function streamFromMedia(media, isVideo, size, fps) {
    var canvas = document.createElement('canvas');
    var natW = isVideo ? (media.videoWidth || size.width) : (media.naturalWidth || size.width);
    var natH = isVideo ? (media.videoHeight || size.height) : (media.naturalHeight || size.height);
    canvas.width = size.width;
    canvas.height = size.height;
    var ctx = canvas.getContext('2d');

    // Cover-fit: fill the frame preserving aspect ratio, cropping the
    // overflow. Matches how a camera fills its sensor rather than
    // letterboxing, so a scanner's centre-crop heuristics still work.
    function draw() {
      if (!ctx) return;
      var sw = isVideo ? (media.videoWidth || natW) : natW;
      var sh = isVideo ? (media.videoHeight || natH) : natH;
      if (!sw || !sh) return;
      var scale = Math.max(canvas.width / sw, canvas.height / sh);
      var dw = sw * scale, dh = sh * scale;
      ctx.drawImage(media, (canvas.width - dw) / 2, (canvas.height - dh) / 2, dw, dh);
    }

    draw();
    var stream = canvas.captureStream(fps);

    // Keep painting so a scanner sampling frames over time keeps seeing the
    // source. A still image still needs the repaint: captureStream(fps) only
    // emits a frame when the canvas is touched, and a stream that stops
    // producing frames after the first one stalls scanners that wait for
    // several.
    var timer = setInterval(draw, Math.max(1000 / fps, 16));

    var track = stream.getVideoTracks()[0];
    if (track) {
      // Register the track; the prototype-level overrides installed once
      // below read this map. Assigning label/getSettings/stop onto the track
      // instance instead would leave them enumerable in
      // Object.getOwnPropertyNames(track), where a real MediaStreamTrack has
      // none — a giveaway a fingerprinter checks for.
      _syntheticTracks.set(track, {
        timer: timer,
        media: media,
        isVideo: isVideo,
        width: canvas.width,
        height: canvas.height,
        fps: fps,
      });
      // A canvas track is a CanvasCaptureMediaStreamTrack; a camera track is
      // a plain MediaStreamTrack, and the constructor name is readable via
      // the prototype chain. Re-point the prototype so the class matches an
      // ordinary camera track. Internal slots live on the instance, so the
      // track keeps working; if any engine disagrees, the try/catch leaves
      // the honest prototype in place.
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

  // Synthetic track -> its paint loop + reported settings. A WeakMap so a
  // dropped stream is collectable.
  var _syntheticTracks = new WeakMap();

  // Per spec a device label is only exposed once the page holds a capture
  // permission; flipped the first time this shim serves any stream.
  var _servedStream = false;

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
        s.facingMode = 'environment';
        if (typeof s.width !== 'number') s.width = meta.width;
        if (typeof s.height !== 'number') s.height = meta.height;
        if (typeof s.frameRate !== 'number') s.frameRate = meta.fps;
        return s;
      }, 'getSettings');
      try { proto.getSettings = getSettings; } catch (e) {}
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

  function virtualStream(source, constraints) {
    if (!source || !source.dataUrl) {
      return Promise.reject(notAllowed('No camera source selected'));
    }
    var size = requestedSize(constraints);
    var fps = requestedFrameRate(constraints);
    var isVideo = source.kind === 'video';
    var loader = isVideo ? loadVideo(source.dataUrl) : loadImage(source.dataUrl);
    return loader.then(function(media) {
      return streamFromMedia(media, isVideo, size, fps);
    });
  }

  // --- getUserMedia patch -------------------------------------------------

  // A page that enumerated while this site was on the virtual camera may hold
  // our synthetic deviceId. If the site is now on the real camera, passing
  // that id through would make the platform reject the request as
  // overconstrained, so drop just that constraint and let the OS pick.
  function withoutSyntheticDeviceId(constraints) {
    var v = constraints && constraints.video;
    if (!v || v === true || !v.deviceId) return constraints;
    var d = v.deviceId;
    var wanted = typeof d === 'string' ? d : (d.exact || d.ideal);
    if (wanted !== DEVICE_ID) return constraints;
    var video = {};
    for (var k in v) {
      if (k !== 'deviceId' && Object.prototype.hasOwnProperty.call(v, k)) {
        video[k] = v[k];
      }
    }
    var out = {};
    for (var c in constraints) {
      if (Object.prototype.hasOwnProperty.call(constraints, c)) out[c] = constraints[c];
    }
    out.video = video;
    return out;
  }

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

  var getUserMedia = function getUserMedia(constraints) {
    var self = this && this.getUserMedia ? this : md;
    // Audio requests (alone or with video) are none of this shim's business:
    // hand them to the platform untouched so the grant can never widen into
    // the microphone.
    if (!wantsVideo(constraints) || wantsAudio(constraints)) {
      var passthrough = callOrigGum(self, constraints);
      return passthrough || Promise.reject(notAllowed('getUserMedia is unavailable'));
    }
    return fetchDecision().then(function(decision) {
      if (decision.mode === 'virtual') {
        return virtualStream(decision.source, constraints).then(function(s) {
          _servedStream = true;
          return s;
        });
      }
      if (decision.mode === 'real') {
        var real = callOrigGum(self, withoutSyntheticDeviceId(constraints));
        if (!real) return Promise.reject(notAllowed('getUserMedia is unavailable'));
        return Promise.resolve(real).then(function(s) {
          _servedStream = true;
          return s;
        });
      }
      throw notAllowed('Permission denied');
    });
  };
  defineOnProto('getUserMedia', asNative(getUserMedia, 'getUserMedia'));

  // Legacy callback API. Some older scanner bundles still feature-detect it,
  // and leaving it unpatched would route them to the real camera.
  var nav = globalThis.navigator;
  if (nav && (nav.getUserMedia || nav.webkitGetUserMedia || nav.mozGetUserMedia)) {
    var legacy = function getUserMedia(constraints, success, failure) {
      getUserMedia(constraints).then(
        function(s) { if (success) success(s); },
        function(e) { if (failure) failure(e); });
    };
    ['getUserMedia', 'webkitGetUserMedia', 'mozGetUserMedia'].forEach(function(name) {
      if (!nav[name]) return;
      try { nav[name] = asNative(legacy, name); } catch (e) {}
    });
  }

  // --- enumerateDevices patch --------------------------------------------

  // In VIRTUAL mode: hide the real cameras (getUserMedia will not open them,
  // so listing them is a lie the page could catch by selecting one by
  // deviceId) and publish exactly one synthetic videoinput.
  //
  // In ASK mode on a device with NO real camera, publish the synthetic one
  // too: otherwise a scanner page that enumerates first concludes there is no
  // camera and never calls getUserMedia, so the user is never offered the
  // "use image or video" popup at all.
  //
  // In REAL / BLOCK mode (and ASK where a real camera exists): pass the
  // platform list through untouched. Masking there would break the common
  // "pick a camera" UI — the page would request our synthetic deviceId and
  // the real getUserMedia would reject it as overconstrained.
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
      var hasRealCamera = false;
      for (var i = 0; i < list.length; i++) {
        if (list[i] && list[i].kind === 'videoinput') hasRealCamera = true;
      }
      var publishSynthetic =
        mode === 'virtual' || (mode === 'ask' && !hasRealCamera);
      if (!publishSynthetic) return list;

      var out = [];
      for (var j = 0; j < list.length; j++) {
        if (list[j] && list[j].kind !== 'videoinput') out.push(list[j]);
      }
      var info = {
        deviceId: DEVICE_ID,
        kind: 'videoinput',
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
