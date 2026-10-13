// A wrapped worker must resolve URLs the way the unwrapped one does (WORK-009).
//
// The wrapper starts every worker from a blob: URL, so without a fix the
// worker's own URL is that blob: `self.location` reports it, and each relative
// URL the site's script hands a loader resolves against a base that cannot hold
// one. `importScripts('lib.js')` throws, `fetch('data.json')` rejects, and
// webpack's chunk path, derived from `self.location`, points at nothing.
//
// Only a real engine resolves URLs against a worker's base, so this is the
// browser tier. Each case runs the same worker unwrapped and wrapped and
// requires the two to agree.

const test = require('node:test');
const assert = require('node:assert/strict');
const WORKER = require('../js/helpers/worker_shims');

const { setupBrowser, requireBrowser } = require('./helpers/launch');
const { startVictim } = require('./helpers/attacker_server');
const { scriptOf } = require('../js/helpers/script_of');

const INSTALLER = WORKER.INSTALLER_COMBINED;
const PAYLOAD = WORKER.COMBINED_PAYLOAD;

const CSP = "default-src 'self'; script-src 'self' blob:; worker-src 'self' blob:";
// worker-src admits the wrapper, script-src refuses the shim it imports.
const NO_BLOB_SCRIPT_CSP = "default-src 'self'; script-src 'self'; worker-src 'self' blob:";

const DATA = '{"from":"data.json"}';

