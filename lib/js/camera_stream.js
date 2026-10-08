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
(function() {
  'use strict';
  // @include _capture_prelude.js
  // @include _capture_device_prelude.js
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

  // @include _capture_visual_sources.js


  function virtualStream(source, constraints) {
    var size = requestedSize(constraints);
    var fps = requestedFrameRate(constraints);
    return loadSource(source, 'No camera source selected').then(function(loaded) {
      var media = loaded.media;
      var isVideo = loaded.isVideo;
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
      return canvasStream(canvas, draw, fps, {
        media: media,
        isVideo: isVideo,
        width: canvas.width,
        height: canvas.height,
        fps: fps,
      });
    });
  }

  overrideTrack('getSettings', function(orig) {
    return function getSettings() {
      var s = orig.call(this) || {};
      var meta = _syntheticTracks.get(this);
      if (!meta) return s;
      s.deviceId = DEVICE_ID;
      s.groupId = GROUP_ID;
      s.facingMode = 'environment';
      if (typeof s.width !== 'number') s.width = meta.width;
      if (typeof s.height !== 'number') s.height = meta.height;
      if (typeof s.frameRate !== 'number') s.frameRate = meta.fps;
      return s;
    };
  });

  var getUserMedia = function getUserMedia(constraints) {
    var self = this && this.getUserMedia ? this : md;
    // Audio requests (alone or with video) are none of this shim's business:
    // hand them to the platform untouched so the grant can never widen into
    // the microphone.
    if (!wantsVideo(constraints) || wantsAudio(constraints)) {
      var passthrough = callOrigGum(self, constraints);
      if (!passthrough) return Promise.reject(notAllowed('getUserMedia is unavailable'));
      // Same call, same constraints, same stream — the tracks are only
      // recorded, so a deactivation can end a capture the platform granted
      // on its own prompt (CAM-012).
      return Promise.resolve(passthrough).then(rememberRealTracks);
    }
    return fetchDecision().then(function(decision) {
      if (decision.mode === 'virtual') {
        return virtualStream(decision.source, constraints).then(function(s) {
          _servedStream = true;
          return s;
        });
      }
      if (decision.mode === 'real') {
        var real = callOrigGum(self, withoutSyntheticDeviceId(constraints, 'video'));
        if (!real) return Promise.reject(notAllowed('getUserMedia is unavailable'));
        return Promise.resolve(real).then(function(s) {
          _servedStream = true;
          return rememberRealTracks(s);
        });
      }
      throw notAllowed('Permission denied');
    });
  };
  defineOnProto('getUserMedia', asNative(getUserMedia, 'getUserMedia'));

  // @include _capture_device_epilogue.js
})();
