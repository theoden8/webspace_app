// Behavioural tests for Worker/SharedWorker shim propagation
// (lib/services/worker_shim.dart, dumped to test/js_fixtures/worker_shim/*.js).
//
// Two tiers, because the feature has two halves:
//
//   1. The page-side installer — asserted under jsdom with Blob /
//      createObjectURL / Worker stubbed, so we can read the generated wrapper
//      script and confirm what the real constructor was handed.
//   2. The worker-scope payload — extracted from the installer's own Blob and
//      executed in a simulated WorkerGlobalScope built with node:vm (jsdom has
//      no workers). This is the half that actually matters: it proves the
//      shims apply with no `window`, no `Navigator`, no `document`, and that
//      they do NOT add navigator properties a real WorkerNavigator lacks.

const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { JSDOM } = require('jsdom');
const { readFixture } = require('./helpers/load_shim');

const COMBINED = 'worker_shim/installer_combined.js';
const LANGUAGE_ONLY = 'worker_shim/installer_language_only.js';

// A jsdom page whose Blob/URL/Worker are recording stubs. Returns handles to
// everything the installer touches so tests can inspect the generated wrapper.
// `refuseBlobWorkers` models chromium under a CSP whose worker-src omits
// blob:: the constructor returns a Worker and the refusal arrives later as an
// error event on it.
function pageWithStubs(fixture, { refuseBlobWorkers = false } = {}) {
  const dom = new JSDOM('<!doctype html><html><body></body></html>', {
    url: 'https://example.com/app/',
    runScripts: 'outside-only',
  });
  const w = dom.window;

  const blobs = new Map(); // blob url -> text content
  let counter = 0;
  w.Blob = function Blob(parts) { this.__text = (parts || []).join(''); };
  w.URL.createObjectURL = function (blob) {
    const url = 'blob:https://example.com/obj-' + (++counter);
    blobs.set(url, blob && blob.__text);
    return url;
  };

  const created = [];
  function recorder(name) {
    const Ctor = function (script, options) {
      created.push({ name, script: String(script), options });
      this.__script = String(script);
      if (refuseBlobWorkers && this.__script.startsWith('blob:')) {
        const worker = this;
        w.setTimeout(() => {
          if (worker.onerror) worker.onerror({ preventDefault() {} });
        }, 0);
      }
    };
    Ctor.prototype.__brand = name;
    return Ctor;
  }
  w.Worker = recorder('Worker');
  w.SharedWorker = recorder('SharedWorker');

  w.eval(readFixture(fixture));

  // The installer starts one throwaway worker at install time to find out
  // whether this document's CSP admits blob: workers at all. It is not a
  // wrapper, so keep it out of the recording the wrapper tests index into.
  const probes = [];
  for (let i = created.length - 1; i >= 0; i--) {
    if ((blobs.get(created[i].script) || '') === 'postMessage(1);close();') {
      probes.unshift(created.splice(i, 1)[0]);
    }
  }
  return { dom, window: w, blobs, created, probes };
}

// One macrotask in the jsdom window, which is when a refused blob: worker
// reports its error.
function tick(ctx) {
  return new Promise((resolve) => ctx.window.setTimeout(resolve, 0));
}

// Content of the wrapper blob handed to the real constructor for call `i`.
function wrapperFor(ctx, i = 0) {
  return ctx.blobs.get(ctx.created[i].script);
}

// The shim blob the wrapper imports, and its source.
function shimFor(ctx) {
  const wrapper = wrapperFor(ctx);
  const m = /importScripts\("(blob:[^"]+)"\)/.exec(wrapper) ||
            /^import "(blob:[^"]+)"/m.exec(wrapper);
  assert.ok(m, `no shim import found in wrapper:\n${wrapper}`);
  return { shimUrl: m[1], payload: ctx.blobs.get(m[1]) };
}

// --- Page-side installer ---

test('Worker is constructed with a wrapper blob, not the original URL', () => {
  const ctx = pageWithStubs(COMBINED);
  new ctx.window.Worker('/app/w.js');
  assert.equal(ctx.created.length, 1);
  assert.match(ctx.created[0].script, /^blob:/);
});

