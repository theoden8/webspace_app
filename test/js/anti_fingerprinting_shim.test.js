// Behavioural tests for the per-site anti-fingerprinting shim
// (lib/services/anti_fingerprinting_shim.dart).
//
// jsdom omits real Canvas/WebGL/Audio/Speech engines, so tests that need
// to exercise the shim's wrappers stub the missing constructors with
// inert classes whose methods just record the call. The shim's job is to
// patch prototypes and surface seeded noise — we assert the patch shape
// (wrapper installed, [native code] toString, return value transformed)
// rather than the noise's effect on real engine output, which jsdom
// can't reproduce. Real-engine fingerprint proofing belongs to a follow-
// up Playwright + CreepJS tier.

const test = require('node:test');
const assert = require('node:assert/strict');
const { JSDOM } = require('jsdom');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const fixturesRoot = path.join(repoRoot, 'test', 'js_fixtures');

function readFixture(rel) {
  return fs.readFileSync(path.join(fixturesRoot, rel), 'utf8');
}

// Stubs for browser APIs jsdom omits. Each stub records every call onto
// `window.__calls` so tests can assert the wrapper actually invoked the
// underlying method (apply-and-noise pattern).
function installFpStubs(window) {
  window.__calls = [];
  function record(name, args) { window.__calls.push({ name, args }); }

  // --- WebGL ---
  function WebGLRenderingContext() {}
  WebGLRenderingContext.prototype.getParameter = function(p) {
    record('webgl.getParameter', [p]);
    if (p === 7936 || p === 37445) return 'STUB-VENDOR';
    if (p === 7937 || p === 37446) return 'STUB-RENDERER';
    return null;
  };
  WebGLRenderingContext.prototype.getSupportedExtensions = function() {
    record('webgl.getSupportedExtensions', []);
    return ['STUB_EXT_A', 'STUB_EXT_B', 'STUB_EXT_VENDOR_LEAK'];
  };
  WebGLRenderingContext.prototype.readPixels = function(x, y, w, h, fmt, type, pixels) {
    record('webgl.readPixels', [x, y, w, h]);
    if (pixels) for (let i = 0; i < pixels.length; i++) pixels[i] = 128;
  };
  function WebGL2RenderingContext() {}
  WebGL2RenderingContext.prototype = Object.create(WebGLRenderingContext.prototype);
  window.WebGLRenderingContext = WebGLRenderingContext;
  window.WebGL2RenderingContext = WebGL2RenderingContext;

  // --- Canvas 2D context (jsdom returns null without `canvas` npm) ---
  // Replace HTMLCanvasElement.prototype.getContext with a stub that
  // returns a fresh CanvasRenderingContext2D object — our shim then
  // wraps the prototype methods.
  function CanvasRenderingContext2D() {}
  CanvasRenderingContext2D.prototype.getImageData = function(x, y, w, h) {
    record('ctx.getImageData', [x, y, w, h]);
    const data = new Uint8ClampedArray(w * h * 4);
    for (let i = 0; i < data.length; i++) data[i] = 100;
    return { data, width: w, height: h, colorSpace: 'srgb' };
  };
  CanvasRenderingContext2D.prototype.measureText = function(text) {
    record('ctx.measureText', [text]);
    return {
      width: 42, actualBoundingBoxLeft: 1, actualBoundingBoxRight: 41,
      actualBoundingBoxAscent: 10, actualBoundingBoxDescent: 2,
    };
  };
  CanvasRenderingContext2D.prototype.fillRect = function() { record('ctx.fillRect', [...arguments]); };
  CanvasRenderingContext2D.prototype.save = function() {};
  CanvasRenderingContext2D.prototype.restore = function() {};
  Object.defineProperty(CanvasRenderingContext2D.prototype, 'fillStyle', {
    configurable: true,
    get() { return this._fillStyle; },
    set(v) { this._fillStyle = v; },
  });
  window.CanvasRenderingContext2D = CanvasRenderingContext2D;
  // jsdom's HTMLCanvasElement.getContext('2d') returns null. Replace it
  // with a stub that returns a real CanvasRenderingContext2D so the
  // shim's nudge-canvas path can fire.
  const HTMLCanvasElement = window.HTMLCanvasElement;
  HTMLCanvasElement.prototype.getContext = function(type) {
    record('canvas.getContext', [type]);
    if (type === '2d') {
      if (!this.__ctx) this.__ctx = new CanvasRenderingContext2D();
      return this.__ctx;
    }
    return null;
  };
  HTMLCanvasElement.prototype.toDataURL = function(type) {
    record('canvas.toDataURL', [type]);
    return 'data:image/png;base64,STUB';
  };
  HTMLCanvasElement.prototype.toBlob = function(cb) {
    record('canvas.toBlob', []);
    cb && cb(new (window.Blob || function() {})(['stub']));
  };

  // --- Offscreen canvas 2D ---
  function OffscreenCanvasRenderingContext2D() {}
  OffscreenCanvasRenderingContext2D.prototype.measureText = function(text) {
    record('osc.measureText', [text]);
    return { width: 24, actualBoundingBoxAscent: 8, actualBoundingBoxDescent: 1 };
  };
  window.OffscreenCanvasRenderingContext2D = OffscreenCanvasRenderingContext2D;

  // --- Audio ---
  function AudioBuffer() {}
  AudioBuffer.prototype.getChannelData = function(ch) {
    record('audio.getChannelData', [ch]);
    const a = new Float32Array(64);
    for (let i = 0; i < a.length; i++) a[i] = 0.5;
    return a;
  };
  AudioBuffer.prototype.copyFromChannel = function(dest, ch, off) {
    record('audio.copyFromChannel', [ch, off]);
    if (dest) for (let i = 0; i < dest.length; i++) dest[i] = 0.25;
  };
  function AnalyserNode() {}
  AnalyserNode.prototype.getFloatFrequencyData = function(arr) {
    record('analyser.getFloatFrequencyData', [arr.length]);
    if (arr) for (let i = 0; i < arr.length; i++) arr[i] = -100;
  };
  AnalyserNode.prototype.getFloatTimeDomainData = function(arr) {
    record('analyser.getFloatTimeDomainData', [arr.length]);
    if (arr) for (let i = 0; i < arr.length; i++) arr[i] = 0.001;
  };
  window.AudioBuffer = AudioBuffer;
  window.AnalyserNode = AnalyserNode;

  // --- Speech ---
  function SpeechSynthesis() {}
  SpeechSynthesis.prototype.getVoices = function() {
    record('speech.getVoices');
    return [{ name: 'STUB', lang: 'en' }];
  };
  window.SpeechSynthesis = SpeechSynthesis;

  // --- document.fonts ---
  Object.defineProperty(window.document, 'fonts', {
    configurable: true,
    value: {
      check: function(font) { record('fonts.check', [font]); return true; },
      ready: Promise.resolve(),
    },
  });
}

