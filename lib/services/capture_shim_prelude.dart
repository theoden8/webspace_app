import 'dart:convert';

import 'package:webspace/services/capture_track_registry.dart';
import 'package:webspace/settings/capture.dart';

/// [kind]'s capture shim: the prelude every capture shim shares, the kind's
/// own stream code ([body]), and for a kind that publishes a device, the
/// `enumerateDevices` and legacy-callback patches.
///
/// The prelude names the bridge handler from [CaptureKind.requestHandler],
/// the constant the Dart side registers, so the two cannot drift apart. It
/// leaves [body] these names: `md`, `DEVICE_LABEL`, `DEVICE_ID`, `GROUP_ID`,
/// `asNative`, `notAllowed`, `fetchDecision`, `_syntheticTracks`,
/// `presentSynthetic(track, meta)` (with `meta.release()` freeing the
/// stream's source), `overrideTrack(name, wrap)`, `defineOnProto`,
/// `patchTarget`, `rememberRealTracks`, and for a device kind `fetchMode`,
/// `_servedStream`, `callOrigGum` and `withoutSyntheticDeviceId`.
///
/// [deviceLabel] is what the page reads as the substituted track's `label`,
/// and as the published device's.
String captureShim(
  CaptureKind kind, {
  required String deviceLabel,
  required String body,
}) {
  final device = kind.publishedDevice;
  return '''
(function() {
  'use strict';
${_prelude(kind, label: jsonEncode(deviceLabel))}
${device == null ? '' : _devicePrelude(device)}
$body
${device == null ? '' : _deviceEpilogue(device)}
})();
''';
}

String _prelude(CaptureKind kind, {required String label}) => '''
  if (globalThis.__ws_${kind.shimGroup}_shim__) return;
  globalThis.__ws_${kind.shimGroup}_shim__ = true;

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
    _decisionInFlight = iaw.callHandler(${jsonEncode(kind.requestHandler)}).then(function(res) {
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
${buildRealCaptureRegistry()}

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
''';

String _devicePrelude(PublishedDevice device) => '''
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
    _modePromise = iaw.callHandler(${jsonEncode(device.modeHandler)}).then(function(m) {
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
''';

String _deviceEpilogue(PublishedDevice device) => '''
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
        if (list[i] && list[i].kind === '${device.deviceKind}') hasReal = true;
      }
      var publishSynthetic = mode === 'virtual' || (mode === 'ask' && !hasReal);
      if (!publishSynthetic) return list;

      var out = [];
      for (var j = 0; j < list.length; j++) {
        if (list[j] && list[j].kind !== '${device.deviceKind}') out.push(list[j]);
      }
      var info = {
        deviceId: DEVICE_ID,
        kind: '${device.deviceKind}',
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
''';

/// Image and looped-video sources drawn onto a capture canvas, for the
/// visual kinds. Leaves [body] `loadSource(source, missing)` and
/// `canvasStream(canvas, draw, fps, meta)`.
const String visualCaptureSources = r'''
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

  // The picked file, decoded: an <img>, or a muted looping <video>.
  function loadSource(source, missing) {
    if (!source || !source.dataUrl) return Promise.reject(notAllowed(missing));
    var isVideo = source.kind === 'video';
    return (isVideo ? loadVideo(source.dataUrl) : loadImage(source.dataUrl))
      .then(function(media) { return { media: media, isVideo: isVideo }; });
  }

  // The canvas's captured stream, repainted by `draw` at `fps`. The canvas is
  // kept out of the document: captureStream() does not require the element to
  // be rendered, and inserting it would let the page see it in the DOM.
  //
  // Keeps painting so a consumer sampling frames over time keeps seeing the
  // source. A still image needs the repaint too: captureStream(fps) only
  // emits a frame when the canvas is touched, and a stream that stops after
  // its first frame stalls consumers that wait for several.
  function canvasStream(canvas, draw, fps, meta) {
    draw();
    var stream = canvas.captureStream(fps);
    var timer = setInterval(draw, Math.max(1000 / fps, 16));
    var track = stream.getVideoTracks()[0];
    meta.release = function() {
      clearInterval(timer);
      if (meta.isVideo) { try { meta.media.pause(); } catch (e) {} }
    };
    if (track) {
      presentSynthetic(track, meta);
      // A canvas track is a CanvasCaptureMediaStreamTrack; a device or
      // display track is a plain MediaStreamTrack, and the constructor name is
      // readable via the prototype chain. Internal slots live on the
      // instance, so the track keeps working; if any engine disagrees, the
      // try/catch leaves the honest prototype in place.
      try {
        if (globalThis.MediaStreamTrack &&
            Object.getPrototypeOf(track) !== globalThis.MediaStreamTrack.prototype) {
          Object.setPrototypeOf(track, globalThis.MediaStreamTrack.prototype);
        }
      } catch (e) {}
    }
    return stream;
  }
''';