test('wrapper loads the shim first, then the original script, synchronously', () => {
  const ctx = pageWithStubs(COMBINED);
  new ctx.window.Worker('w.js');
  const wrapper = wrapperFor(ctx);
  const shimImport = wrapper.indexOf('importScripts("blob:');
  const origImport = wrapper.indexOf('importScripts("https://example.com/app/w.js")');
  assert.ok(shimImport >= 0, `shim not imported:\n${wrapper}`);
  assert.ok(origImport > shimImport,
    `original must be imported AFTER the shim:\n${wrapper}`);
});

test('the original script URL is resolved to an absolute URL', () => {
  // importScripts inside a blob worker resolves relative specifiers against the
  // blob URL, which would 404 — the wrapper must bake in an absolute URL.
  const ctx = pageWithStubs(COMBINED);
  new ctx.window.Worker('./nested/w.js');
  assert.match(wrapperFor(ctx),
    /importScripts\("https:\/\/example\.com\/app\/nested\/w\.js"\)/);
});

test('SharedWorker with the same script reuses one wrapper URL (sharing intact)', () => {
  // SharedWorker identity is keyed on the script URL. A fresh blob per call
  // would silently turn one shared worker into N unshared ones.
  const ctx = pageWithStubs(COMBINED);
  new ctx.window.SharedWorker('/app/s.js');
  new ctx.window.SharedWorker('/app/s.js');
  assert.equal(ctx.created.length, 2);
  assert.equal(ctx.created[0].script, ctx.created[1].script);
});

test('module workers get ordered static imports, not importScripts', () => {
  // importScripts does not exist in a module worker. Static imports evaluate in
  // source order, so the shim still lands before the original module body.
  const ctx = pageWithStubs(COMBINED);
  new ctx.window.Worker('/app/m.js', { type: 'module' });
  const wrapper = wrapperFor(ctx);
  assert.equal(wrapper.includes('importScripts'), false);
  const shimIdx = wrapper.indexOf('import "blob:');
  const origIdx = wrapper.indexOf('import "https://example.com/app/m.js"');
  assert.ok(shimIdx >= 0 && origIdx > shimIdx, `bad module wrapper:\n${wrapper}`);
});

test('classic and module variants of the same script get distinct wrappers', () => {
  const ctx = pageWithStubs(COMBINED);
  new ctx.window.Worker('/app/w.js');
  new ctx.window.Worker('/app/w.js', { type: 'module' });
  assert.notEqual(ctx.created[0].script, ctx.created[1].script);
});

test('options are forwarded to the real constructor', () => {
  const ctx = pageWithStubs(COMBINED);
  new ctx.window.Worker('/app/w.js', { name: 'my-worker', type: 'classic' });
  assert.equal(ctx.created[0].options.name, 'my-worker');
});

test('instanceof Worker still holds through the patch', () => {
  const ctx = pageWithStubs(COMBINED);
  const worker = new ctx.window.Worker('/app/w.js');
  assert.equal(worker instanceof ctx.window.Worker, true);
});

test('patched constructors stringify as [native code] and keep their name', () => {
  const ctx = pageWithStubs(COMBINED);
  const s = ctx.window.Function.prototype.toString.call(ctx.window.Worker);
  assert.match(s, /\[native code\]/);
  assert.equal(ctx.window.Worker.name, 'Worker');
});

test('fails open: a worker is still created when wrapping throws', () => {
  // Better an unspoofed worker than a broken page.
  const ctx = pageWithStubs(COMBINED);
  ctx.window.URL.createObjectURL = function () { throw new Error('CSP'); };
  const worker = new ctx.window.Worker('/app/w.js');
  assert.ok(worker);
  // Passed through verbatim — the fallback hands the real constructor exactly
  // what the page asked for.
  assert.equal(ctx.created[ctx.created.length - 1].script, '/app/w.js');
});