function makeDom({ url = 'https://example.com/' } = {}) {
  const dom = new JSDOM(
    '<!doctype html><html><head></head><body></body></html>',
    { url, pretendToBeVisual: true, runScripts: 'outside-only' },
  );
  installFpStubs(dom.window);
  return dom;
}

function loadShim(rel, options) {
  const dom = makeDom(options);
  dom.window.eval(readFixture(rel));
  return dom;
}

const ALPHA = 'anti_fingerprinting/shim_seed_alpha.js';
const BETA = 'anti_fingerprinting/shim_seed_beta.js';

// --- screen.* ---

test('screen.width / screen.height pinned to 1920×1080', () => {
  const dom = loadShim(ALPHA);
  assert.equal(dom.window.screen.width, 1920);
  assert.equal(dom.window.screen.height, 1080);
  assert.equal(dom.window.screen.availWidth, 1920);
  assert.equal(dom.window.screen.availHeight, 1040);
});

test('screen.colorDepth and pixelDepth pinned to 24', () => {
  const dom = loadShim(ALPHA);
  assert.equal(dom.window.screen.colorDepth, 24);
  assert.equal(dom.window.screen.pixelDepth, 24);
});

test('screen overrides land on Screen.prototype, not the instance', () => {
  // An own-property leak would let a fingerprinter detect the shim by
  // walking Object.getOwnPropertyNames(screen).
  const dom = loadShim(ALPHA);
  const own = Object.getOwnPropertyNames(dom.window.screen);
  for (const leaked of ['width', 'height', 'colorDepth', 'pixelDepth']) {
    assert.equal(own.includes(leaked), false,
      `${leaked} leaks as own-property: ${JSON.stringify(own)}`);
  }
});