// What a worker's own script sees of its URL, and where each loader it reaches
// for sends a relative URL. Answers on `self` or, for a shared worker, on the
// connecting port.
function baseUrlProbe(shared) {
  function natives() {
    var href = Object.getOwnPropertyDescriptor(WorkerLocation.prototype, 'href');
    return [importScripts, fetch, XMLHttpRequest.prototype.open, Request, href.get,
      WorkerLocation.prototype.toString].map(function (f) {
      return [Function.prototype.toString.call(f), f.name, f.length].join(' | ');
    });
  }
  function nested() {
    return new Promise(function (resolve) {
      try {
        var w = new Worker('leaf.js');
        w.onmessage = function (e) { resolve(e.data); };
        w.onerror = function (e) { resolve({ href: 'error: ' + (e.message || '') }); };
      } catch (e) {
        resolve({ href: e.name });
      }
    });
  }
  function probe(msg) {
    var urls = {
      href: self.location.href,
      asString: String(self.location),
      pathname: self.location.pathname,
      origin: self.location.origin,
      // webpack's automatic publicPath in a worker.
      publicPath: (self.location + '').replace(/#.*$/, '').replace(/\?.*$/, '')
        .replace(/\/[^/]+$/, '/'),
    };
    if (msg.classic) {
      try { importScripts('lib.js'); urls.importScripts = self.__libLoaded === true; }
      catch (e) { urls.importScripts = e.name; }
    }
    try { urls.request = new Request('data.json').url; } catch (e) { urls.request = e.name; }
    try {
      var xhr = new XMLHttpRequest();
      xhr.open('GET', 'data.json', false);
      xhr.send();
      urls.xhr = xhr.responseText;
    } catch (e) { urls.xhr = e.name; }
    var out = {
      urls: urls,
      natives: natives(),
      ownLocation: Object.getOwnPropertyNames(self.location).join(','),
      ownRequest: Object.getOwnPropertyNames(Request).sort().join(','),
      requestCtor: Request.prototype.constructor === Request,
      shimInstalled: !!globalThis.__ws_anti_fp_shim__,
    };
    return fetch('data.json').then(function (r) { return r.text(); })
      .then(function (t) { urls.fetch = t; }, function (e) { urls.fetch = e.name; })
      .then(function () { return msg.nest ? nested() : null; })
      .then(function (n) {
        if (n) { urls.nested = n.href; out.nestedShimInstalled = n.shimInstalled; }
        return out;
      });
  }
  if (shared) {
    self.onconnect = function (ev) {
      var port = ev.ports[0];
      port.onmessage = function (e) { probe(e.data).then(function (r) { port.postMessage(r); }); };
      port.start();
    };
  } else {
    self.onmessage = function (e) { probe(e.data).then(function (r) { postMessage(r); }); };
  }
}

function leafWorker() {
  postMessage({ href: self.location.href, shimInstalled: !!globalThis.__ws_anti_fp_shim__ });
}

function libScript() {
  self.__libLoaded = true;
}

const ASSETS = {
  'probe.js': scriptOf(baseUrlProbe, false),
  'shared_probe.js': scriptOf(baseUrlProbe, true),
  'leaf.js': scriptOf(leafWorker),
  'lib.js': scriptOf(libScript),
  'data.json': DATA,
};

const browser = setupBrowser();

// Runs in the page.
const runProbe = async (opts) => {
  const w = opts.shared
    ? new SharedWorker('/shared_probe.js')
    : new Worker('/probe.js', opts.module ? { type: 'module' } : undefined);
  const port = opts.shared ? w.port : w;
  const done = new Promise((resolve, reject) => {
    port.onmessage = (e) => resolve(e.data);
    w.onerror = (e) => reject(new Error(e.message || 'worker failed to start'));
    setTimeout(() => reject(new Error('timeout')), 15000);
  });
  if (opts.shared) port.start();
  port.postMessage({ classic: !opts.module, nest: !!opts.nest });
  return done;
};

async function probe(t, { csp = CSP, shim, opts }) {
  if (!requireBrowser(browser, t)) return null;
  const victim = await startVictim({ csp, assets: ASSETS });
  const page = await browser.browser.newPage();
  try {
    if (shim) {
      await page.evaluateOnNewDocument(PAYLOAD);
      await page.evaluateOnNewDocument(INSTALLER);
    }
    await page.goto(victim.url, { waitUntil: 'load' });
    return { origin: victim.origin, result: await page.evaluate(runProbe, opts) };
  } finally {
    await page.close();
    await victim.close();
  }
}

// Ports differ between the two runs, so compare with the origin taken out.
function portless(value, origin) {
  return JSON.parse(JSON.stringify(value).split(origin).join('ORIGIN'));
}

const KINDS = {
  classic: {},
  module: { module: true },
  shared: { shared: true },
  'nested in classic': { nest: true },
  'nested in module': { module: true, nest: true },
};

test('PREMISE: an unwrapped worker resolves relative URLs against its own script',
  async (t) => {
    const run = await probe(t, { shim: false, opts: { nest: true } });
    if (!run) return;
    const { origin, result } = run;
    assert.equal(result.shimInstalled, false);
    assert.deepEqual(result.urls, {
      href: `${origin}/probe.js`,
      asString: `${origin}/probe.js`,
      pathname: '/probe.js',
      origin,
      publicPath: `${origin}/`,
      importScripts: true,
      request: `${origin}/data.json`,
      xhr: DATA,
      fetch: DATA,
      nested: `${origin}/leaf.js`,
    });
  });

for (const [kind, opts] of Object.entries(KINDS)) {
  test(`a wrapped ${kind} worker resolves URLs as the unwrapped one does`, async (t) => {
    const bare = await probe(t, { shim: false, opts });
    if (!bare) return;
    const wrapped = await probe(t, { shim: true, opts });
    assert.equal(wrapped.result.shimInstalled, true, 'the worker must be wrapped');
    if (opts.nest) {
      assert.equal(wrapped.result.nestedShimInstalled, true, 'and so must the one it spawns');
    }
    assert.deepEqual(portless(wrapped.result.urls, wrapped.origin),
      portless(bare.result.urls, bare.origin));
  });
}

test('what the fix patches reads as the engine\'s own', async (t) => {
  const bare = await probe(t, { shim: false, opts: {} });
  if (!bare) return;
  const wrapped = await probe(t, { shim: true, opts: {} });
  assert.deepEqual(wrapped.result.natives, bare.result.natives);
  assert.equal(wrapped.result.ownLocation, bare.result.ownLocation);
  assert.equal(wrapped.result.ownRequest, bare.result.ownRequest);
  assert.equal(wrapped.result.requestCtor, true);
});

test('a refused shim import still leaves the worker its own URLs', async (t) => {
  // The fix travels in the wrapper itself, not the shim payload, because this
  // is the CSP where the payload never loads and the site's worker still runs.
  const bare = await probe(t, { csp: NO_BLOB_SCRIPT_CSP, shim: false, opts: {} });
  if (!bare) return;
  const wrapped = await probe(t, { csp: NO_BLOB_SCRIPT_CSP, shim: true, opts: {} });
  assert.equal(wrapped.result.shimInstalled, false, 'the shim import must be refused');
  assert.deepEqual(portless(wrapped.result.urls, wrapped.origin),
    portless(bare.result.urls, bare.origin));
});