test('the installer probes blob: worker support before the page asks', () => {
  // A CSP refusal is asynchronous, so the answer has to be in hand before the
  // site builds its first worker — there is nothing to fall back to once one
  // has been handed a wrapper that will never load.
  const ctx = pageWithStubs(COMBINED);
  assert.equal(ctx.probes.length, 1);
  assert.equal(ctx.created.length, 0, 'nothing else may be constructed at install');
  const payload = ctx.blobs.get(ctx.probes[0].script);
  assert.match(payload, /postMessage\(1\);close\(\);/,
    'the probe must report back and then shut itself down');
});

test('a refused blob: worker stops the wrapping (site worker survives)', async () => {
  // The messenger.com case: worker-src without blob: kills every wrapper, and
  // the refusal never reaches the constructor. Once the probe reports it, the
  // page's own script is what the real constructor gets.
  const ctx = pageWithStubs(COMBINED, { refuseBlobWorkers: true });
  await tick(ctx);
  new ctx.window.Worker('/app/w.js');
  assert.equal(ctx.created.length, 1);
  assert.equal(ctx.created[0].script, '/app/w.js');
});

test('a blob: worker-src violation stops the wrapping too', () => {
  // Covers the window before the probe answers, for a page that builds a
  // worker from an inline script at the top of the document.
  const ctx = pageWithStubs(COMBINED);
  const ev = new ctx.window.Event('securitypolicyviolation');
  ev.blockedURI = 'blob';
  ev.effectiveDirective = 'worker-src';
  ctx.window.document.dispatchEvent(ev);
  new ctx.window.Worker('/app/w.js');
  assert.equal(ctx.created[0].script, '/app/w.js');
});

test('an unrelated blob: violation leaves the wrapping alone', () => {
  // img-src says nothing about worker scripts; treating it as a refusal would
  // drop the spoof on any site that blocks blob: images.
  const ctx = pageWithStubs(COMBINED);
  const ev = new ctx.window.Event('securitypolicyviolation');
  ev.blockedURI = 'blob';
  ev.effectiveDirective = 'img-src';
  ctx.window.document.dispatchEvent(ev);
  new ctx.window.Worker('/app/w.js');
  assert.match(ctx.created[0].script, /^blob:/);
});

