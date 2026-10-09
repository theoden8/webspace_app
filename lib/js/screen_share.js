// Simulated screen sharing JavaScript shim.
//
// Intercepts `getDisplayMedia` and resolves it with a MediaStream rendered
// from a user-picked image or looped video instead of a real display surface.
// Nothing on the device is ever captured: there is no "share the real screen"
// mode to fall through to, on any platform (see ScreenShareMode for why).
//
// Top-level document only. Unlike the camera and microphone shims this one is
// injected with forMainFrameOnly:true and refuses to serve a subframe even if
// it somehow finds itself in one. A screen share is the grant a user is least
// willing to have redirected, and a third-party frame is not who they answered
// the popup for. This is stricter than the `display-capture` permission
// policy's own `self` default, which would let a same-origin subframe through.
//
// Never any audio. `getDisplayMedia({audio: true})` resolves video-only, which
// the spec permits (system audio is best-effort), so no code path here can
// produce an audio track and system audio capture is impossible by
// construction rather than by refusal.
(function() {
  'use strict';
  // @include _native_fn.js
  // @include _capture_prelude.js
  // Whether this realm is the top-level document. The plugin's
  // forMainFrameOnly:true already keeps the shim out of subframes (on Android
  // by wrapping the source in this very test, on iOS/macOS natively), so this
  // is the second reading of the same guard rather than the only one — and the
  // one that still holds if a future platform stops honouring the flag.
  var IS_TOP = (function() {
    try { return globalThis.top === globalThis; } catch (e) { return false; }
  })();

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

  // @include _capture_visual_sources.js


  function virtualSurface(source, constraints) {
    return loadSource(source, 'No shared surface selected').then(function(loaded) {
      var media = loaded.media;
      var isVideo = loaded.isVideo;
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
      return canvasStream(canvas, draw, fps, {
        media: media,
        isVideo: isVideo,
        width: canvas.width,
        height: canvas.height,
        fps: fps,
        constraints: (constraints && constraints.video && constraints.video !== true)
          ? constraints.video
          : {},
      });
    });
  }

  overrideTrack('getSettings', function(orig) {
    return function getSettings() {
      var s = orig.call(this) || {};
      var meta = _syntheticTracks.get(this);
      if (!meta) return s;
      // The shape a display capture reports, which is NOT the camera's:
      // no facingMode or groupId, and displaySurface/logicalSurface/cursor
      // instead. A page that branches on these must see a coherent surface.
      s.deviceId = DEVICE_ID;
      s.displaySurface = 'monitor';
      s.logicalSurface = true;
      s.cursor = 'never';
      s.resizeMode = 'none';
      s.width = meta.width;
      s.height = meta.height;
      s.aspectRatio = meta.height > 0 ? meta.width / meta.height : 0;
      if (typeof s.frameRate !== 'number') s.frameRate = meta.fps;
      return s;
    };
  });

  overrideTrack('getCapabilities', function(orig) {
    return function getCapabilities() {
      var meta = _syntheticTracks.get(this);
      if (!meta) return orig.call(this);
      return {
        deviceId: DEVICE_ID,
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
    };
  });

  overrideTrack('applyConstraints', function(orig) {
    return function applyConstraints(c) {
      var meta = _syntheticTracks.get(this);
      if (!meta) return orig.call(this, c);
      // A real display capture accepts a downscale re-negotiation; the
      // underlying canvas track would reject it as overconstrained.
      meta.constraints = c || {};
      return Promise.resolve();
    };
  });

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
  defineOnProto('getDisplayMedia', asNative(getDisplayMedia, 'getDisplayMedia'));

})();