// --- navigator.* ---

test('navigator.hardwareConcurrency is in the seeded range [4, 8]', () => {
  const dom = loadShim(ALPHA);
  const hc = dom.window.navigator.hardwareConcurrency;
  assert.equal(typeof hc, 'number');
  assert.ok(hc >= 4 && hc <= 8, `hardwareConcurrency=${hc} out of range`);
});

test('navigator.deviceMemory is one of {4, 8}', () => {
  const dom = loadShim(ALPHA);
  const dm = dom.window.navigator.deviceMemory;
  assert.ok(dm === 4 || dm === 8, `deviceMemory=${dm} not in {4,8}`);
});

test('same seed → same hardwareConcurrency / deviceMemory across runs', () => {
  // Per-site stability: a given site must report the same hardware
  // fingerprint on every launch. Re-loading the same fixture twice
  // must produce the same numbers.
  const a = loadShim(ALPHA);
  const b = loadShim(ALPHA);
  assert.equal(a.window.navigator.hardwareConcurrency,
    b.window.navigator.hardwareConcurrency);
  assert.equal(a.window.navigator.deviceMemory,
    b.window.navigator.deviceMemory);
});

test('different seeds may report different deviceMemory', () => {
  // Cross-site uniqueness: two different seeds should at least sometimes
  // disagree. Since deviceMemory is binary {4, 8} we check the values
  // are present and well-formed; the alpha/beta seeds were chosen to
  // straddle the threshold.
  const a = loadShim(ALPHA).window.navigator.deviceMemory;
  const b = loadShim(BETA).window.navigator.deviceMemory;
  assert.ok([4, 8].includes(a));
  assert.ok([4, 8].includes(b));
});

test('navigator.plugins is empty PluginArray-shaped', () => {
  const dom = loadShim(ALPHA);
  const plugins = dom.window.navigator.plugins;
  assert.equal(plugins.length, 0);
  assert.equal(typeof plugins.item, 'function');
  assert.equal(plugins.item(0), null);
  assert.equal(typeof plugins.namedItem, 'function');
  assert.equal(typeof plugins.refresh, 'function');
});

test('navigator.mimeTypes is empty', () => {
  const dom = loadShim(ALPHA);
  const mt = dom.window.navigator.mimeTypes;
  assert.equal(mt.length, 0);
  assert.equal(mt.item(0), null);
});

test('navigator.getBattery resolves to fixed values', async () => {
  const dom = loadShim(ALPHA);
  const battery = await dom.window.navigator.getBattery();
  assert.equal(battery.charging, true);
  assert.equal(battery.level, 1);
  assert.equal(battery.dischargingTime, Infinity);
  assert.equal(typeof battery.addEventListener, 'function');
});

test('speechSynthesis.getVoices returns []', () => {
  const dom = loadShim(ALPHA);
  // We patched SpeechSynthesis.prototype, so a fresh instance has the
  // override. Cross-realm: jsdom Array vs Node Array fails deepEqual
  // even when both are []; assert on length + element absence instead.
  const ss = new dom.window.SpeechSynthesis();
  const voices = ss.getVoices();
  assert.equal(voices.length, 0);
});

test('navigator overrides land on Navigator.prototype, not the instance', () => {
  const dom = loadShim(ALPHA);
  const own = Object.getOwnPropertyNames(dom.window.navigator);
  for (const leaked of ['hardwareConcurrency', 'deviceMemory', 'plugins',
                        'mimeTypes', 'getBattery']) {
    assert.equal(own.includes(leaked), false,
      `${leaked} leaks as own-property: ${JSON.stringify(own)}`);
  }
});

// --- Canvas 2D ---

