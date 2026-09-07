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

  // Real EventTargets, because the installer's rescue path listens for the
  // `error` a refused wrapper fires and re-dispatches the rebuilt worker's
  // events on the object the page holds. `onerror` and friends register their
  // listener when the attribute is set, as they do on a real Worker — the
  // rescue's own listener is registered first and stops theirs, and that
  // ordering is the whole mechanism.
  const created = [];
  function recorder(name) {
    const Ctor = class extends w.EventTarget {
      constructor(script, options) {
        super();
        this.__script = String(script);
        this.__posted = [];
        created.push({ name, script: this.__script, options, worker: this });
        if (refuseBlobWorkers && this.__script.startsWith('blob:')) {
          // chromium reports a CSP refusal as a plain `error` Event with no
          // message, asynchronously, on the object the constructor returned.
          w.setTimeout(() => {
            this.dispatchEvent(new w.Event('error', { cancelable: true }));
          }, 0);
        }
      }
      postMessage() { this.__posted.push(Array.prototype.slice.call(arguments)); }
      terminate() { this.__terminated = true; }
    };
    Ctor.prototype.__brand = name;
    for (const attr of ['onmessage', 'onerror', 'onmessageerror']) {
      const type = attr.slice(2);
      Object.defineProperty(Ctor.prototype, attr, {
        configurable: true,
        get() { return this['__' + attr] || null; },
        set(fn) {
          const prev = this['__' + attr];
          if (prev) this.removeEventListener(type, prev);
          this['__' + attr] = fn;
          if (fn) this.addEventListener(type, fn);
        },
      });
    }
    return Ctor;
  }
  w.Worker = recorder('Worker');
  w.SharedWorker = recorder('SharedWorker');

  w.eval(readFixture(fixture));
  return { dom, window: w, blobs, created };
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

test('the installer asks the CSP nothing until the page wants a worker', () => {
  // A document that never builds a worker never touches the policy. Asking up
  // front cost one refusal on every load of every site whose worker-src omits
  // blob:, which any first party can see and a report-uri mails home.
  const ctx = pageWithStubs(COMBINED);
  assert.deepEqual(ctx.created, [], 'nothing may be constructed at install');
});

test('a refused blob: worker stops the wrapping (site workers survive)', async () => {
  // The messenger.com case: worker-src without blob: kills every wrapper, and
  // the refusal never reaches the constructor. The first worker is what finds
  // that out; every one after it is handed the page's own script.
  const ctx = pageWithStubs(COMBINED, { refuseBlobWorkers: true });
  new ctx.window.Worker('/app/w.js');
  await tick(ctx);
  await tick(ctx);

  new ctx.window.Worker('/app/w2.js');
  const scripts = ctx.created.map((c) => c.script);
  assert.match(scripts[0], /^blob:/, 'the first one pays for the answer');
  assert.equal(scripts[1], '/app/w.js', 'and is rebuilt on the page\'s script');
  assert.equal(scripts[2], '/app/w2.js', 'the next is never wrapped at all');
});

test('a policy read off an unrelated violation answers without a worker', () => {
  // The one time the platform hands a page its own policy is inside a
  // violation report, whatever the violation was about. A site that refuses
  // its own blob: image tells us everything we need about its workers.
  const ctx = pageWithStubs(COMBINED);
  const ev = new ctx.window.Event('securitypolicyviolation');
  ev.blockedURI = 'blob:https://example.com/img';
  ev.effectiveDirective = 'img-src';
  ev.disposition = 'enforce';
  ev.originalPolicy = "default-src 'self'; worker-src 'self'";
  ctx.window.document.dispatchEvent(ev);

  new ctx.window.Worker('/app/w.js');
  assert.equal(ctx.created[0].script, '/app/w.js',
    'no wrapper may be built once the policy has been read');
});

test('a policy that admits blob: workers keeps the wrapping', () => {
  const ctx = pageWithStubs(COMBINED);
  const ev = new ctx.window.Event('securitypolicyviolation');
  ev.blockedURI = 'blob:https://example.com/img';
  ev.effectiveDirective = 'img-src';
  ev.disposition = 'enforce';
  ev.originalPolicy = "default-src 'self'; worker-src 'self' blob:";
  ctx.window.document.dispatchEvent(ev);

  new ctx.window.Worker('/app/w.js');
  assert.match(ctx.created[0].script, /^blob:/);
});