test('a refused shim import still leaves the original script loading', () => {
  // worker-src admitting blob: while script-src does not: the wrapper worker
  // starts and the shim import is what CSP kills. That must cost the spoof,
  // not the site's worker.
  const ctx = pageWithStubs(COMBINED);
  new ctx.window.Worker('/app/w.js');
  const wrapper = wrapperFor(ctx);
  assert.match(wrapper, /try \{ importScripts\("blob:[^"]+"\); \}/);
  assert.match(wrapper, /catch \(e\) \{ try \{ delete self\.__wsShimUrl; \}/);
  const guarded = wrapper.indexOf('catch (e)');
  const original = wrapper.indexOf('importScripts("https://example.com/app/w.js")');
  assert.ok(original > guarded, `original import must follow the catch:\n${wrapper}`);
});

test('re-running the installer does not double-wrap', () => {
  const ctx = pageWithStubs(COMBINED);
  ctx.window.eval(readFixture(COMBINED));
  new ctx.window.Worker('/app/w.js');
  const wrapper = wrapperFor(ctx);
  // A double patch would produce a wrapper that imports another wrapper.
  assert.equal((wrapper.match(/importScripts/g) || []).length, 2);
});

test('installer is absent when there are no shims to propagate', () => {
  // buildWorkerShimScript returns null for an empty shim list, so no fixture
  // exists for that case; assert the builder contract via the two that do.
  assert.ok(readFixture(LANGUAGE_ONLY).includes('__wsInstallWorkerWrap'));
  assert.ok(readFixture(COMBINED).includes('__wsInstallWorkerWrap'));
});

// --- Worker-scope payload, executed in a simulated WorkerGlobalScope ---

// Build a context that looks like a real worker global: no window, no
// Navigator/Screen/document/Element, navigator is a WorkerNavigator carrying
// only the properties the HTML spec's NavigatorID mixin exposes there.
function workerContext({ userAgentData = false } = {}) {
  // A fresh vm context carries only ECMAScript intrinsics; URL is a real worker
  // global, so hand the context a genuine implementation.
  const ctx = vm.createContext({ URL: URL });
  const run = (src) => vm.runInContext(src, ctx);

  run(`
    globalThis.WorkerGlobalScope = function WorkerGlobalScope() {};
    // The shims test scope with \`globalThis instanceof WorkerGlobalScope\`;
    // the context global cannot literally be one, so answer the brand check.
    Object.defineProperty(WorkerGlobalScope, Symbol.hasInstance, {
      value: function() { return true; },
    });
    globalThis.WorkerNavigator = function WorkerNavigator() {};
    Object.defineProperties(WorkerNavigator.prototype, {
      appCodeName: { value: 'Mozilla', configurable: true },
      appName: { value: 'Netscape', configurable: true },
      appVersion: { value: '5.0 (Macintosh)', configurable: true },
      product: { value: 'Gecko', configurable: true },
      productSub: { value: '20030107', configurable: true },
      vendor: { value: 'Apple Computer, Inc.', configurable: true },
      vendorSub: { value: '', configurable: true },
      platform: { value: 'iPhone', configurable: true },
      userAgent: { value: 'stub', configurable: true },
      language: { get() { return 'es-ES'; }, configurable: true },
      languages: { get() { return ['es-ES', 'en']; }, configurable: true },
      hardwareConcurrency: { value: 10, configurable: true },
      deviceMemory: { value: 2, configurable: true },
      onLine: { value: true, configurable: true },
    });
    globalThis.navigator = new WorkerNavigator();
    globalThis.self = globalThis;
    globalThis.location = { href: 'https://example.com/app/w.js' };
    globalThis.performance = { now: function() { return 1234.5678; } };
  `);
  if (userAgentData) {
    run(`Object.defineProperty(WorkerNavigator.prototype, 'userAgentData',
      { value: { brands: [] }, configurable: true });`);
  }
  return { run };
}

// Run the real payload in a simulated worker, reproducing what the generated
// wrapper does first: hand the payload its own URL, then load it.
function loadPayloadInWorker(opts = {}) {
  const page = pageWithStubs(COMBINED);
  new page.window.Worker('/app/w.js');
  const { shimUrl, payload } = shimFor(page);
  const worker = workerContext(opts);
  if (opts.prelude) worker.run(opts.prelude);
  worker.run(`self.__wsShimUrl = ${JSON.stringify(shimUrl)};`);
  worker.run(payload);
  return { worker, page, shimUrl };
}

test('payload applies in worker scope without window/Navigator/document', () => {
  assert.doesNotThrow(() => loadPayloadInWorker());
});

test('worker navigator.language / languages are spoofed', () => {
  const { worker } = loadPayloadInWorker();
  assert.equal(worker.run('navigator.language'), 'en');
  // Compared as a string: a vm-realm Array never deep-equals a host-realm one.
  assert.equal(worker.run('navigator.languages.join(",")'), 'en');
});

test('worker Intl FORMATS in the spoofed locale (the CreepJS worker leak)', () => {
  // The dump showed the worker formatting in es-ES ("1 dólar estadounidense")
  // while the page claimed English.
  const { worker } = loadPayloadInWorker();
  assert.equal(worker.run('new Intl.NumberFormat().format(0.5)'), '0.5');
  assert.equal(
    worker.run(`new Intl.DateTimeFormat(undefined, {timeZone:'UTC', month:'long'})
      .format(new Date(Date.UTC(2020, 6, 1)))`),
    'July');
});

test('worker timezone is spoofed to the per-site zone', () => {
  // The dump showed the worker reporting Europe/London (-60) against a UTC page.
  const { worker } = loadPayloadInWorker();
  assert.equal(worker.run('new Date().getTimezoneOffset()'), 0);
  assert.equal(
    worker.run("new Intl.DateTimeFormat().resolvedOptions().timeZone"), 'UTC');
});

test('worker navigator identity matches the claimed engine', () => {
  const { worker } = loadPayloadInWorker();
  assert.equal(worker.run('navigator.vendor'), '');
  assert.equal(worker.run('navigator.productSub'), '20100101');
  assert.equal(worker.run('navigator.platform'), 'Linux armv8l');
});

test('worker hardware values are the spoofed ones, matching the page', () => {
  // Page/worker disagreement is itself a fingerprint, so the same seeded shim
  // source runs in both. Compare against the page's own values.
  const { worker, page } = loadPayloadInWorker();
  const pageDom = new JSDOM('<!doctype html>', { runScripts: 'outside-only' });
  pageDom.window.eval(readFixture('anti_fingerprinting/shim_seed_alpha.js'));
  assert.equal(worker.run('navigator.hardwareConcurrency'),
    pageDom.window.navigator.hardwareConcurrency);
  assert.equal(worker.run('navigator.deviceMemory'),
    pageDom.window.navigator.deviceMemory);
  // And not the host's real values from the stub.
  assert.notEqual(worker.run('navigator.hardwareConcurrency'), 10);
  assert.ok(page);
});

test('worker timing is quantized', () => {
  const { worker } = loadPayloadInWorker();
  assert.equal(worker.run('performance.now()') % 100, 0);
  assert.equal(worker.run('Date.now()') % 100, 0);
});

test('window-only navigator properties are NOT added to a worker', () => {
  // A real WorkerNavigator has no plugins/mimeTypes/getBattery and no
  // oscpu/buildID; defining them would be a fresh leak, worse than the one
  // we are closing.
  const { worker } = loadPayloadInWorker();
  for (const absent of ['plugins', 'mimeTypes', 'getBattery', 'oscpu', 'buildID']) {
    assert.equal(worker.run(`'${absent}' in navigator`), false,
      `${absent} must not be added to a worker navigator`);
  }
});

test('window-only globals are NOT created in a worker', () => {
  // The location shim carries a WebRTC policy and the anti-fp shim a matchMedia
  // wrapper; neither exists in a worker and both must stay absent.
  const { worker } = loadPayloadInWorker();
  assert.equal(worker.run("typeof globalThis.RTCPeerConnection"), 'undefined');
  assert.equal(worker.run("typeof globalThis.matchMedia"), 'undefined');
});

test('a Blink-host worker gets userAgentData removed under a Gecko UA', () => {
  const { worker } = loadPayloadInWorker({ userAgentData: true });
  assert.equal(worker.run("'userAgentData' in navigator"), false);
});

test('payload re-installs the patch for nested workers', () => {
  // A worker spawning a worker must stay covered, else it is a trivial bypass.
  const { worker, shimUrl } = loadPayloadInWorker({
    prelude: `
      globalThis.__nested = [];
      globalThis.Worker = function Worker(s) { globalThis.__nested.push(String(s)); };
      globalThis.Blob = function Blob(parts) { this.__text = parts.join(''); };
      // Augment the real URL rather than replacing it — wrap() needs the
      // constructor to absolutize the script specifier.
      globalThis.URL.createObjectURL = function(b) {
        globalThis.__nestedWrapper = b.__text;
        return 'blob:nested-1';
      };
    `,
  });
  worker.run("new Worker('/app/inner.js')");
  assert.equal(worker.run("globalThis.__nested.join(',')"), 'blob:nested-1');
  // The nested wrapper must load the same shim before the inner script.
  const nestedWrapper = worker.run('globalThis.__nestedWrapper');
  assert.ok(nestedWrapper.includes(`importScripts(${JSON.stringify(shimUrl)})`),
    `nested wrapper must import the shim:\n${nestedWrapper}`);
  assert.ok(nestedWrapper.indexOf('inner.js') >
    nestedWrapper.indexOf(shimUrl), 'shim must load before the inner script');
});

test('the shim URL handle is cleaned off the worker global', () => {
  // __wsShimUrl is how the payload learns its own URL for nested wrapping; it
  // must not linger as an inspectable own-property.
  const { worker } = loadPayloadInWorker();
  assert.equal(worker.run("'__wsShimUrl' in globalThis"), false);
});