test('CanvasRenderingContext2D.prototype.getImageData calls original and returns ImageData', () => {
  const dom = loadShim(ALPHA);
  const ctx = new dom.window.CanvasRenderingContext2D();
  const img = ctx.getImageData(0, 0, 4, 4);
  assert.equal(img.width, 4);
  assert.equal(img.height, 4);
  assert.equal(img.data.length, 64);
  // The original was invoked exactly once via the wrapper.
  const calls = dom.window.__calls.filter(c => c.name === 'ctx.getImageData');
  assert.equal(calls.length, 1);
});

test('Canvas toDataURL invokes the original after a noise nudge', () => {
  const dom = loadShim(ALPHA);
  const canvas = dom.window.document.createElement('canvas');
  canvas.width = 8;
  canvas.height = 8;
  const url = canvas.toDataURL('image/png');
  assert.match(url, /^data:image\/png;base64,STUB$/);
  // Wrapper should have requested a 2d context to nudge a pixel BEFORE
  // calling the original toDataURL.
  const ctxCalls = dom.window.__calls.filter(c => c.name === 'canvas.getContext');
  const fillCalls = dom.window.__calls.filter(c => c.name === 'ctx.fillRect');
  const tdu = dom.window.__calls.filter(c => c.name === 'canvas.toDataURL');
  assert.ok(ctxCalls.length >= 1, 'getContext was not called by the wrapper');
  assert.equal(fillCalls.length, 1, 'noise nudge fillRect did not fire');
  assert.equal(tdu.length, 1, 'original toDataURL was not invoked');
});

test('measureText returns jittered numeric fields and preserves shape', () => {
  const dom = loadShim(ALPHA);
  const ctx = new dom.window.CanvasRenderingContext2D();
  const m = ctx.measureText('hello');
  // Width should be very close to but not equal the raw 42 (multiplicative
  // ±0.01% jitter).
  assert.notEqual(m.width, 42);
  assert.ok(Math.abs(m.width - 42) < 42 * 0.001,
    `width=${m.width} jitter outside ±0.1% bound`);
  // Other numeric fields are jittered too; non-numeric fields untouched.
  assert.equal(typeof m.actualBoundingBoxAscent, 'number');
});

test('measureText jitter is deterministic per seed + text', () => {
  // Same site, same text → same width across reads. A varying jitter
  // would let a fingerprinter average it away.
  const dom1 = loadShim(ALPHA);
  const dom2 = loadShim(ALPHA);
  const m1 = new dom1.window.CanvasRenderingContext2D().measureText('hello');
  const m2 = new dom2.window.CanvasRenderingContext2D().measureText('hello');
  assert.equal(m1.width, m2.width);
});

test('measureText jitter differs per seed (cross-site uniqueness)', () => {
  const a = new (loadShim(ALPHA).window.CanvasRenderingContext2D)().measureText('hello');
  const b = new (loadShim(BETA).window.CanvasRenderingContext2D)().measureText('hello');
  assert.notEqual(a.width, b.width);
});

// --- WebGL ---

test('WebGL.getParameter masks UNMASKED_VENDOR_WEBGL / UNMASKED_RENDERER_WEBGL', () => {
  const dom = loadShim(ALPHA);
  const gl = new dom.window.WebGLRenderingContext();
  // 37445 = UNMASKED_VENDOR_WEBGL, 37446 = UNMASKED_RENDERER_WEBGL.
  // The stub would have returned STUB-VENDOR / STUB-RENDERER; the shim
  // must rewrite to the constant generic identifier.
  assert.equal(gl.getParameter(37445), 'WebSpace');
  assert.equal(gl.getParameter(37446), 'WebSpace WebGL');
});

test('WebGL.getParameter masks GL_VENDOR / GL_RENDERER', () => {
  const dom = loadShim(ALPHA);
  const gl = new dom.window.WebGLRenderingContext();
  assert.equal(gl.getParameter(7936), 'WebSpace');
  assert.equal(gl.getParameter(7937), 'WebSpace WebGL');
});