test('a report-only policy blocks nothing and is not read as a refusal', () => {
  const ctx = pageWithStubs(COMBINED);
  const ev = new ctx.window.Event('securitypolicyviolation');
  ev.blockedURI = 'blob';
  ev.effectiveDirective = 'worker-src';
  ev.disposition = 'report';
  ev.originalPolicy = "worker-src 'self'";
  ctx.window.document.dispatchEvent(ev);

  new ctx.window.Worker('/app/w.js');
  assert.match(ctx.created[0].script, /^blob:/);
});

test('the worker that finds the refusal is rebuilt on the site\'s own script', async () => {
  // The refusal lands with the wrapper already in the page's hands, and there
  // is no constructor left to fall open on: the worker is simply dead unless
  // the one the page holds is made to work.
  const ctx = pageWithStubs(COMBINED, { refuseBlobWorkers: true });
  const worker = new ctx.window.Worker('/app/w.js');
  const errors = [];
  worker.onerror = (e) => errors.push(e);
  worker.postMessage('go');
  assert.match(ctx.created[0].script, /^blob:/, 'this one must get a wrapper');

  await tick(ctx);
  await tick(ctx);

  assert.equal(ctx.created.length, 2, 'the refused wrapper must be rebuilt');
  assert.equal(ctx.created[1].script, '/app/w.js', 'on what the page asked for');
  assert.deepEqual(ctx.created[1].worker.__posted, [['go']],
    'the message posted to the wrapper must reach the worker that replaced it');
  assert.deepEqual(errors, [],
    "the refused wrapper's error belongs to a worker the page never had");
  assert.equal(ctx.created[0].worker.__terminated, true);
});

test('an error thrown by the site\'s own worker is not read as a refusal', () => {
  // Same event type, opposite meaning: a refusal never reaches any script and
  // so carries no message, while this one is the page's to handle. Rebuilding
  // here would run the site's worker twice.
  const ctx = pageWithStubs(COMBINED);
  const worker = new ctx.window.Worker('/app/w.js');
  const errors = [];
  worker.onerror = (e) => errors.push(e.message);
  worker.dispatchEvent(new ctx.window.ErrorEvent('error', { message: 'boom' }));

  assert.deepEqual(errors, ['boom']);
  assert.equal(ctx.created.length, 1, 'nothing may be rebuilt');
});

test('once blob: workers are known to run, a load failure reaches the page', () => {
  // The mirror of the case above. Anything a wrapped worker says is proof that
  // its wrapper ran, and after that a message-less error is the site's own
  // script failing to load: swallowing it would hide a real breakage.
  const ctx = pageWithStubs(COMBINED);
  const worker = new ctx.window.Worker('/app/w.js');
  const errors = [];
  worker.onerror = () => errors.push('error');
  worker.dispatchEvent(new ctx.window.MessageEvent('message', { data: 'up' }));

  worker.dispatchEvent(new ctx.window.Event('error', { cancelable: true }));
  assert.deepEqual(errors, ['error']);
  assert.equal(ctx.created.length, 1, 'nothing may be rebuilt');
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
  // The shim corrects deviceMemory only where the engine has it, and the
  // worker stub above has it. jsdom's page navigator does not, so without
  // this the two scopes are modelling two different engines and the
  // agreement the test is about cannot be read off them.
  Object.defineProperty(Object.getPrototypeOf(pageDom.window.navigator),
    'deviceMemory', { value: 2, configurable: true });
  pageDom.window.eval(readFixture('anti_fingerprinting/shim_seed_alpha.js'));
  assert.equal(worker.run('navigator.hardwareConcurrency'),
    pageDom.window.navigator.hardwareConcurrency);
  assert.equal(worker.run('navigator.deviceMemory'),
    pageDom.window.navigator.deviceMemory);
  // And not the host's real values from the stub.
  assert.notEqual(worker.run('navigator.hardwareConcurrency'), 10);
  assert.notEqual(worker.run('navigator.deviceMemory'), 2);
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
