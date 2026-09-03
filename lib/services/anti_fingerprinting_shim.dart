// Per-site anti-fingerprinting JavaScript shim.
//
// Injected at DOCUMENT_START into every frame when a site's umbrella
// `trackingProtectionEnabled` toggle is on. Surfaces covered:
//
//   * Canvas 2D     — toDataURL / toBlob / getImageData seeded noise
//   * WebGL / WebGL2 — getParameter (vendor/renderer), getSupportedExtensions
//                      list, readPixels seeded noise
//   * Audio          — AudioBuffer.getChannelData / copyFromChannel,
//                      AnalyserNode.getFloat{Frequency,TimeDomain}Data noise
//   * Text metrics   — Canvas/Offscreen measureText jitter, document.fonts.check
//                      restricted to a small common-fonts allowlist
//   * Screen         — width/height/availWidth/availHeight/colorDepth/pixelDepth;
//                      in letterbox mode screen.* mirrors the real window.inner*;
//                      matchMedia (min-|max-)device-width/height answers against
//                      the same dimensions so CSS media queries can't recover
//                      the real screen size
//   * Hardware       — navigator.hardwareConcurrency, navigator.deviceMemory
//   * Plugins/MIME   — navigator.plugins / navigator.mimeTypes -> empty
//   * Battery        — navigator.getBattery() -> fixed values
//   * Speech         — speechSynthesis.getVoices() -> []
//   * Timing         — performance.now() / Date.now() quantized to 100ms
//   * Layout         — Element.getBoundingClientRect sub-pixel jitter
//
// All values that vary per site are derived from a Mulberry32 PRNG seeded
// off [seed] (the per-site siteId), so the same site always reports the
// same fingerprint across sessions, but two different sites — or two users
// of the same site — see distinct fingerprints. Noise added to large
// arrays (canvas pixels, audio buffers) uses sub-seeds salted with the
// call's input range so a script can't average it away by reading the
// same buffer twice.
//
// Patches go on Web*RenderingContext / Navigator / Screen / etc.
// PROTOTYPES, never the instance, so a fingerprinter walking
// `Object.getOwnPropertyNames(navigator)` doesn't see a tell. Every
// wrapper goes through `asNative(...)` so `Function.prototype.toString`
// reports `[native code]` — the WeakMap keyed there is the same one
// `desktop_mode_shim.dart` and `location_spoof_service.dart` use.
//
// The shim is wrapped in a re-entrance guard (`__ws_anti_fp_shim__`)
// because Android System WebView and WKWebView both re-run
// initialUserScripts on every frame; without the guard the second run
// would wrap the already-wrapped methods and amplify the noise.
//
// jsdom can exercise the shape (prototype methods replaced, getters
// installed) but not the noise on real Canvas/WebGL/Audio data — those
// engines are absent. End-to-end fingerprint proofing runs the dumped
// fixture through Puppeteer + FingerprintJS in
// test/browser/fingerprint_real_engine.test.js.

import 'dart:convert';

/// Compute the seed string passed to [buildAntiFingerprintingShim].
///
/// Non-incognito sites seed with `siteId` verbatim — the fingerprint stays
/// stable across launches (ETP-004 baseline).
///
/// Incognito sites mix in a process-lifetime [launchNonce] (typically
/// `LaunchNonce.value`) so the fingerprint is stable within a single app
/// session — no flicker on iframe re-injection or nested webview opens —
/// but randomizes across cold restarts. The `incognito` flag already implies
/// the user wants a fresh-visitor posture each launch; reusing the same
/// fingerprint across launches would itself be a stable cross-session
/// identifier (issue #327, ETP-019).
///
/// [resetNonce], when non-empty, is a per-site value regenerated whenever the
/// user clears the site's data (ETP-022). Folding it into the seed rerolls
/// the entire fingerprint (canvas/WebGL/audio/window size/…) so a site can't
/// re-identify the user across a data wipe via a stable fingerprint. When
/// null/empty the seed is unchanged, so sites stored before this field
/// existed keep their fingerprint until the user resets them.
String computeAntiFingerprintingSeed({
  required String siteId,
  required bool incognito,
  required String launchNonce,
  String? resetNonce,
}) {
  final base = (resetNonce != null && resetNonce.isNotEmpty)
      ? '$siteId:$resetNonce'
      : siteId;
  return incognito ? '$base:$launchNonce' : base;
}

