// Attacker-page tier: can a page read its true fingerprint by moving the
// read into a realm the shims do not reach?
//
// The anti-fingerprinting shim spoofs navigator scalars in the document,
// and worker_shim.dart patches Worker/SharedWorker so the same shim is
// preloaded into worker scopes. WORK-002 requires page and worker to
// report identical values: if any reachable realm reports the real
// hardware, a fingerprinter just reads it there and the spoof is worth
// nothing.
//
// jsdom has no Workers at all, so test/js/ can only check the installer's
// shape and test/worker_shim_test.dart only its scope-agnostic source
// patterns. Whether a realm actually ends up covered is a question only a
// real engine answers, which is why these live here.
//
// Realms probed: the document, a classic worker, a module worker, and a
// worker spawned from each of those. The nested-from-module case is a
// fixed escape — see the spec's WORK-005 scenarios.

const test = require('node:test');
const assert = require('node:assert/strict');

const { setupBrowser, requireBrowser, readFixture } = require('./helpers/launch');
const { startVictim } = require('./helpers/attacker_server');

const INSTALLER = readFixture('worker_shim/installer_combined.js');

// The installer embeds the exact shim bundle it preloads into workers
// (anti-fingerprinting + UA identity + location/timezone + language).
// Injecting that same bundle into the document is what the app does via
// initialUserScripts, and it means any page/worker difference is a
// propagation failure rather than two fixtures drifting apart.
const PAYLOAD = (() => {
  const m = INSTALLER.match(/var PAYLOAD = ("(?:[^"\\]|\\.)*");/);
  if (!m) throw new Error('installer fixture no longer embeds a PAYLOAD string');
  return JSON.parse(m[1]);
})();

// The wrapper hands workers a blob: URL, so the page's own CSP has to
// admit blob: workers. The gap test at the bottom covers what happens
// when a site refuses.
const CSP = "default-src 'self'; script-src 'self' blob:; worker-src 'self' blob:";

// Reports its own scope's fingerprint, then optionally spawns a nested
// worker and reports that one too. The leaf URL is passed in because a
// wrapped worker's base URL is the blob, not the origin.
const PROBE_WORKER = `
function scopeVals() {
  return {
    hardwareConcurrency: navigator.hardwareConcurrency,
    deviceMemory: navigator.deviceMemory,
    language: navigator.language,
    shimInstalled: !!globalThis.__ws_anti_fp_shim__,
    wrapperInstalled: !!globalThis.__ws_worker_shim__,
  };
}
self.onmessage = function (ev) {
  var leaf = ev.data && ev.data.leaf;
  var mine = scopeVals();
  if (!leaf) { postMessage({ mine: mine, nested: null }); return; }
  var reply = function (nested) { postMessage({ mine: mine, nested: nested }); };
  try {
    var w = new Worker(leaf);
    var timer = setTimeout(function () { reply({ error: 'timeout' }); }, 8000);
    w.onmessage = function (e) { clearTimeout(timer); reply(e.data); };
    w.onerror = function (e) { clearTimeout(timer); reply({ error: e.message || 'error' }); };
    w.postMessage('go');
  } catch (e) {
    reply({ error: String(e) });
  }
};`;

const LEAF_WORKER = `
self.onmessage = function () {
  postMessage({
    hardwareConcurrency: navigator.hardwareConcurrency,
    deviceMemory: navigator.deviceMemory,
    language: navigator.language,
    shimInstalled: !!globalThis.__ws_anti_fp_shim__,
    wrapperInstalled: !!globalThis.__ws_worker_shim__,
  });
};`;

const ASSETS = { 'probe.js': PROBE_WORKER, 'leaf.js': LEAF_WORKER };

const browser = setupBrowser();

// Drives one page and returns the document's values plus whatever the
// caller asks the worker realms for.
async function withPage(t, { csp = CSP, shim = true } = {}, fn) {
  if (!requireBrowser(browser, t)) return;
  const victim = await startVictim({ csp, assets: ASSETS });
  const page = await browser.browser.newPage();
  try {
    if (shim) {
      await page.evaluateOnNewDocument(PAYLOAD);
      await page.evaluateOnNewDocument(INSTALLER);
    }
    await page.goto(victim.url, { waitUntil: 'load' });
    await fn(page, victim);
  } finally {
    await page.close();
    await victim.close();
  }
}

