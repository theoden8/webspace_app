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

// ---------- CSP refusing blob: workers ----------

// Models an engine that refuses a blob: worker at construction time
// rather than asynchronously. Installed before the installer so it is
// what the installer captures as the real constructor.
const SYNC_REFUSING_ENGINE = `
(function () {
  var Real = globalThis.Worker;
  function Refusing(script, options) {
    if (String(script).indexOf('blob:') === 0) {
      throw new DOMException('Refused to create a worker from blob:', 'SecurityError');
    }
    return new Real(script, options);
  }
  Refusing.prototype = Real.prototype;
  globalThis.Worker = Refusing;
})();`;

const CREATE_OBJECT_URL_THROWS = `
URL.createObjectURL = function () { throw new Error('refused'); };`;

test('WORK-006 fail-open yields a working but UNSHIMMED worker', async (t) => {
  // Which failure mode an engine picks is native and outside this tier:
  // Chromium refuses a CSP-blocked blob worker asynchronously (above), so
  // the fallback never runs. An engine that refuses at construction, or
  // any failure inside wrap(), takes the other branch — and that branch
  // is testable here, whichever engine ends up on it.
  //
  // It resolves to an escape. WORK-006 says a broken worker is worse than
  // an unspoofed one, so this is the documented trade being made, not a
  // defect in the implementation. It is pinned because the cost is
  // invisible in the spec text: the worker that "still works" reports the
  // real hardware while the document reports the spoof, which is exactly
  // the WORK-002 disagreement a fingerprinter looks for.
  const triggers = {
    'engine refuses blob: at construction': SYNC_REFUSING_ENGINE,
    'URL.createObjectURL throws': CREATE_OBJECT_URL_THROWS,
  };

  for (const [name, inject] of Object.entries(triggers)) {
    if (!requireBrowser(browser, t)) return;
    const victim = await startVictim({ csp: CSP, assets: ASSETS });
    const page = await browser.browser.newPage();
    try {
      await page.evaluateOnNewDocument(PAYLOAD);
      // The engine stub has to precede the installer; the
      // createObjectURL stub has to follow it, since wrap() reads
      // URL.createObjectURL at call time.
      if (inject === SYNC_REFUSING_ENGINE) await page.evaluateOnNewDocument(inject);
      await page.evaluateOnNewDocument(INSTALLER);
      if (inject === CREATE_OBJECT_URL_THROWS) await page.evaluateOnNewDocument(inject);
      await page.goto(victim.url, { waitUntil: 'load' });

      const doc = await pageVals(page);
      const { mine } = await page.evaluate(runWorker, null, NO_NEST);

      assert.ok(mine, `${name}: no worker was created — fail-open did not fire`);
      assert.equal(mine.shimInstalled, false, `${name}: expected the unshimmed fallback`);
      assert.notEqual(mine.hardwareConcurrency, doc.hardwareConcurrency,
        `${name}: the fallback worker must be the one leaking real values`);
      assert.notEqual(mine.deviceMemory, doc.deviceMemory, name);
    } finally {
      await page.close();
      await victim.close();
    }
  }
});

const NO_BLOB_CSP = "default-src 'self'; script-src 'self'; worker-src 'self'";

// Registered ahead of the installer so the probe's own violation, which
// fires at document start, is recorded too.
const RECORD_VIOLATIONS = `
globalThis.__wsViolations = [];
document.addEventListener('securitypolicyviolation', function (e) {
  globalThis.__wsViolations.push(
    { directive: e.violatedDirective, blocked: e.blockedURI });
}, true);`;

async function withShimmedPage(t, csp, fn) {
  if (!requireBrowser(browser, t)) return;
  const victim = await startVictim({ csp, assets: ASSETS });
  const page = await browser.browser.newPage();
  try {
    await page.evaluateOnNewDocument(RECORD_VIOLATIONS);
    await page.evaluateOnNewDocument(PAYLOAD);
    await page.evaluateOnNewDocument(INSTALLER);
    await page.goto(victim.url, { waitUntil: 'load' });
    await fn(page, victim);
  } finally {
    await page.close();
    await victim.close();
  }
}

