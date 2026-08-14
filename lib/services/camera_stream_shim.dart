// Virtual camera JavaScript shim.
//
// Intercepts video-only `getUserMedia` and resolves it with a MediaStream
// rendered from a user-picked image or looped video instead of the device
// camera, so a page's QR scanner (banking logins especially) can read a code
// that already lives on the device. The real camera is never opened in this
// mode and no OS camera permission is involved — the stream comes from
// `HTMLCanvasElement.captureStream()`, which every engine we ship supports
// (Chromium WebView, WKWebView 11+, WPE WebKit).
//
// The per-site decision lives in Dart (`WebViewModel.cameraMode`); this shim
// asks for it through the `webCameraRequest` handler on the first request, so
// the popup, the remembered choice, and the archive-tier override are all
// enforced in one place rather than duplicated in JS.
//
// Presentation: a synthetic track otherwise reports an empty `label` and
// `enumerateDevices()` reports no camera at all, which both breaks ordinary
// capture UIs (they enumerate before requesting, and show the label in a
// device picker) and singles this browser out to any script that looks. The
// shim therefore gives the track an ordinary camera label and publishes one
// matching `videoinput` device. That is presentation hygiene for a stream the
// user deliberately substituted — it is not a defeat of liveness or
// presentation-attack detection, which inspects the imagery itself.
//
// Audio is never synthesised. A request that asks for audio (with or without
// video) falls through to the native path untouched, so this can't widen into
// the microphone.
//
// Must be injected at DOCUMENT_START (and with forMainFrameOnly: false) so it
// beats the page's own capture code and reaches cross-origin iframes.

import 'dart:convert';

/// Build the virtual-camera shim.
///
/// [deviceLabel] is the camera name reported to the page for both the track
/// and the published `videoinput` device.
///
/// Pure-Dart so the shim string is reachable from `tool/dump_shim_js.dart`
/// and the drift check.
String buildCameraStreamShim({String deviceLabel = 'Integrated Camera'}) {
  final label = jsonEncode(deviceLabel);
  return '''
(function() {
  'use strict';
  if (globalThis.__ws_camera_shim__) return;
  globalThis.__ws_camera_shim__ = true;

  // `mediaDevices` is window-only; in a worker there is nothing to patch.
  var md = globalThis.navigator && globalThis.navigator.mediaDevices;
  if (!md) return;

  var DEVICE_LABEL = $label;
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
      // Present as an ordinary camera: the synthetic track's own label is
      // empty and its facingMode absent, both of which break capture UIs
      // and mark the browser.
      try {
        Object.defineProperty(track, 'label', { get: function() { return DEVICE_LABEL; }, configurable: true });
      } catch (e) {}
      var _origGetSettings = track.getSettings ? track.getSettings.bind(track) : null;
      var getSettings = function getSettings() {
        var s = _origGetSettings ? _origGetSettings() : {};
        s.deviceId = DEVICE_ID;
        s.groupId = GROUP_ID;
        s.facingMode = 'environment';
        if (typeof s.width !== 'number') s.width = canvas.width;
        if (typeof s.height !== 'number') s.height = canvas.height;
        if (typeof s.frameRate !== 'number') s.frameRate = fps;
        return s;
      };
      try { track.getSettings = asNative(getSettings, 'getSettings'); } catch (e) {}

      var _origStop = track.stop ? track.stop.bind(track) : null;
      var stop = function stop() {
        clearInterval(timer);
        if (isVideo) { try { media.pause(); } catch (e) {} }
        if (_origStop) _origStop();
      };
      try { track.stop = asNative(stop, 'stop'); } catch (e) {}
      // A track that ends must also drop the paint loop, else a page that
      // discards the stream without calling stop() leaks a timer for the
      // lifetime of the document.
      try {
        track.addEventListener('ended', function() { clearInterval(timer); });
      } catch (e) {}
    }
    return stream;
  }

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

  var _origGum = md.getUserMedia ? md.getUserMedia.bind(md) : null;

  var getUserMedia = function getUserMedia(constraints) {
    // Audio requests (alone or with video) are none of this shim's business:
    // hand them to the platform untouched so the grant can never widen into
    // the microphone.
    if (!wantsVideo(constraints) || wantsAudio(constraints)) {
      if (_origGum) return _origGum(constraints);
      return Promise.reject(notAllowed('getUserMedia is unavailable'));
    }
    return fetchDecision().then(function(decision) {
      if (decision.mode === 'virtual') {
        return virtualStream(decision.source, constraints);
      }
      if (decision.mode === 'real') {
        if (_origGum) return _origGum(constraints);
        return Promise.reject(notAllowed('getUserMedia is unavailable'));
      }
      throw notAllowed('Permission denied');
    });
  };
  try { md.getUserMedia = asNative(getUserMedia, 'getUserMedia'); } catch (e) {}

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

  // Publish exactly one videoinput. Without this, a page that enumerates
  // before requesting concludes the device has no camera and never calls
  // getUserMedia at all — the scanner UI just never starts.
  //
  // Per spec, labels are only exposed once the page holds a capture
  // permission, so the label is blank until this shim has served a stream.
  var _servedStream = false;
  var _origEnumerate = md.enumerateDevices ? md.enumerateDevices.bind(md) : null;
  var enumerateDevices = function enumerateDevices() {
    var base = _origEnumerate ? _origEnumerate() : Promise.resolve([]);
    return Promise.resolve(base).then(function(list) {
      var out = [];
      // Drop real videoinputs: in virtual mode they are not what a
      // getUserMedia call would open, so reporting them would be a lie the
      // page could catch by selecting one by deviceId.
      for (var i = 0; i < list.length; i++) {
        if (list[i] && list[i].kind !== 'videoinput') out.push(list[i]);
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
  try { md.enumerateDevices = asNative(enumerateDevices, 'enumerateDevices'); } catch (e) {}

  var _gumForFlag = md.getUserMedia;
  var flaggingGum = function getUserMedia(constraints) {
    return Promise.resolve(_gumForFlag.call(md, constraints)).then(function(s) {
      _servedStream = true;
      return s;
    });
  };
  try { md.getUserMedia = asNative(flaggingGum, 'getUserMedia'); } catch (e) {}
})();
''';
}