// Runs in the page. Declared as a real function so Puppeteer serializes
// it and applies the arguments — a string would be evaluated as a bare
// expression and the arguments dropped.
const runWorker = async (opts, leafUrl) => {
  const w = new Worker('/probe.js', opts || undefined);
  const done = new Promise((resolve, reject) => {
    w.onmessage = (e) => resolve(e.data);
    w.onerror = (e) => reject(new Error(e.message || 'worker failed to start'));
    setTimeout(() => reject(new Error('timeout')), 15000);
  });
  w.postMessage({ leaf: leafUrl });
  const r = await done;
  w.terminate();
  return r;
};

// Passed instead of a bare origin when the probe should not nest.
const NO_NEST = null;

function pageVals(page) {
  return page.evaluate(() => ({
    hardwareConcurrency: navigator.hardwareConcurrency,
    deviceMemory: navigator.deviceMemory,
    language: navigator.language,
    shimInstalled: !!globalThis.__ws_anti_fp_shim__,
  }));
}

const FINGERPRINT_KEYS = ['hardwareConcurrency', 'deviceMemory', 'language'];

function assertMatches(realm, actual, expected) {
  for (const k of FINGERPRINT_KEYS) {
    assert.equal(actual[k], expected[k],
      `${realm} leaks a different ${k}: ${actual[k]} vs page ${expected[k]}`);
  }
}

// ---------- premise ----------

test('PREMISE: an unshimmed page and worker report the real hardware',
  async (t) => {
    // Without the shims every realm agrees, because nothing is spoofed.
    // This is what the tests below must not degenerate into: agreement
    // alone is not evidence the spoof is working.
    await withPage(t, { shim: false }, async (page) => {
      const doc = await pageVals(page);
      const { mine } = await page.evaluate(runWorker, null, NO_NEST);
      assert.equal(doc.shimInstalled, false);
      assert.equal(mine.shimInstalled, false);
      assertMatches('unshimmed worker', mine, doc);
    });
  });

test('the shimmed document reports spoofed values', async (t) => {
  await withPage(t, {}, async (page) => {
    const doc = await pageVals(page);
    assert.equal(doc.shimInstalled, true);
    assert.equal(typeof doc.hardwareConcurrency, 'number');
  });
});

// ---------- realm coverage ----------

test('a classic worker reports the same values as the document',
  async (t) => {
    await withPage(t, {}, async (page) => {
      const doc = await pageVals(page);
      const { mine } = await page.evaluate(runWorker, null, NO_NEST);
      assert.equal(mine.shimInstalled, true);
      assertMatches('classic worker', mine, doc);
    });
  });

test('a module worker reports the same values as the document', async (t) => {
  await withPage(t, {}, async (page) => {
    const doc = await pageVals(page);
    const { mine } = await page.evaluate(runWorker, { type: 'module' }, NO_NEST);
    assert.equal(mine.shimInstalled, true);
    assertMatches('module worker', mine, doc);
  });
});

test('a worker spawned from a classic worker stays covered', async (t) => {
  await withPage(t, {}, async (page, victim) => {
    const doc = await pageVals(page);
    const { mine, nested } = await page.evaluate(runWorker, null, victim.origin + '/leaf.js');
    assert.equal(mine.wrapperInstalled, true,
      'the classic worker must re-install the constructor patch');
    assert.ok(!nested.error, `nested worker failed: ${nested.error}`);
    assert.equal(nested.shimInstalled, true);
    assertMatches('worker nested in a classic worker', nested, doc);
  });
});

test('a worker spawned from a module worker stays covered', async (t) => {
  // Regression gate. Module evaluation is hoisted, so an assignment in
  // the wrapper body ran after both imports and the shim's tail found no
  // __wsShimUrl to re-install itself from. Module workers were spoofed
  // but left Worker unpatched, and anything they spawned read the real
  // hardware — two lines of page script to escape the shim entirely.
  await withPage(t, {}, async (page, victim) => {
    const doc = await pageVals(page);
    const { mine, nested } = await page.evaluate(
      runWorker, { type: 'module' }, victim.origin + '/leaf.js');
    assert.equal(mine.wrapperInstalled, true,
      'the module worker must re-install the constructor patch');
    assert.ok(!nested.error, `nested worker failed: ${nested.error}`);
    assert.equal(nested.shimInstalled, true);
    assertMatches('worker nested in a module worker', nested, doc);
  });
});