test('a blob-less CSP costs the shim, not the site\'s workers', async (t) => {
  // messenger.com: worker-src without blob: refuses every wrapper, and
  // chromium reports that refusal as an async error event rather than a
  // constructor throw, so the WORK-006 fallback never saw it and no
  // worker started at all — the chat worker died and the PIN prompt hung.
  //
  // The installer now asks the engine first, with one throwaway blob
  // worker at document start. The violation report is what makes this a
  // mechanism and not an inference: the only refused URI is that probe's
  // blob, under worker-src, on a page whose own worker script is
  // same-origin and allowed.
  await withShimmedPage(t, NO_BLOB_CSP, async (page) => {
    const beforeWorker = await page.evaluate(() => globalThis.__wsViolations.slice());
    assert.deepEqual(beforeWorker, [{ directive: 'worker-src', blocked: 'blob' }],
      'the probe must be what the CSP refuses, and it must have run by load');

    const doc = await pageVals(page);
    const classic = await page.evaluate(runWorker, null, NO_NEST);
    const module = await page.evaluate(runWorker, { type: 'module' }, NO_NEST);

    for (const [kind, r] of [['classic', classic], ['module', module]]) {
      assert.ok(r.mine, `${kind}: the site's worker must start`);
      // The cost, pinned rather than implied: WORK-006 buys a live worker
      // with a page/worker disagreement, which is the signal WORK-002
      // exists to deny. No wrapper can preload a shim past this CSP.
      assert.equal(r.mine.shimInstalled, false, `${kind}: expected the fallback`);
      assert.notEqual(r.mine.hardwareConcurrency, doc.hardwareConcurrency,
        `${kind}: the fallback worker is the one leaking real values`);
    }

    assert.equal(await page.evaluate(() => globalThis.__wsViolations.length), 1,
      'no wrapper may be handed to the constructor after the refusal');
  });
});

// worker-src admits the wrapper, script-src refuses what it imports.
const NO_BLOB_SCRIPT_CSP =
  "default-src 'self'; script-src 'self'; worker-src 'self' blob:";

test('a refused shim import leaves the worker running, unshimmed', async (t) => {
  // The wrapper starts here — it is the shim's importScripts that CSP
  // kills, inside a blob worker that inherited the document's policy.
  // Uncaught, that takes the site's own script down with it, which is the
  // same breakage one checkpoint later.
  await withShimmedPage(t, NO_BLOB_SCRIPT_CSP, async (page) => {
    const doc = await pageVals(page);
    const { mine } = await page.evaluate(runWorker, null, NO_NEST);
    assert.ok(mine, 'the worker must start despite the refused shim import');
    assert.equal(mine.shimInstalled, false);
    assert.notEqual(mine.hardwareConcurrency, doc.hardwareConcurrency);
  });
});

// Neither worker-src nor default-src is set, so chromium falls back to
// script-src for worker scripts. A retailer sign-in reported this shape
// (#567) with the refused blob and the importScripts NetworkError that
// follows it, and the button did nothing. The two cases above both name
// worker-src explicitly, so nothing pinned the fallback.
const SCRIPT_SRC_FALLBACK_CSP = "script-src 'self' 'unsafe-eval' 'unsafe-inline'";

test('a CSP that only sets script-src still answers the probe', async (t) => {
  await withShimmedPage(t, SCRIPT_SRC_FALLBACK_CSP, async (page) => {
    const beforeWorker = await page.evaluate(() => globalThis.__wsViolations.slice());
    // The console message names script-src ("'worker-src' was not
    // explicitly set, so 'script-src' is used as a fallback") while the
    // violation event reports the effective directive instead. The
    // installer's filter has to accept whichever name arrives, so pin
    // the one the engine actually emits.
    assert.deepEqual(beforeWorker, [{ directive: 'worker-src', blocked: 'blob' }],
      'the probe must be refused here, and have run by load');

    const doc = await pageVals(page);
    const { mine } = await page.evaluate(runWorker, null, NO_NEST);
    assert.ok(mine, "the site's worker must start");
    assert.equal(mine.shimInstalled, false, 'expected the WORK-006 fallback');
    assert.notEqual(mine.hardwareConcurrency, doc.hardwareConcurrency,
      'the fallback worker is the one leaking real values');

    assert.equal(await page.evaluate(() => globalThis.__wsViolations.length), 1,
      'no wrapper may be handed to the constructor after the refusal');
  });
});

test('PREMISE: the fallback is exactly an unpatched Worker', async (t) => {
    // Shim the document but leave Worker unpatched — what the fallback
    // above amounts to. The worker starts and reports the real hardware
    // while the document reports the spoof, so the assertions above are
    // measuring the trade, not a vacuous agreement.
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