/// Compose the full anti-fingerprinting `UserScript.source` (shim body
/// plus the trailing `\n;null;` evaluator-return) for the given site
/// configuration, or `null` if the umbrella is off / no siteId is set.
///
/// Lives alongside [computeAntiFingerprintingSeed] so the entire chain —
/// gate → seed derivation → shim text — is exercisable from `flutter test`
/// without standing up `WebViewFactory.createWebView`.
String? buildAntiFingerprintingScriptSource({
  required String? siteId,
  required bool trackingProtectionEnabled,
  required bool incognito,
  required String launchNonce,
  String? resetNonce,
  bool letterbox = false,
}) {
  if (!trackingProtectionEnabled || siteId == null) return null;
  final seed = computeAntiFingerprintingSeed(
    siteId: siteId,
    incognito: incognito,
    launchNonce: launchNonce,
    resetNonce: resetNonce,
  );
  return '${buildAntiFingerprintingShim(seed, letterbox: letterbox)}\n;null;';
}

/// Build the per-site anti-fingerprinting shim seeded by [seed]. The seed
/// is computed via [computeAntiFingerprintingSeed] — siteId-only for
/// non-incognito (stable per site) or `siteId:launchNonce` for incognito
/// (stable per session, randomized per launch).
///
/// When [letterbox] is true the site's WebView has been physically sized to a
/// bucketed box by Flutter, so `window.inner*` is already truthful; the shim
/// then makes `screen.*` mirror `window.inner*` (instead of the fixed
/// 1920x1080) so the two stay consistent. When false, `screen.*` keeps the
/// fixed desktop dimensions (ETP-010) and window size is left untouched.
String buildAntiFingerprintingShim(
  String seed, {
  bool letterbox = false,
}) {
  final encodedSeed = jsonEncode(seed);
  final letterboxJs = letterbox ? 'true' : 'false';
  return '''
(function() {
  'use strict';
  if (globalThis.__ws_anti_fp_shim__) return;
  globalThis.__ws_anti_fp_shim__ = true;

  var SEED = $encodedSeed;
  var LETTERBOX = $letterboxJs;

  // Shared Function.prototype.toString stubs — same WeakMap as
  // desktop_mode_shim.dart and location_spoof_service.dart so all three
  // shims funnel through one patched toString.
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

  // Mulberry32 PRNG keyed off a 32-bit FNV-1a hash of (SEED + ':' + salt).
  // Salting per call site means a fingerprinter can't cancel noise by
  // reading the same buffer twice — the second read uses a different sub-
  // stream because the salt encodes the call's input range.
  function hashStr(s) {
    var h = 2166136261 >>> 0;
    for (var i = 0; i < s.length; i++) {
      h ^= s.charCodeAt(i);
      h = Math.imul(h, 16777619) >>> 0;
    }
    return h >>> 0;
  }
  function makeRng(seedNum) {
    var s = seedNum >>> 0;
    return function() {
      s = (s + 0x6D2B79F5) >>> 0;
      var t = s;
      t = Math.imul(t ^ (t >>> 15), t | 1);
      t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }
  function seededRng(salt) { return makeRng(hashStr(SEED + ':' + salt)); }

  var _baseRng = seededRng('init');

  // This same source is injected into Worker/SharedWorker global scopes so the
  // page and its workers report identical values (a page/worker disagreement
  // is itself a fingerprint). A worker has no Screen/document/Element and its
  // navigator legitimately carries a smaller surface, so scope-only sections
  // are guarded and we never ADD a navigator property a real WorkerNavigator
  // lacks — only correct the value of one already present.
  var IS_WORKER = typeof WorkerGlobalScope !== 'undefined' &&
    globalThis instanceof WorkerGlobalScope;
  var NavProto = (typeof navigator !== 'undefined' && navigator)
    ? Object.getPrototypeOf(navigator) : null;

  // Constants baked once per session. Realistic, plausible values — not
  // the ones the underlying device would report, so two sites isolated
  // by container both see the same numbers (privacy) while different
  // sites see different ones (uniqueness).
  var SCREEN_W = 1920;
  var SCREEN_H = 1080;
  var COLOR_DEPTH = 24;
  // hardwareConcurrency in [4, 8]
  var HW_CONCURRENCY = 4 + (Math.floor(_baseRng() * 5) | 0);
  // deviceMemory ∈ {4, 8}
  var DEVICE_MEMORY = (_baseRng() < 0.5) ? 4 : 8;

  function defineGetterOnProto(proto, name, value) {
    if (!proto) return;
    try {
      Object.defineProperty(proto, name, {
        configurable: true,
        enumerable: true,
        get: asNative(function() { return value; }, name),
      });
    } catch (e) {}
  }

  function defineGetterFnOnProto(proto, name, fn) {
    if (!proto) return;
    try {
      Object.defineProperty(proto, name, {
        configurable: true,
        enumerable: true,
        get: asNative(fn, name),
      });
    } catch (e) {}
  }

  // --- screen.* ---
  // In letterbox mode the WebView has been physically sized to a bucketed
  // box, so window.inner* is already truthful — mirror screen.* to it so the
  // two agree (Tor-style). Otherwise pin the fixed desktop dimensions.
  try {
    if (typeof Screen !== 'undefined' && Screen.prototype) {
      if (LETTERBOX) {
        defineGetterFnOnProto(Screen.prototype, 'width',
            function() { return globalThis.innerWidth; });
        defineGetterFnOnProto(Screen.prototype, 'height',
            function() { return globalThis.innerHeight; });
        defineGetterFnOnProto(Screen.prototype, 'availWidth',
            function() { return globalThis.innerWidth; });
        defineGetterFnOnProto(Screen.prototype, 'availHeight',
            function() { return globalThis.innerHeight; });
      } else {
        defineGetterOnProto(Screen.prototype, 'width', SCREEN_W);
        defineGetterOnProto(Screen.prototype, 'height', SCREEN_H);
        defineGetterOnProto(Screen.prototype, 'availWidth', SCREEN_W);
        defineGetterOnProto(Screen.prototype, 'availHeight', SCREEN_H - 40);
      }
      defineGetterOnProto(Screen.prototype, 'colorDepth', COLOR_DEPTH);
      defineGetterOnProto(Screen.prototype, 'pixelDepth', COLOR_DEPTH);
    }
  } catch (e) {}

  // --- matchMedia device-dimension agreement ---
  // screen.* is spoofed above, but CSS `(min-|max-)device-width/height`
  // media queries resolve against the REAL screen. A fingerprinter
  // binary-searching `(max-device-width: Npx)` recovers the true device
  // size and contradicts screen.width (CreepJS's "CSS Media Queries" leak).
  // Intercept single-feature device-width/height queries and answer against
  // the SAME dimensions screen.* reports: window.inner* in letterbox mode
  // (the box is physically real), the pinned SCREEN_W/H otherwise.
  try {
    if (typeof globalThis.matchMedia === 'function') {
      var _origMatchMedia = globalThis.matchMedia.bind(globalThis);
      var DEVICE_DIM_RE =
        /^\\(\\s*(min-|max-)?device-(width|height)\\s*:\\s*([\\d.]+)px\\s*\\)\$/i;
      function _targetDim(which) {
        if (LETTERBOX) {
          return which === 'width' ? globalThis.innerWidth : globalThis.innerHeight;
        }
        return which === 'width' ? SCREEN_W : SCREEN_H;
      }
      function _syntheticMql(query, matches) {
        var listeners = [];
        return {
          matches: matches,
          media: query,
          onchange: null,
          addListener: function(l) { if (l) listeners.push(l); },
          removeListener: function(l) {
            var i = listeners.indexOf(l); if (i >= 0) listeners.splice(i, 1);
          },
          addEventListener: function(_t, l) { if (l) listeners.push(l); },
          removeEventListener: function(_t, l) {
            var i = listeners.indexOf(l); if (i >= 0) listeners.splice(i, 1);
          },
          dispatchEvent: function() { return false; },
        };
      }
      var _patchedMatchMedia = function matchMedia(query) {
        try {
          if (typeof query === 'string') {
            var m = DEVICE_DIM_RE.exec(query.trim());
            if (m) {
              var actual = _targetDim(m[2].toLowerCase());
              var val = parseFloat(m[3]);
              var prefix = (m[1] || '').toLowerCase();
              var matches = prefix === 'min-'
                ? actual >= val
                : (prefix === 'max-' ? actual <= val : actual === val);
              return _syntheticMql(query, matches);
            }
          }
        } catch (e) {}
        return _origMatchMedia(query);
      };
      asNative(_patchedMatchMedia, 'matchMedia');
      globalThis.matchMedia = _patchedMatchMedia;
    }
  } catch (e) {}

  // --- navigator.hardwareConcurrency / deviceMemory ---
  // hardwareConcurrency / deviceMemory exist on WorkerNavigator too, so these
  // are spoofed in worker scope as well — the page and its workers MUST agree.
  try {
    defineGetterOnProto(NavProto, 'hardwareConcurrency', HW_CONCURRENCY);
    defineGetterOnProto(NavProto, 'deviceMemory', DEVICE_MEMORY);
  } catch (e) {}

  // --- navigator.plugins / mimeTypes -> empty array-likes ---
  // A real PluginArray has length, item(), namedItem(), refresh(). Returning
  // a plain array would leak the override; we synthesize the missing methods.
  //
  // Built from the LIVE collection's own prototype, not from an Array:
  // `Object.defineProperty([], 'length', ...)` throws because an Array's
  // length is non-configurable, which aborted this whole block and left the
  // real plugin list in place with nothing reporting the failure. A plain
  // array was also a tell in its own right — `Array.isArray(navigator
  // .plugins)` is false on a real engine and its prototype is `PluginArray`.
  try {
    function emptyCollectionLike(live, withRefresh) {
      if (!live) return null;
      var proto = Object.getPrototypeOf(live);
      if (!proto) return null;
      var d = Object.getOwnPropertyDescriptor(proto, 'length');
      if (d && d.configurable !== false) {
        Object.defineProperty(proto, 'length', {
          configurable: true,
          enumerable: d.enumerable,
          get: asNative(function length() { return 0; }, 'length'),
        });
      }
      if (typeof proto.item === 'function') {
        proto.item = asNative(function item() { return null; }, 'item');
      }
      if (typeof proto.namedItem === 'function') {
        proto.namedItem = asNative(function namedItem() { return null; }, 'namedItem');
      }
      if (withRefresh && typeof proto.refresh === 'function') {
        proto.refresh = asNative(function refresh() {}, 'refresh');
      }
      return Object.create(proto);
    }
    // Skipped in worker scope: a real WorkerNavigator has no plugins /
    // mimeTypes, so defining them there would ADD a property the engine lacks.
    if (!IS_WORKER && typeof navigator !== 'undefined') {
      var emptyPlugins = emptyCollectionLike(navigator.plugins, true);
      var emptyMimes = emptyCollectionLike(navigator.mimeTypes, false);
      if (emptyPlugins) defineGetterOnProto(NavProto, 'plugins', emptyPlugins);
      if (emptyMimes) defineGetterOnProto(NavProto, 'mimeTypes', emptyMimes);
    }
  } catch (e) {}

  // --- navigator.getBattery -> fixed values ---
  // Window-only: the Battery API is not exposed to workers (see plugins above).
  try {
    if (NavProto && !IS_WORKER) {
      var fixedBattery = {
        charging: true,
        chargingTime: 0,
        dischargingTime: Infinity,
        level: 1,
        addEventListener: asNative(function() {}, 'addEventListener'),
        removeEventListener: asNative(function() {}, 'removeEventListener'),
        dispatchEvent: asNative(function() { return false; }, 'dispatchEvent'),
        onchargingchange: null,
        onchargingtimechange: null,
        ondischargingtimechange: null,
        onlevelchange: null,
      };
      Object.defineProperty(NavProto, 'getBattery', {
        configurable: true,
        writable: true,
        value: asNative(function getBattery() {
          return Promise.resolve(fixedBattery);
        }, 'getBattery'),
      });
    }
  } catch (e) {}

  // --- speechSynthesis.getVoices -> [] ---
  // A device's installed-voice list is one of the highest-entropy
  // fingerprinting axes. Returning an empty list is the same posture as
  // a fresh-install browser before any voices have loaded.
  try {
    if (typeof SpeechSynthesis !== 'undefined' && SpeechSynthesis.prototype) {
      SpeechSynthesis.prototype.getVoices = asNative(function getVoices() {
        return [];
      }, 'getVoices');
    } else if (typeof speechSynthesis !== 'undefined' && speechSynthesis) {
      try {
        speechSynthesis.getVoices = asNative(function getVoices() {
          return [];
        }, 'getVoices');
      } catch (e) {}
    }
  } catch (e) {}

  // --- Canvas 2D: toDataURL / toBlob / getImageData seeded noise ---
  // We mutate ~1 in 32 RGBA pixels by ±1 on the red channel. A canvas
  // fingerprint hashing the pixel buffer changes consistently per site,
  // but stays consistent across loads of the same site (seed -> same RNG).
  function noisePixels(pixelData, salt) {
    try {
      var rng = seededRng(salt);
      var len = pixelData.length;
      for (var i = 0; i < len; i += 4) {
        if ((rng() * 32) < 1) {
          var v = pixelData[i] + ((rng() < 0.5) ? 1 : -1);
          pixelData[i] = (v < 0) ? 0 : ((v > 255) ? 255 : v);
        }
      }
    } catch (e) {}
  }
  try {
    if (typeof CanvasRenderingContext2D !== 'undefined' &&
        CanvasRenderingContext2D.prototype) {
      var ctxProto = CanvasRenderingContext2D.prototype;
      var origGetImageData = ctxProto.getImageData;
      if (typeof origGetImageData === 'function') {
        ctxProto.getImageData = asNative(function getImageData(x, y, w, h) {
          var data = origGetImageData.apply(this, arguments);
          if (data && data.data) {
            noisePixels(data.data, 'canvas2d:gid:' + x + ':' + y + ':' + w + ':' + h);
          }
          return data;
        }, 'getImageData');
      }
    }
    if (typeof HTMLCanvasElement !== 'undefined' &&
        HTMLCanvasElement.prototype) {
      var canProto = HTMLCanvasElement.prototype;
      // Once per canvas. The nudge paints a pixel ONTO the canvas, so running
      // it again on the next read stacks a second pixel on the first: two
      // reads of one canvas return different bytes and the per-site
      // fingerprint drifts within a page, which is the averaging weakness the
      // noise exists to resist.
      var _nudged = new WeakSet();
      function nudgeCanvas(canvas, salt) {
        try {
          if (_nudged.has(canvas)) return;
          _nudged.add(canvas);
          var ctx = canvas.getContext && canvas.getContext('2d');
          if (!ctx || typeof ctx.fillRect !== 'function') return;
          var rng = seededRng(salt);
          var x = Math.floor(rng() * Math.max(1, canvas.width || 1));
          var y = Math.floor(rng() * Math.max(1, canvas.height || 1));
          var prev;
          try { prev = ctx.fillStyle; } catch (e) {}
          ctx.fillStyle = 'rgba(' +
            (Math.floor(rng() * 256)) + ',' +
            (Math.floor(rng() * 256)) + ',' +
            (Math.floor(rng() * 256)) + ',0.005)';
          ctx.fillRect(x, y, 1, 1);
          try { if (prev !== undefined) ctx.fillStyle = prev; } catch (e) {}
        } catch (e) {}
      }
      var origToDataURL = canProto.toDataURL;
      if (typeof origToDataURL === 'function') {
        canProto.toDataURL = asNative(function toDataURL() {
          nudgeCanvas(this, 'canvas:toDataURL');
          return origToDataURL.apply(this, arguments);
        }, 'toDataURL');
      }
      var origToBlob = canProto.toBlob;
      if (typeof origToBlob === 'function') {
        canProto.toBlob = asNative(function toBlob() {
          nudgeCanvas(this, 'canvas:toBlob');
          return origToBlob.apply(this, arguments);
        }, 'toBlob');
      }
    }
  } catch (e) {}

  // --- measureText jitter (Canvas + Offscreen) ---
  // A multiplicative ±0.01% jitter on every numeric TextMetrics field.
  // Big enough to break exact-equality fingerprints, small enough that
  // text never visibly mis-lays-out.
  //
  // The jitter is applied by wrapping the getters on TextMetrics.prototype,
  // not by returning a copy. The copy was a plain object: `m instanceof
  // TextMetrics` came back false and its prototype chain ended at `Object`,
  // so the noise was undetectable but the presence of the noise was not, and
  // it broke any caller that type-checked the result. The engine's own
  // TextMetrics is handed back untouched and a WeakMap keyed on it carries
  // the factor, so the instance keeps zero own properties.
  var _tmJitter = new WeakMap();
  function patchTextMetricsProto() {
    if (typeof TextMetrics === 'undefined' || !TextMetrics.prototype) return;
    var proto = TextMetrics.prototype;
    var names = Object.getOwnPropertyNames(proto);
    for (var i = 0; i < names.length; i++) {
      var name = names[i];
      if (name === 'constructor') continue;
      var d = Object.getOwnPropertyDescriptor(proto, name);
      if (!d || !d.get) continue;
      (function(getter, propName, desc) {
        Object.defineProperty(proto, propName, {
          configurable: true,
          enumerable: desc.enumerable,
          get: asNative(function() {
            var v = getter.call(this);
            if (typeof v !== 'number') return v;
            var j = _tmJitter.get(this);
            return j === undefined ? v : v * j;
          }, propName),
        });
      })(d.get, name, d);
    }
  }
  function wrapMeasureText(proto, salt) {
    if (!proto) return;
    var orig = proto.measureText;
    if (typeof orig !== 'function') return;
    proto.measureText = asNative(function measureText(text) {
      var m = orig.apply(this, arguments);
      try {
        var rng = seededRng(salt + ':' + (text || ''));
        _tmJitter.set(m, 1.0 + (rng() - 0.5) * 0.0002);
      } catch (e) {}
      return m;
    }, 'measureText');
  }
  try {
    patchTextMetricsProto();
    if (typeof CanvasRenderingContext2D !== 'undefined') {
      wrapMeasureText(CanvasRenderingContext2D.prototype, 'canvas2d:measureText');
    }
    if (typeof OffscreenCanvasRenderingContext2D !== 'undefined') {
      wrapMeasureText(OffscreenCanvasRenderingContext2D.prototype, 'osc2d:measureText');
    }
  } catch (e) {}

  // --- WebGL: getParameter (vendor/renderer), getSupportedExtensions, readPixels ---
  // GL_VENDOR=7936, GL_RENDERER=7937, UNMASKED_VENDOR_WEBGL=37445,
  // UNMASKED_RENDERER_WEBGL=37446. The stock WebView returns strings like
  // "Google Inc. (Qualcomm)" / "ANGLE (Qualcomm, ...)" — fingerprintable
  // down to the device model. We replace with a constant generic identifier.
  function wrapWebGl(proto) {
    if (!proto) return;
    var origGetParam = proto.getParameter;
    if (typeof origGetParam === 'function') {
      proto.getParameter = asNative(function getParameter(p) {
        if (p === 37445 || p === 7936) return 'WebSpace';
        if (p === 37446 || p === 7937) return 'WebSpace WebGL';
        return origGetParam.apply(this, arguments);
      }, 'getParameter');
    }
    var origExt = proto.getSupportedExtensions;
    if (typeof origExt === 'function') {
      // Constant minimal extension list — masks GPU-specific extensions
      // like WEBGL_compressed_texture_etc that leak vendor identity.
      var FROZEN_EXT = Object.freeze([
        'OES_texture_float',
        'OES_element_index_uint',
        'WEBGL_depth_texture',
      ]);
      proto.getSupportedExtensions = asNative(function getSupportedExtensions() {
        return FROZEN_EXT.slice();
      }, 'getSupportedExtensions');
    }
    var origRead = proto.readPixels;
    if (typeof origRead === 'function') {
      proto.readPixels = asNative(function readPixels(x, y, w, h, fmt, type, pixels) {
        var ret = origRead.apply(this, arguments);
        try {
          if (pixels && pixels.length) {
            noisePixels(pixels, 'webgl:rp:' + x + ':' + y + ':' + w + ':' + h);
          }
        } catch (e) {}
        return ret;
      }, 'readPixels');
    }
  }
  try {
    if (typeof WebGLRenderingContext !== 'undefined' && WebGLRenderingContext.prototype) {
      wrapWebGl(WebGLRenderingContext.prototype);
    }
    if (typeof WebGL2RenderingContext !== 'undefined' && WebGL2RenderingContext.prototype) {
      wrapWebGl(WebGL2RenderingContext.prototype);
    }
  } catch (e) {}

  // --- Audio: AudioBuffer + AnalyserNode noise ---
  // Magnitudes are inaudibly small (1e-7 for waveform, 1e-4 for dB-scale
  // frequency data) — defeats hash-the-buffer fingerprints without
  // perturbing actual audio playback or analysis.
  function audioNoiseFloat(arr, salt, magnitude) {
    try {
      if (!arr || !arr.length) return;
      var rng = seededRng(salt);
      var n = arr.length;
      for (var i = 0; i < n; i++) {
        arr[i] = arr[i] + (rng() - 0.5) * magnitude;
      }
    } catch (e) {}
  }
  try {
    if (typeof AudioBuffer !== 'undefined' && AudioBuffer.prototype) {
      var bufProto = AudioBuffer.prototype;
      var origGetCh = bufProto.getChannelData;
      if (typeof origGetCh === 'function') {
        bufProto.getChannelData = asNative(function getChannelData(ch) {
          var data = origGetCh.apply(this, arguments);
          audioNoiseFloat(data, 'abuf:gc:' + ch, 1e-7);
          return data;
        }, 'getChannelData');
      }
      var origCopy = bufProto.copyFromChannel;
      if (typeof origCopy === 'function') {
        bufProto.copyFromChannel = asNative(function copyFromChannel(dest, ch, off) {
          var ret = origCopy.apply(this, arguments);
          audioNoiseFloat(dest, 'abuf:cp:' + ch + ':' + (off || 0), 1e-7);
          return ret;
        }, 'copyFromChannel');
      }
    }
    if (typeof AnalyserNode !== 'undefined' && AnalyserNode.prototype) {
      var anaProto = AnalyserNode.prototype;
      var origFFD = anaProto.getFloatFrequencyData;
      if (typeof origFFD === 'function') {
        anaProto.getFloatFrequencyData = asNative(function getFloatFrequencyData(arr) {
          var ret = origFFD.apply(this, arguments);
          audioNoiseFloat(arr, 'ana:freq', 1e-4);
          return ret;
        }, 'getFloatFrequencyData');
      }
      var origFTD = anaProto.getFloatTimeDomainData;
      if (typeof origFTD === 'function') {
        anaProto.getFloatTimeDomainData = asNative(function getFloatTimeDomainData(arr) {
          var ret = origFTD.apply(this, arguments);
          audioNoiseFloat(arr, 'ana:time', 1e-7);
          return ret;
        }, 'getFloatTimeDomainData');
      }
    }
  } catch (e) {}

  // --- Timing quantization ---
  // 100ms granularity defeats high-resolution-timer side channels (Spectre,
  // hardware fingerprinting via execution timing) without breaking normal
  // animation/loading code that tolerates >>16ms scheduling jitter anyway.
  try {
    if (typeof performance !== 'undefined' && typeof performance.now === 'function') {
      // On the PROTOTYPE. Assigning to `performance.now` creates an own
      // property, and a pristine engine's
      // `Object.getOwnPropertyNames(performance)` is empty, so the
      // quantization announced itself through the one enumeration the rest of
      // this file stays out of.
      var perfProto = Object.getPrototypeOf(performance);
      var nowDesc = perfProto
          ? Object.getOwnPropertyDescriptor(perfProto, 'now') : null;
      if (nowDesc && typeof nowDesc.value === 'function') {
        var origNow = nowDesc.value;
        perfProto.now = asNative(function now() {
          return Math.floor(origNow.call(this) / 100) * 100;
        }, 'now');
      } else {
        // Nothing on the prototype to patch. The instance reintroduces the own
        // property this branch exists to avoid, but an unquantized
        // high-resolution timer is an actual side channel.
        var origPerf = performance.now.bind(performance);
        performance.now = asNative(function now() {
          return Math.floor(origPerf() / 100) * 100;
        }, 'now');
      }
    }
  } catch (e) {}
  try {
    var origDateNow = Date.now;
    Date.now = asNative(function now() {
      return Math.floor(origDateNow.call(Date) / 100) * 100;
    }, 'now');
  } catch (e) {}

  // --- ClientRects sub-pixel jitter ---
  // ±0.001px jitter on x/y. Real browsers deliver fractional pixels for
  // sub-pixel layout; the magnitude is below the visible threshold but
  // above floating-point comparison fingerprints.
  //
  // Returns a real `DOMRect`. The object literal this used to build was
  // rejected by `instanceof DOMRect` and its prototype chain ended at
  // `Object`, so the noise was undetectable but the presence of the noise was
  // not, and any site that type-checked the result broke. `DOMRect` has a
  // public constructor, so there is nothing to fake.
  function jitterRect(r, salt) {
    if (!r) return r;
    try {
      var rng = seededRng(salt + ':' + r.x + ':' + r.y + ':' + r.width + ':' + r.height);
      var jx = (rng() - 0.5) * 0.001;
      var jy = (rng() - 0.5) * 0.001;
      if (typeof DOMRect === 'function') {
        return new DOMRect(r.x + jx, r.y + jy, r.width, r.height);
      }
    } catch (e) {}
    return r;
  }
  // getClientRects() was not wrapped at all, so the un-jittered geometry of
  // the same element was readable straight past getBoundingClientRect: both a
  // bypass and a disagreement between two APIs that must agree.
  //
  // It returns a `DOMRectList`, which has no constructor. Building on its
  // prototype keeps `instanceof DOMRectList` true and `Array.isArray` false,
  // with `length` shadowed as an own property because the inherited getter
  // only works on a platform object. Where the interface is absent the
  // array-like below is the fallback: a different type is a weaker tell than
  // handing back exact layout.
  function jitterRectList(list, salt) {
    try {
      var rects = [];
      for (var i = 0; i < list.length; i++) {
        rects.push(jitterRect(list[i], salt + ':' + i));
      }
      var out;
      if (typeof DOMRectList === 'function') {
        out = Object.create(DOMRectList.prototype);
        for (var j = 0; j < rects.length; j++) {
          Object.defineProperty(out, j, {
            configurable: true, enumerable: true, value: rects[j],
          });
        }
        // Shadowed as an own property: the inherited getter only works on a
        // platform object. Not attempted on the array fallback, where
        // redefining a non-configurable `length` throws.
        Object.defineProperty(out, 'length', {
          configurable: true, value: rects.length,
        });
      } else {
        out = rects;
      }
      Object.defineProperty(out, 'item', {
        configurable: true,
        value: asNative(function item(i) {
          return (i >>> 0) < this.length ? this[i] : null;
        }, 'item'),
      });
      return out;
    } catch (e) { return list; }
  }
  try {
    if (typeof Element !== 'undefined' && Element.prototype &&
        typeof Element.prototype.getBoundingClientRect === 'function') {
      var origGB = Element.prototype.getBoundingClientRect;
      Element.prototype.getBoundingClientRect = asNative(function getBoundingClientRect() {
        var r = origGB.apply(this, arguments);
        return jitterRect(r, 'rect:' + (this.tagName || ''));
      }, 'getBoundingClientRect');
      var origGCR = Element.prototype.getClientRects;
      if (typeof origGCR === 'function') {
        Element.prototype.getClientRects = asNative(function getClientRects() {
          return jitterRectList(origGCR.apply(this, arguments),
              'rects:' + (this.tagName || ''));
        }, 'getClientRects');
      }
    }
    if (typeof Range !== 'undefined' && Range.prototype &&
        typeof Range.prototype.getBoundingClientRect === 'function') {
      var origRangeGB = Range.prototype.getBoundingClientRect;
      Range.prototype.getBoundingClientRect = asNative(function getBoundingClientRect() {
        var r = origRangeGB.apply(this, arguments);
        return jitterRect(r, 'range');
      }, 'getBoundingClientRect');
      var origRangeGCR = Range.prototype.getClientRects;
      if (typeof origRangeGCR === 'function') {
        Range.prototype.getClientRects = asNative(function getClientRects() {
          return jitterRectList(origRangeGCR.apply(this, arguments), 'rangeRects');
        }, 'getClientRects');
      }
    }
  } catch (e) {}

  // --- document.fonts.check restriction ---
  // Font enumeration via FontFaceSet.check() is one of the highest-entropy
  // fingerprinting vectors — installed-font lists vary wildly per device.
  // We answer `true` only for a small allowlist of common platform fonts;
  // every other family reads as not-installed, even if it actually is.
  //
  // Installed on the prototype of the LIVE `document.fonts`. Assigning to the
  // instance put `check` in `Object.getOwnPropertyNames(document.fonts)`,
  // where a stock engine has none. The global `FontFaceSet` is not the right
  // target either: on Chromium `Object.getPrototypeOf(document.fonts)` is not
  // `FontFaceSet.prototype` and the global carries no `check` at all.
  try {
    var _fontsProto = (typeof document !== 'undefined' && document.fonts)
        ? Object.getPrototypeOf(document.fonts) : null;
    var _fontsTarget = (_fontsProto && typeof _fontsProto.check === 'function')
        ? _fontsProto
        // No prototype to patch. The instance reintroduces the own property,
        // but open font enumeration is the worse of the two.
        : ((typeof document !== 'undefined' && document.fonts &&
            typeof document.fonts.check === 'function') ? document.fonts : null);
    if (_fontsTarget) {
      var COMMON_FONTS = {
        'serif': 1, 'sans-serif': 1, 'monospace': 1,
        'cursive': 1, 'fantasy': 1, 'system-ui': 1,
        'arial': 1, 'helvetica': 1,
        'times': 1, 'times new roman': 1,
        'courier': 1, 'courier new': 1,
        'verdana': 1, 'georgia': 1, 'tahoma': 1,
        'trebuchet ms': 1, 'impact': 1,
      };
      _fontsTarget.check = asNative(function check(font) {
        try {
          var s = String(font || '').toLowerCase();
          var families = s.split(',');
          for (var i = 0; i < families.length; i++) {
            var f = families[i]
              .replace(/^([0-9.]+(px|em|rem|pt|%)?\\s+|bold\\s+|italic\\s+|normal\\s+|oblique\\s+)+/i, '')
              .replace(/['"]/g, '')
              .trim();
            if (COMMON_FONTS[f]) return true;
          }
          return false;
        } catch (e) { return false; }
      }, 'check');
    }
  } catch (e) {}
})();
''';
}