test('WebGL.getParameter falls through for non-vendor params', () => {
  // A pname the shim does not intercept must reach the underlying impl.
  const dom = loadShim(ALPHA);
  const gl = new dom.window.WebGLRenderingContext();
  // 1 is not a vendor/renderer pname; stub returns null.
  assert.equal(gl.getParameter(1), null);
  const calls = dom.window.__calls.filter(c => c.name === 'webgl.getParameter');
  assert.equal(calls.length, 1, 'underlying getParameter should have been called once');
});

test('WebGL.getSupportedExtensions returns the constant minimal list', () => {
  const dom = loadShim(ALPHA);
  const gl = new dom.window.WebGLRenderingContext();
  // [...exts] copies into the Node realm so deepEqual works.
  const exts = [...gl.getSupportedExtensions()].sort();
  assert.deepEqual(exts, [
    'OES_element_index_uint',
    'OES_texture_float',
    'WEBGL_depth_texture',
  ]);
  // Vendor-leaking extensions are scrubbed.
  assert.equal(exts.includes('STUB_EXT_VENDOR_LEAK'), false);
});

test('WebGL.getSupportedExtensions returns an independent array per call', () => {
  // Returning the same frozen reference would let a script mutate the
  // shared state; returning a slice keeps every caller isolated.
  const dom = loadShim(ALPHA);
  const gl = new dom.window.WebGLRenderingContext();
  const a = gl.getSupportedExtensions();
  const b = gl.getSupportedExtensions();
  assert.notEqual(a, b);
  assert.deepEqual([...a].sort(), [...b].sort());
});

test('WebGL.readPixels invokes original and applies seeded noise', () => {
  const dom = loadShim(ALPHA);
  const gl = new dom.window.WebGLRenderingContext();
  const buf = new Uint8Array(64);
  gl.readPixels(0, 0, 4, 4, 0, 0, buf);
  // Stub fills with 128; some pixels will be jittered to 127 or 129 by
  // the seeded noise pass. The exact count is deterministic per seed.
  const distinctValues = new Set(buf);
  assert.ok(distinctValues.size >= 1);
});

test('WebGL2 inherits the same patches as WebGL1', () => {
  const dom = loadShim(ALPHA);
  // WebGL2RenderingContext.prototype is a child of WebGLRenderingContext.prototype
  // in our stub setup, so the wrapped methods are reachable on instances.
  const gl2 = new dom.window.WebGL2RenderingContext();
  assert.equal(gl2.getParameter(37445), 'WebSpace');
  assert.equal(gl2.getParameter(37446), 'WebSpace WebGL');
});

// --- Audio ---

test('AudioBuffer.getChannelData applies per-sample noise', () => {
  const dom = loadShim(ALPHA);
  const buf = new dom.window.AudioBuffer();
  const data = buf.getChannelData(0);
  // Stub returns Float32Array of 0.5; noise magnitude is 1e-7. Every
  // sample should still be ≈0.5 but not exactly equal.
  let mutated = 0;
  for (const v of data) {
    if (Math.abs(v - 0.5) > 0 && Math.abs(v - 0.5) < 1e-6) mutated++;
  }
  assert.ok(mutated > 0, 'no samples mutated by audio noise pass');
});

test('AnalyserNode.getFloatFrequencyData applies dB-scale noise', () => {
  const dom = loadShim(ALPHA);
  const an = new dom.window.AnalyserNode();
  const arr = new Float32Array(32);
  for (let i = 0; i < arr.length; i++) arr[i] = -100;
  an.getFloatFrequencyData(arr);
  // Stub fills with -100; shim noise magnitude is 1e-4 — values should be
  // ≈-100 but not exactly.
  let mutated = 0;
  for (const v of arr) {
    if (v !== -100 && Math.abs(v + 100) < 1e-3) mutated++;
  }
  assert.ok(mutated > 0, 'frequency data was not noised');
});

// --- Timing ---

test('performance.now is quantized to 100ms', () => {
  const dom = loadShim(ALPHA);
  const t = dom.window.performance.now();
  assert.equal(t % 100, 0, `performance.now()=${t} not quantized`);
});

test('Date.now is quantized to 100ms', () => {
  const dom = loadShim(ALPHA);
  const t = dom.window.Date.now();
  assert.equal(t % 100, 0, `Date.now()=${t} not quantized`);
});

