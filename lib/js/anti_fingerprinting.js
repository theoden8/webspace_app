// Per-site anti-fingerprinting JavaScript shim.
//
// Injected at DOCUMENT_START into every frame when a site's umbrella
// `trackingProtectionEnabled` toggle is on. Surfaces covered:
//
//   * Canvas 2D     — every read (getImageData, toDataURL, toBlob,
//                      OffscreenCanvas) noised by the pixel's own block
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
//   * Hardware       — navigator.hardwareConcurrency, navigator.deviceMemory,
//                      navigator.maxTouchPoints
//   * Network        — navigator.connection (effectiveType/rtt/downlink/saveData)
//   * Plugins/MIME   — navigator.plugins / navigator.mimeTypes -> empty
//   * Battery        — navigator.getBattery() -> fixed values
//   * Speech         — speechSynthesis.getVoices() -> []
//   * Timing         — performance.now(), Date.now(), event and frame
//                      timestamps, timeOrigin: 5 ms steps, rounded at a
//                      seeded point per step
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
// desktop_mode.js and location_spoof.js use.
//
// The shim is wrapped in a re-entrance guard (`__ws_anti_fp_shim__`)
// because Android System WebView and WKWebView both re-run
// initialUserScripts on every frame; without the guard the second run
// would wrap the already-wrapped methods and amplify the noise.
//
// jsdom can exercise the shape (prototype methods replaced, getters
// installed) but not the noise on real Canvas/WebGL/Audio data — those
// engines are absent. End-to-end fingerprint proofing runs this script
// through Puppeteer + FingerprintJS in
// test/browser/fingerprint_real_engine.test.js.
(function() {
  'use strict';
  if (globalThis.__ws_anti_fp_shim__) return;
  globalThis.__ws_anti_fp_shim__ = true;

  var SEED = CONFIG.seed;
  var LETTERBOX = CONFIG.letterbox;

  // @include _native_fn.js

  // Mulberry32 PRNG keyed off a 32-bit FNV-1a hash of (SEED + ':' + salt).
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
  var HW_CONCURRENCY = 4 + (Math.floor(_baseRng() * 5) | 0);
  var DEVICE_MEMORY = (_baseRng() < 0.5) ? 4 : 8;

  // Correct only what the engine already exposes. Defining a property the
  // real engine lacks is a one-expression tell (`'x' in navigator`), the
  // same leak class as the own-property override ETP-010 already forbids.
  function hasOnNav(name) {
    try {
      return typeof navigator !== 'undefined' && !!navigator &&
        (name in navigator);
    } catch (e) { return false; }
  }

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
  // Rewrite every device-dimension feature in the query, whatever surrounds
  // it (media type, `not`, `and`, comma lists, range syntax, em or cm
  // lengths, device-aspect-ratio), and answer against the SAME dimensions
  // screen.* reports: window.inner* in letterbox mode (the box is
  // physically real), the pinned SCREEN_W/H otherwise. A single feature is
  // answered here; a compound query has each feature replaced by a
  // standard one that is always true or always false and is then handed to
  // the engine, so its boolean structure is the engine's to evaluate.
  try {
    if (typeof globalThis.matchMedia === 'function') {
      var _origMatchMedia = globalThis.matchMedia.bind(globalThis);
      var DEVICE_FEATURE_RE =
        /\(\s*([^()]*device-(?:width|height|aspect-ratio)[^()]*)\)/gi;
      var SINGLE_FEATURE_RE = /^\s*\(\s*([^()]*)\)\s*$/;
      var UNIT_PX = {
        '': 1, px: 1, em: 16, rem: 16, 'in': 96, cm: 96 / 2.54, mm: 96 / 25.4,
        q: 96 / 101.6, pt: 96 / 72, pc: 16,
      };
      function _targetDim(which) {
        if (LETTERBOX) {
          return which === 'width' ? globalThis.innerWidth : globalThis.innerHeight;
        }
        return which === 'width' ? SCREEN_W : SCREEN_H;
      }
      function _actual(feature) {
        if (feature === 'aspect-ratio') {
          return _targetDim('width') / _targetDim('height');
        }
        return _targetDim(feature);
      }
      function _value(text, feature) {
        text = text.trim();
        if (feature === 'aspect-ratio') {
          var r = /^([\d.]+)\s*(?:\/\s*([\d.]+))?$/.exec(text);
          if (!r) return NaN;
          return parseFloat(r[1]) / (r[2] ? parseFloat(r[2]) : 1);
        }
        var m = /^([\d.]+)\s*([a-z]*)$/i.exec(text);
        if (!m) return NaN;
        var unit = UNIT_PX[m[2].toLowerCase()];
        return unit === undefined ? NaN : parseFloat(m[1]) * unit;
      }
      function _cmp(a, op, b) {
        if (op === '<') return a < b;
        if (op === '<=') return a <= b;
        if (op === '>') return a > b;
        if (op === '>=') return a >= b;
        return Math.abs(a - b) < 1e-6;
      }
      function _flip(op) {
        return op === '<' ? '>' : op === '<=' ? '>=' :
          op === '>' ? '<' : op === '>=' ? '<=' : op;
      }
      // The truth of one device feature against the spoofed screen, or null
      // when the text is not something this parses (left to the engine).
      function _evalDeviceFeature(inner) {
        var m = /^\s*(min-|max-)?device-(width|height|aspect-ratio)\s*:\s*(.+?)\s*$/i.exec(inner);
        if (m) {
          var feature = m[2].toLowerCase();
          var v = _value(m[3], feature);
          if (isNaN(v)) return null;
          var prefix = (m[1] || '').toLowerCase();
          return _cmp(_actual(feature),
            prefix === 'min-' ? '>=' : (prefix === 'max-' ? '<=' : '='), v);
        }
        m = /^\s*device-(width|height|aspect-ratio)\s*$/i.exec(inner);
        if (m) return _actual(m[1].toLowerCase()) > 0;
        m = /^\s*device-(width|height|aspect-ratio)\s*(<=|>=|<|>|=)\s*(.+?)\s*$/i.exec(inner);
        if (m) {
          var f1 = m[1].toLowerCase();
          var v1 = _value(m[3], f1);
          return isNaN(v1) ? null : _cmp(_actual(f1), m[2], v1);
        }
        m = /^\s*(.+?)\s*(<=|>=|<|>|=)\s*device-(width|height|aspect-ratio)\s*(?:(<=|>=|<|>)\s*(.+?))?\s*$/i.exec(inner);
        if (m) {
          var f2 = m[3].toLowerCase();
          var actual = _actual(f2);
          var lo = _value(m[1], f2);
          if (isNaN(lo)) return null;
          var ok = _cmp(actual, _flip(m[2]), lo);
          if (m[4]) {
            var hi = _value(m[5], f2);
            if (isNaN(hi)) return null;
            ok = ok && _cmp(actual, m[4], hi);
          }
          return ok;
        }
        return null;
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
          if (typeof query === 'string' &&
              /device-(width|height|aspect-ratio)/i.test(query)) {
            var single = SINGLE_FEATURE_RE.exec(query);
            if (single) {
              var v = _evalDeviceFeature(single[1]);
              if (v !== null) return _syntheticMql(query, v);
            } else {
              var complete = true;
              var rewritten = query.replace(DEVICE_FEATURE_RE, function(whole, inner) {
                var r = _evalDeviceFeature(inner);
                if (r === null) { complete = false; return whole; }
                return r ? '(min-width: 0px)' : '(min-width: 99999999px)';
              });
              if (complete) {
                return _syntheticMql(query, !!_origMatchMedia(rewritten).matches);
              }
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
  //
  // deviceMemory is Chromium-only: absent on the WebKit builds behind iOS,
  // macOS and Linux, so defining it unconditionally ADDED a property those
  // engines lack.
  try {
    if (hasOnNav('hardwareConcurrency')) {
      defineGetterOnProto(NavProto, 'hardwareConcurrency', HW_CONCURRENCY);
    }
    if (hasOnNav('deviceMemory')) {
      defineGetterOnProto(NavProto, 'deviceMemory', DEVICE_MEMORY);
    }
  } catch (e) {}

  // --- navigator.maxTouchPoints ---
  // Reports the real digitizer count (5 or 10 on a phone) and so contradicts
  // the desktop screen size. The desktop-mode shim runs after this one and
  // sets its own value for desktop UAs; this is the mobile-UA case, which
  // had no coverage.
  try {
    if (hasOnNav('maxTouchPoints')) {
      defineGetterOnProto(NavProto, 'maxTouchPoints', 0);
    }
  } catch (e) {}

  // --- navigator.connection (NetworkInformation) ---
  // Present on WorkerNavigator too, which is why this is not in the
  // window-only section. `effectiveType`/`rtt`/`downlink` describe the
  // user's link, change as they move between networks, and are readable
  // without any permission — a coarse location and mobility signal. Only
  // the values are corrected; the object is left in place because removing
  // a property a real WebView has is itself the tell.
  try {
    if (NavProto && 'connection' in NavProto) {
      var conn = navigator.connection;
      if (conn) {
        var connProto = Object.getPrototypeOf(conn);
        // Correct only what is already there. `NetworkInformation.type` does
        // not exist on every build — measured absent on desktop Chromium and
        // present on mobile — so defining it unconditionally ADDED a property
        // the engine lacks, which is both the rule this file states and a
        // one-expression tell: `'type' in navigator.connection` answered
        // false natively and true under the shim.
        function correct(name, value) {
          if (!(name in connProto)) return;
          defineGetterOnProto(connProto, name, value);
        }
        correct('effectiveType', '4g');
        correct('type', 'wifi');
        correct('rtt', 50);
        correct('downlink', 10);
        correct('downlinkMax', Infinity);
        correct('saveData', false);
        // The engine still fires `change` when the real link changes. A
        // listener that wakes up and reads the same constants back is a
        // contradiction no real device produces, and the event's mere timing
        // tracks the user moving between networks. Drop the delivery: with
        // static values there is nothing truthful left to announce.
        var origConnAdd = connProto.addEventListener;
        if (typeof origConnAdd === 'function') {
          connProto.addEventListener = asNative(
              function addEventListener(type) {
            if (type === 'change') return;
            return origConnAdd.apply(this, arguments);
          }, 'addEventListener');
        }
        // Reading back what was just assigned is the observable half of an
        // event-handler property, and a slot that always answers null is the
        // one-expression tell this block exists to avoid. Keep the value off
        // the engine instead: it round-trips, and nothing ever registers it,
        // so it cannot fire. A non-function assigns as null, as natively.
        var _connOnChange = new WeakMap();
        Object.defineProperty(connProto, 'onchange', {
          configurable: true,
          enumerable: true,
          get: asNative(function onchange() {
            var v = _connOnChange.get(this);
            return v === undefined ? null : v;
          }, 'onchange'),
          set: asNative(function onchange(v) {
            _connOnChange.set(this, typeof v === 'function' ? v : null);
          }, 'onchange'),
        });
      }
    }
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
  // Window-only: the Battery API is not exposed to workers (see plugins above),
  // and Chromium-only: WebKit has no navigator.getBattery at all, so this is
  // corrected where it exists rather than introduced where it does not.
  try {
    if (NavProto && !IS_WORKER && hasOnNav('getBattery')) {
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

  // --- Canvas 2D: seeded noise on every read (ETP-005) ---
  // A pixel's noise is a function of the seed and the raw 3x3 block around
  // it, so every way of reading a canvas agrees with every other: any
  // rectangle, getImageData, toDataURL, toBlob, an OffscreenCanvas (SEC-018),
  // a copy drawn elsewhere. Only an opaque pixel that differs from at least
  // three of its four neighbours can move, about one in 32 of those, by one
  // step of red: the anti-aliased edges text and curves leave, never a solid
  // fill, a straight edge or a one-pixel line a page drew to compare against,
  // nor a partly transparent pixel, whose values premultiplied alpha
  // constrains. What the page wrote with putImageData reads back as written
  // while it is still there. Nothing is painted onto the page's canvas: an
  // encode reads a noised copy. A context or canvas from another frame is
  // read through that frame's own shim.
  var NOISE_KEY = hashStr(SEED + ':canvas2d');
  var _puts = new WeakMap();
  var _contexts = new WeakMap();
  var PUT_MAX_PIXELS = 65536;
  var PUT_RECORDS = 4;

  // A canvas's bytes, wherever its array was made.
  function isBytes(d) {
    return Object.prototype.toString.call(d) === '[object Uint8ClampedArray]';
  }

  function words(bytes) {
    return new Uint32Array(bytes.buffer, bytes.byteOffset, bytes.length >> 2);
  }

  // Whether canvas pixel (cx, cy) still holds what a put the page made
  // there wrote.
  function putAt(records, cx, cy, raw) {
    for (var r = records.length - 1; r >= 0; r--) {
      var rec = records[r];
      var lx = cx - rec.x, ly = cy - rec.y;
      if (lx >= 0 && ly >= 0 && lx < rec.w && ly < rec.h) {
        return rec.px[ly * rec.w + lx] === raw;
      }
    }
    return false;
  }

  // Noise the w x h pixels in [out], read at canvas (x0, y0), from [pad]:
  // the same pixels read with one more on each side. The noise sets a
  // chosen pixel's lowest red bit from the block with that bit masked out,
  // so noising a read again changes nothing: a decoded encode, or a read
  // put back, reads as the first read did.
  var RED_LSB = new Uint8Array(new Uint32Array([1]).buffer)[0] === 1 ? 1 : 0x01000000;
  var KEEP = ~RED_LSB;
  function canvasNoise(out, pad, w, h, x0, y0, records) {
    var rw = w + 2;
    var p = words(pad);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var i = (y * w + x) * 4;
        if (out[i + 3] !== 255) continue;
        var c = (y + 1) * rw + (x + 1);
        var v = p[c] & KEEP;
        var pick = Math.imul(NOISE_KEY ^ v, 16777619) >>> 0;
        pick ^= pick >>> 13;
        pick = Math.imul(pick, 0x5bd1e995) >>> 0;
        pick ^= pick >>> 15;
        if ((pick & 15) !== 0) continue;
        var differs = ((p[c - 1] & KEEP) !== v) + ((p[c + 1] & KEEP) !== v) +
          ((p[c - rw] & KEEP) !== v) + ((p[c + rw] & KEEP) !== v);
        if (differs < 3) continue;
        if (records && putAt(records, x0 + x, y0 + y, p[c])) continue;
        // The neighbours summed, not chained, so a flipped read (WebGL's
        // rows run bottom up) or a turned copy noises the pixel alike.
        var bit = pick;
        for (var dy = -rw; dy <= rw; dy += rw) {
          for (var dx = -1; dx <= 1; dx++) {
            var q = Math.imul((p[c + dy + dx] & KEEP) ^ NOISE_KEY, 0x9e3779b1);
            bit = (bit + (q ^ (q >>> 16))) >>> 0;
          }
        }
        bit = Math.imul(bit ^ (bit >>> 15), 0x2c1b3c6d) >>> 0;
        out[i] = (out[i] & 0xFE) | ((bit >>> 9) & 1);
      }
    }
  }

  // getImageData's rectangle as the engine takes it: truncated, a negative
  // size flipping it.
  function readRect(args) {
    var x = Math.trunc(+args[0] || 0), y = Math.trunc(+args[1] || 0);
    var w = Math.trunc(+args[2] || 0), h = Math.trunc(+args[3] || 0);
    if (w < 0) { x += w; w = -w; }
    if (h < 0) { y += h; h = -h; }
    return { x: x, y: y, w: w, h: h };
  }

  function recordPut(ctx, args) {
    try {
      var img = args[0];
      if (args.length !== 3 || !img || !isBytes(img.data)) return;
      if (img.width * img.height > PUT_MAX_PIXELS) return;
      var records = _puts.get(ctx);
      if (!records) { records = []; _puts.set(ctx, records); }
      records.push({
        x: Math.trunc(+args[1] || 0), y: Math.trunc(+args[2] || 0),
        w: img.width, h: img.height, px: new Uint32Array(words(img.data)),
      });
      if (records.length > PUT_RECORDS) records.shift();
    } catch (e) {}
  }

  // The method [name] of [obj]'s own realm when it is another frame's, so
  // that frame's shim, which saw its contexts and puts, answers.
  function otherRealm(obj, proto, name) {
    try {
      if (obj instanceof proto.constructor) return null;
      var own = Object.getPrototypeOf(obj);
      var fn = own && own[name];
      return typeof fn === 'function' ? fn : null;
    } catch (e) {
      return null;
    }
  }

  // One canvas kind, on-screen or offscreen: its context getter records the
  // context each canvas was given, its 2D context's reads are noised and
  // its puts recorded, and an encode reads a noised copy made by [make].
  function canvasKind(canvasProto, ctxProto, make) {
    var origGetContext = canvasProto.getContext;
    var origGet = ctxProto.getImageData;
    var origPut = ctxProto.putImageData;
    var origAttrs = ctxProto.getContextAttributes;
    var widthOf = Object.getOwnPropertyDescriptor(canvasProto, 'width');
    var heightOf = Object.getOwnPropertyDescriptor(canvasProto, 'height');
    if (typeof origGetContext !== 'function' || typeof origGet !== 'function' ||
        typeof origPut !== 'function' || !widthOf || !heightOf) return null;

    canvasProto.getContext = asNative(function getContext(contextId) {
      var ctx = origGetContext.apply(this, arguments);
      try { if (ctx) _contexts.set(this, ctx); } catch (e) {}
      return ctx;
    }, 'getContext');

    ctxProto.getImageData = asNative(function getImageData(sx, sy, sw, sh) {
      var other = otherRealm(this, ctxProto, 'getImageData');
      if (other) return other.apply(this, arguments);
      var img = origGet.apply(this, arguments);
      try {
        var d = img && img.data;
        if (isBytes(d) && img.width && img.height) {
          var r = readRect(arguments);
          var pad = origGet.call(this, r.x - 1, r.y - 1,
            img.width + 2, img.height + 2, arguments[4]);
          canvasNoise(d, pad.data, img.width, img.height, r.x, r.y, _puts.get(this));
        }
      } catch (e) {}
      return img;
    }, 'getImageData');

    ctxProto.putImageData = asNative(function putImageData(imagedata, dx, dy) {
      var result = origPut.apply(this, arguments);
      recordPut(this, arguments);
      return result;
    }, 'putImageData');

    return function noisedCopy(canvas) {
      try {
        var ctx = _contexts.get(canvas);
        if (!ctx || !(ctx instanceof ctxProto.constructor)) return null;
        var w = widthOf.get.call(canvas), h = heightOf.get.call(canvas);
        if (!w || !h) return null;
        var img = origGet.call(ctx, 0, 0, w, h);
        var pad = origGet.call(ctx, -1, -1, w + 2, h + 2);
        canvasNoise(img.data, pad.data, w, h, 0, 0, _puts.get(ctx));
        var attrs = typeof origAttrs === 'function' ? origAttrs.call(ctx) : null;
        var copy = make(w, h, widthOf, heightOf);
        var copyCtx = origGetContext.call(copy, '2d',
          attrs && attrs.colorSpace ? { colorSpace: attrs.colorSpace } : undefined);
        origPut.call(copyCtx, img, 0, 0);
        return copy;
      } catch (e) {
        return null;
      }
    };
  }

  // An encode of [canvas] through [orig]: another frame's canvas by that
  // frame's own method, a 2D one from its noised copy, any other as it is.
  function encodeWith(orig, name, proto, noisedCopy) {
    return function(canvas, args) {
      var other = otherRealm(canvas, proto, name);
      if (other) return other.apply(canvas, args);
      return orig.apply(noisedCopy(canvas) || canvas, args);
    };
  }

  try {
    if (typeof HTMLCanvasElement !== 'undefined' && HTMLCanvasElement.prototype &&
        typeof CanvasRenderingContext2D !== 'undefined' &&
        CanvasRenderingContext2D.prototype && typeof document !== 'undefined') {
      var canProto = HTMLCanvasElement.prototype;
      var origCreate = Document.prototype.createElement;
      var copy2d = canvasKind(canProto, CanvasRenderingContext2D.prototype,
        function(w, h, widthOf, heightOf) {
          var c = origCreate.call(document, 'canvas');
          widthOf.set.call(c, w);
          heightOf.set.call(c, h);
          return c;
        });
      if (copy2d) {
        var origToDataURL = canProto.toDataURL;
        if (typeof origToDataURL === 'function') {
          var encodeToDataURL = encodeWith(origToDataURL, 'toDataURL', canProto, copy2d);
          canProto.toDataURL = asNative(function toDataURL() {
            return encodeToDataURL(this, arguments);
          }, 'toDataURL');
        }
        var origToBlob = canProto.toBlob;
        if (typeof origToBlob === 'function') {
          var encodeToBlob = encodeWith(origToBlob, 'toBlob', canProto, copy2d);
          canProto.toBlob = asNative(function toBlob(callback) {
            return encodeToBlob(this, arguments);
          }, 'toBlob');
        }
      }
    }
    // An OffscreenCanvas reads the same way, in page and worker scope, and
    // is where a page copies a covered canvas to read it clean (SEC-018).
    if (typeof OffscreenCanvas !== 'undefined' && OffscreenCanvas.prototype &&
        typeof OffscreenCanvasRenderingContext2D !== 'undefined' &&
        OffscreenCanvasRenderingContext2D.prototype) {
      var oscCanProto = OffscreenCanvas.prototype;
      var OSC = OffscreenCanvas;
      var copyOsc = canvasKind(oscCanProto, OffscreenCanvasRenderingContext2D.prototype,
        function(w, h) { return new OSC(w, h); });
      var origConvertToBlob = oscCanProto.convertToBlob;
      if (copyOsc && typeof origConvertToBlob === 'function') {
        var encodeConvert = encodeWith(origConvertToBlob, 'convertToBlob', oscCanProto, copyOsc);
        oscCanProto.convertToBlob = asNative(function convertToBlob() {
          return encodeConvert(this, arguments);
        }, 'convertToBlob');
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
      // The canvas noise on an RGBA read into memory, so a pixel reads the
      // same through any rectangle here too; a read into a bound buffer, or
      // in another format, goes as it is.
      proto.readPixels = asNative(function readPixels(x, y, width, height, format, type, pixels) {
        var ret = origRead.apply(this, arguments);
        try {
          var w = Math.trunc(+width || 0), h = Math.trunc(+height || 0);
          if (arguments.length === 7 && format === this.RGBA &&
              type === this.UNSIGNED_BYTE &&
              Object.prototype.toString.call(pixels) === '[object Uint8Array]' &&
              w > 0 && h > 0 && pixels.length >= w * h * 4) {
            var pad = new Uint8Array((w + 2) * (h + 2) * 4);
            origRead.call(this, x - 1, y - 1, w + 2, h + 2, format, type, pad);
            canvasNoise(pixels, pad, w, h, 0, 0, null);
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

  // --- Timing (ETP-012) ---
  // Every clock a page reads directly is rounded to a 5 ms step that rounds
  // up at a point drawn per step from the seed: a script waiting for the
  // clock to tick cannot tell where in real time the tick fell, and a
  // renderer that yields after 5 ms still sees time pass. One function per
  // time base, so performance.now(), event and frame timestamps agree.
  var CLOCK_STEP = 5;
  function steppedClock(salt) {
    var lastStep = NaN;
    var lastPoint = 0;
    return function(t) {
      var step = Math.floor(t / CLOCK_STEP);
      if (step !== lastStep) {
        lastStep = step;
        lastPoint = (step + hashStr(SEED + ':' + salt + ':' + step) / 4294967296) *
            CLOCK_STEP;
      }
      return (t < lastPoint ? step : step + 1) * CLOCK_STEP;
    };
  }
  var sinceOrigin = steppedClock('origin');
  var sinceEpoch = steppedClock('epoch');
  try {
    if (typeof performance !== 'undefined' && typeof performance.now === 'function') {
      // On the PROTOTYPE. Assigning to `performance.now` creates an own
      // property, and a pristine engine's
      // `Object.getOwnPropertyNames(performance)` is empty, so the
      // rounding announced itself through the one enumeration the rest of
      // this file stays out of.
      var perfProto = Object.getPrototypeOf(performance);
      var nowDesc = perfProto
          ? Object.getOwnPropertyDescriptor(perfProto, 'now') : null;
      if (nowDesc && typeof nowDesc.value === 'function') {
        var origNow = nowDesc.value;
        perfProto.now = asNative(function now() {
          return sinceOrigin(origNow.call(this));
        }, 'now');
      } else {
        // Nothing on the prototype to patch. The instance reintroduces the own
        // property this branch exists to avoid, but an unrounded
        // high-resolution timer is an actual side channel.
        var origPerf = performance.now.bind(performance);
        performance.now = asNative(function now() {
          return sinceOrigin(origPerf());
        }, 'now');
      }
      var originDesc = perfProto
          ? Object.getOwnPropertyDescriptor(perfProto, 'timeOrigin') : null;
      if (originDesc && originDesc.get) {
        var origOrigin = originDesc.get;
        defineGetterFnOnProto(perfProto, 'timeOrigin', function() {
          return sinceEpoch(origOrigin.call(this));
        });
      }
    }
  } catch (e) {}
  try {
    var origDateNow = Date.now;
    Date.now = asNative(function now() {
      return sinceEpoch(origDateNow.call(Date));
    }, 'now');
  } catch (e) {}
  try {
    var stampDesc = typeof Event !== 'undefined'
        ? Object.getOwnPropertyDescriptor(Event.prototype, 'timeStamp') : null;
    if (stampDesc && stampDesc.get) {
      var origStamp = stampDesc.get;
      defineGetterFnOnProto(Event.prototype, 'timeStamp', function() {
        return sinceOrigin(origStamp.call(this));
      });
    }
  } catch (e) {}
  try {
    if (typeof globalThis.requestAnimationFrame === 'function') {
      var origRaf = globalThis.requestAnimationFrame;
      globalThis.requestAnimationFrame = asNative(function requestAnimationFrame(callback) {
        if (typeof callback !== 'function') return origRaf.apply(this, arguments);
        return origRaf.call(this, function(time) {
          return callback.call(this, sinceOrigin(time));
        });
      }, 'requestAnimationFrame');
    }
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