// ---------- anti-detection ----------

test('the patched Worker constructor is not detectable by stringifying it',
  async (t) => {
    await withPage(t, {}, async (page) => {
      const r = await page.evaluate(() => ({
        worker: Worker.toString(),
        shared: typeof SharedWorker === 'function' ? SharedWorker.toString() : null,
        name: Worker.name,
      }));
      assert.match(r.worker, /\[native code\]/);
      assert.equal(r.name, 'Worker');
      if (r.shared) assert.match(r.shared, /\[native code\]/);
    });
  });

test('the installer markers are enumerable in worker scope too', async (t) => {
  // Same repo-wide convention gap lie_detection.test.js tracks for the
  // window: every shim announces itself with a `__ws*` global, so
  // getOwnPropertyNames finds it. Worth naming separately because a
  // worker is where a fingerprinter looks once the document lies.
  t.todo('repo-wide: __ws* install markers enumerable via getOwnPropertyNames');
});

// ---------- documented gap ----------

const NO_BLOB_CSP = "default-src 'self'; script-src 'self'; worker-src 'self'";

test('KNOWN GAP: the wrapper blob is what a blob-less CSP refuses', async (t) => {
  // The wrapper can only preload the shim by handing the constructor a
  // blob: URL. A site that omits blob: from worker-src blocks that
  // script, and because CSP surfaces the refusal as an async error event
  // rather than a constructor throw, the fail-open fallback in WORK-006
  // never runs — no worker starts.
  //
  // The violation report is what makes this a mechanism and not an
  // inference: the refused URI is the wrapper's blob, under worker-src,
  // on a page whose own worker script is same-origin and allowed.
  await withPage(t, { csp: NO_BLOB_CSP }, async (page) => {
    const r = await page.evaluate(async () => {
      const violations = [];
      document.addEventListener('securitypolicyviolation', (e) => violations.push(
        { directive: e.violatedDirective, blocked: e.blockedURI }));
      let outcome;
      try {
        const w = new Worker('/probe.js');
        outcome = await new Promise((resolve) => {
          w.onmessage = () => resolve('started');
          w.onerror = () => resolve('blocked');
          w.postMessage({ leaf: null });
          setTimeout(() => resolve('timeout'), 5000);
        });
      } catch (e) {
        outcome = `threw:${e.name}`;
      }
      return { outcome, violations };
    });

    assert.equal(r.outcome, 'blocked');
    assert.deepEqual(r.violations, [{ directive: 'worker-src', blocked: 'blob' }],
      'CSP must name the wrapper blob, not the site\'s own worker script');
  });
});

test('PREMISE: the same page under the same CSP gets a working worker '
  + 'without the wrapper — so falling back would be an escape, not a fix',
  async (t) => {
    // Shim the document but leave Worker unpatched, which is what a
    // "just fall back to the original script" fix would amount to here.
    // The worker starts, and reports the real hardware while the document
    // reports the spoof — exactly the page/worker disagreement WORK-002
    // exists to prevent. Whatever fixes the breakage above has to keep
    // these workers shimmed rather than merely running.
    if (!requireBrowser(browser, t)) return;
    const victim = await startVictim({ csp: NO_BLOB_CSP, assets: ASSETS });
    const page = await browser.browser.newPage();
    try {
      await page.evaluateOnNewDocument(PAYLOAD);
      await page.goto(victim.url, { waitUntil: 'load' });
      const doc = await pageVals(page);
      const { mine } = await page.evaluate(runWorker, null, NO_NEST);

      assert.equal(mine.shimInstalled, false, 'the worker must be unshimmed here');
      assert.notEqual(mine.hardwareConcurrency, doc.hardwareConcurrency,
        'an unwrapped worker leaking the same value would make this test vacuous');
    } finally {
      await page.close();
      await victim.close();
    }
  });
