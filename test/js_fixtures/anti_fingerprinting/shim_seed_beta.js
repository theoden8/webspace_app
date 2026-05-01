(function() {
  'use strict';
  if (window.__ws_anti_fp_shim__) return;
  window.__ws_anti_fp_shim__ = true;

  var SEED = "beta-fixture-seed";

  // Shared Function.prototype.toString stubs — same WeakMap as
  // desktop_mode_shim.dart and location_spoof_service.dart so all three
  // shims funnel through one patched toString.
  var _origFnToString = Function.prototype.toString;
  var _stubs = window.__wsFnStubs || new WeakMap();
  window.__wsFnStubs = _stubs;
  function asNative(fn, name) {
    try { _stubs.set(fn, 'function ' + name + '() { [native code] }'); } catch (e) {}
    return fn;
  }
  if (!window.__wsFnToStringPatched) {
    window.__wsFnToStringPatched = true;
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

  // --- screen.* ---
  try {
    if (typeof Screen !== 'undefined' && Screen.prototype) {
      defineGetterOnProto(Screen.prototype, 'width', SCREEN_W);
      defineGetterOnProto(Screen.prototype, 'height', SCREEN_H);
      defineGetterOnProto(Screen.prototype, 'availWidth', SCREEN_W);
      defineGetterOnProto(Screen.prototype, 'availHeight', SCREEN_H - 40);
      defineGetterOnProto(Screen.prototype, 'colorDepth', COLOR_DEPTH);
      defineGetterOnProto(Screen.prototype, 'pixelDepth', COLOR_DEPTH);
    }
  } catch (e) {}

  // --- navigator.hardwareConcurrency / deviceMemory ---
  var NavProto = (typeof Navigator !== 'undefined') ? Navigator.prototype : null;
  try {
    defineGetterOnProto(NavProto, 'hardwareConcurrency', HW_CONCURRENCY);
    defineGetterOnProto(NavProto, 'deviceMemory', DEVICE_MEMORY);
  } catch (e) {}

  // --- navigator.plugins / mimeTypes -> empty array-likes ---
  // A real PluginArray has length, item(), namedItem(), refresh(). Returning
  // a plain array would leak the override; we synthesize the missing methods.
  try {
    function makeEmptyArrayLike(name) {
      var arr = [];
      Object.defineProperty(arr, 'length', { value: 0, configurable: true });
      Object.defineProperty(arr, 'item', {
        value: asNative(function() { return null; }, 'item'),
        configurable: true,
      });
      Object.defineProperty(arr, 'namedItem', {
        value: asNative(function() { return null; }, 'namedItem'),
        configurable: true,
      });
      if (name === 'plugins') {
        Object.defineProperty(arr, 'refresh', {
          value: asNative(function() {}, 'refresh'),
          configurable: true,
        });
      }
      return arr;
    }
    var emptyPlugins = makeEmptyArrayLike('plugins');
    var emptyMimeTypes = makeEmptyArrayLike('mimeTypes');
    defineGetterOnProto(NavProto, 'plugins', emptyPlugins);
    defineGetterOnProto(NavProto, 'mimeTypes', emptyMimeTypes);
  } catch (e) {}

  // --- navigator.getBattery -> fixed values ---
  try {
    if (NavProto) {
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
      function nudgeCanvas(canvas, salt) {
        try {
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
  function wrapMeasureText(proto, salt) {
    if (!proto) return;
    var orig = proto.measureText;
    if (typeof orig !== 'function') return;
    proto.measureText = asNative(function measureText(text) {
      var m = orig.apply(this, arguments);
      try {
        var rng = seededRng(salt + ':' + (text || ''));
        var jitter = 1.0 + (rng() - 0.5) * 0.0002;
        var wrapped = {};
        for (var k in m) {
          var v;
          try { v = m[k]; } catch (e) { continue; }
          if (typeof v === 'number') {
            wrapped[k] = v * jitter;
          } else {
            wrapped[k] = v;
          }
        }
        return wrapped;
      } catch (e) {}
      return m;
    }, 'measureText');
  }
  try {
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
      var origPerf = performance.now.bind(performance);
      performance.now = asNative(function now() {
        return Math.floor(origPerf() / 100) * 100;
      }, 'now');
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
  function jitterRect(r, salt) {
    if (!r) return r;
    try {
      var rng = seededRng(salt + ':' + r.x + ':' + r.y + ':' + r.width + ':' + r.height);
      var jx = (rng() - 0.5) * 0.001;
      var jy = (rng() - 0.5) * 0.001;
      return {
        x: r.x + jx, y: r.y + jy,
        left: (r.left != null ? r.left : r.x) + jx,
        top: (r.top != null ? r.top : r.y) + jy,
        right: (r.right != null ? r.right : (r.x + r.width)) + jx,
        bottom: (r.bottom != null ? r.bottom : (r.y + r.height)) + jy,
        width: r.width,
        height: r.height,
        toJSON: function() {
          return { x: this.x, y: this.y, width: this.width, height: this.height,
                   left: this.left, top: this.top, right: this.right, bottom: this.bottom };
        },
      };
    } catch (e) { return r; }
  }
  try {
    if (typeof Element !== 'undefined' && Element.prototype &&
        typeof Element.prototype.getBoundingClientRect === 'function') {
      var origGB = Element.prototype.getBoundingClientRect;
      Element.prototype.getBoundingClientRect = asNative(function getBoundingClientRect() {
        var r = origGB.apply(this, arguments);
        return jitterRect(r, 'rect:' + (this.tagName || ''));
      }, 'getBoundingClientRect');
    }
    if (typeof Range !== 'undefined' && Range.prototype &&
        typeof Range.prototype.getBoundingClientRect === 'function') {
      var origRangeGB = Range.prototype.getBoundingClientRect;
      Range.prototype.getBoundingClientRect = asNative(function getBoundingClientRect() {
        var r = origRangeGB.apply(this, arguments);
        return jitterRect(r, 'range');
      }, 'getBoundingClientRect');
    }
  } catch (e) {}

  // --- document.fonts.check restriction ---
  // Font enumeration via FontFaceSet.check() is one of the highest-entropy
  // fingerprinting vectors — installed-font lists vary wildly per device.
  // We answer `true` only for a small allowlist of common platform fonts;
  // every other family reads as not-installed, even if it actually is.
  try {
    if (typeof document !== 'undefined' && document.fonts &&
        typeof document.fonts.check === 'function') {
      var COMMON_FONTS = {
        'serif': 1, 'sans-serif': 1, 'monospace': 1,
        'cursive': 1, 'fantasy': 1, 'system-ui': 1,
        'arial': 1, 'helvetica': 1,
        'times': 1, 'times new roman': 1,
        'courier': 1, 'courier new': 1,
        'verdana': 1, 'georgia': 1, 'tahoma': 1,
        'trebuchet ms': 1, 'impact': 1,
      };
      document.fonts.check = asNative(function check(font) {
        try {
          var s = String(font || '').toLowerCase();
          var families = s.split(',');
          for (var i = 0; i < families.length; i++) {
            var f = families[i]
              .replace(/^([0-9.]+(px|em|rem|pt|%)?\s+|bold\s+|italic\s+|normal\s+|oblique\s+)+/i, '')
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