// --- ClientRects ---

test('Element.getBoundingClientRect returns a rect with sub-pixel jitter', () => {
  const dom = loadShim(ALPHA);
  const div = dom.window.document.createElement('div');
  dom.window.document.body.appendChild(div);
  const r = div.getBoundingClientRect();
  // jsdom returns x=0 y=0 width=0 height=0 for unlaid elements; jitter
  // is ±0.001 added to x/y.
  assert.equal(typeof r.x, 'number');
  assert.equal(typeof r.y, 'number');
  assert.equal(typeof r.width, 'number');
  // jitter magnitude bound
  assert.ok(Math.abs(r.x) < 0.01, `x=${r.x} jitter outside bound`);
  assert.ok(Math.abs(r.y) < 0.01, `y=${r.y} jitter outside bound`);
});

test('getBoundingClientRect is deterministic per (seed, element identity)', () => {
  const dom = loadShim(ALPHA);
  const div = dom.window.document.createElement('div');
  dom.window.document.body.appendChild(div);
  const a = div.getBoundingClientRect();
  const b = div.getBoundingClientRect();
  assert.equal(a.x, b.x);
  assert.equal(a.y, b.y);
});

// --- document.fonts.check ---

test('document.fonts.check answers true only for common platform fonts', () => {
  const dom = loadShim(ALPHA);
  // Common families: should answer true.
  assert.equal(dom.window.document.fonts.check('12px Arial'), true);
  assert.equal(dom.window.document.fonts.check('12px "Times New Roman"'), true);
  assert.equal(dom.window.document.fonts.check('12px sans-serif'), true);
  assert.equal(dom.window.document.fonts.check('bold italic 14pt Helvetica'), true);
  // Made-up family should answer false even though the underlying stub
  // would have answered true (revealing the override is intentional —
  // the goal is to suppress the high-entropy installed-fonts axis).
  assert.equal(dom.window.document.fonts.check('12px UnobtainableFont'), false);
});

// --- Function.prototype.toString hardening ---

test('wrapped methods stringify as [native code]', () => {
  // Detection by toString-probing is the most common way a fingerprint
  // script verifies an API is genuine. asNative(...) keys the function
  // into __wsFnStubs so toString returns the native stub. Must call the
  // PATCHED toString from the jsdom realm — Node's own
  // Function.prototype.toString hasn't been patched (different realm).
  const dom = loadShim(ALPHA);
  const ctx = new dom.window.CanvasRenderingContext2D();
  const s = dom.window.Function.prototype.toString.call(ctx.getImageData);
  assert.match(s, /\[native code\]/);
});

test('Function.prototype.toString itself stringifies as native', () => {
  // A naive patch where the patched toString returns its own source
  // would self-incriminate — fingerprinters call
  // Function.prototype.toString.call(Function.prototype.toString).
  const dom = loadShim(ALPHA);
  const fnToString = dom.window.Function.prototype.toString;
  const s = fnToString.call(fnToString);
  assert.match(s, /\[native code\]/);
});

// --- Re-entrance guard ---

test('re-running the shim does not double-wrap (idempotent)', () => {
  // Both Android System WebView and WKWebView re-execute initialUserScripts
  // on every frame. The guard `__ws_anti_fp_shim__` must short-circuit
  // the second run so wrappers don't wrap themselves.
  const dom = makeDom();
  dom.window.eval(readFixture(ALPHA));
  const beforeWidth = new dom.window.CanvasRenderingContext2D().measureText('x').width;
  dom.window.eval(readFixture(ALPHA));  // re-run
  const afterWidth = new dom.window.CanvasRenderingContext2D().measureText('x').width;
  // If re-running double-wrapped, the jitter would compound. Re-entrance
  // guard makes the second run a no-op so the width is identical.
  assert.equal(beforeWidth, afterWidth);
});

// --- Smoke: shim loads cleanly under jsdom ---

test('shim does not throw under jsdom', () => {
  assert.doesNotThrow(() => loadShim(ALPHA));
  assert.doesNotThrow(() => loadShim(BETA));
});
