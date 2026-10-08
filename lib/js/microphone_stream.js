// Per-site microphone JavaScript shim.
//
// Intercepts a `getUserMedia` that asks for audio and resolves it from the
// site's mode: `virtual` builds a MediaStream whose audio track is a
// user-picked clip decoded once and looped forever through a WebAudio graph
// (`AudioBufferSourceNode.loop` -> `MediaStreamAudioDestinationNode`), `real`
// passes an audio-only request to the platform, and anything else denies.
//
// Presentation: a WebAudio destination track otherwise reports an empty
// `label`, empty `getSettings()`, and `enumerateDevices()` lists no
// `audioinput` at all, which both breaks ordinary capture UIs (they enumerate
// before requesting, and show the label in a device picker) and singles this
// browser out to any script that looks. The shim therefore gives the track an
// ordinary microphone label, the settings/capabilities shape a real capture
// track reports, and publishes one matching `audioinput`. That is
// presentation hygiene for a stream the user deliberately substituted — it is
// not a defeat of any analysis of the audio itself.
//
// Composition with the camera shim: a request for audio AND video is split in
// every mode. The audio half is synthesised or requested audio-only here; the
// video half is re-issued through `navigator.mediaDevices.getUserMedia` — the
// live public entry point, not the function this shim captured at install
// time — so the camera shim resolves it per its own mode whichever order the
// two were injected in. Re-entry terminates because a video-only request
// always falls through this shim. Splitting is also what keeps the platform's
// own combined resource (CAMERA_AND_MICROPHONE on iOS and macOS, which cannot
// be half-granted) out of the picture for a page this shim reached.
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

  // @include _capture_device_epilogue.js
})();
