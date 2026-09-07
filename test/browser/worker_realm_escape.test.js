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

const SHARED_WORKER = `
self.onconnect = function (ev) {
  var port = ev.ports[0];
  port.onmessage = function () {
    port.postMessage({
      hardwareConcurrency: navigator.hardwareConcurrency,
      deviceMemory: navigator.deviceMemory,
      language: navigator.language,
      shimInstalled: !!globalThis.__ws_anti_fp_shim__,
      wrapperInstalled: !!globalThis.__ws_worker_shim__,
    });
  };
  port.start();
};`;

// Answers on a port the page transferred to it, which is the thing a
// MessageChannel in the middle can silently drop: a MessagePort cannot be
// cloned, so a forward that leaves the transfer list behind throws.
const PORT_SHARED_WORKER = `
self.onconnect = function (ev) {
  var port = ev.ports[0];
  port.onmessage = function (e) {
    var given = e.ports && e.ports[0];
    if (!given) { port.postMessage('no-port'); return; }
    given.postMessage('through-the-transferred-port');
    given.start();
  };
  port.start();
};`;

const ASSETS = {
  'probe.js': PROBE_WORKER,
  'leaf.js': LEAF_WORKER,
  'shared.js': SHARED_WORKER,
  'shared_port.js': PORT_SHARED_WORKER,
};

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

// Same, for a SharedWorker: its traffic runs through a MessagePort, which is
// what the refusal path has to keep working.
const runShared = async () => {
  const s = new SharedWorker('/shared.js');
  const errors = [];
  s.onerror = (e) => errors.push(e.message || '(no message)');
  const mine = await new Promise((resolve) => {
    const t = setTimeout(() => resolve(null), 10000);
    s.port.onmessage = (e) => { clearTimeout(t); resolve(e.data); };
    s.port.start();
    s.port.postMessage('go');
  });
  return { mine, errors };
};

// Hands the shared worker one end of a channel of the page's own and waits for
// the answer to come back on it.
const runSharedPort = async () => {
  const s = new SharedWorker('/shared_port.js');
  const ch = new MessageChannel();
  const answer = new Promise((resolve) => {
    setTimeout(() => resolve('timeout'), 10000);
    ch.port1.onmessage = (e) => resolve(e.data);
    ch.port1.start();
  });
  s.port.start();
  s.port.postMessage('take', [ch.port2]);
  return answer;
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

async function withShimmedPage(t, csp, fn, { early = null } = {}) {
  if (!requireBrowser(browser, t)) return;
  const victim = await startVictim({ csp, assets: ASSETS });
  const page = await browser.browser.newPage();
  try {
    await page.evaluateOnNewDocument(RECORD_VIOLATIONS);
    await page.evaluateOnNewDocument(PAYLOAD);
    await page.evaluateOnNewDocument(INSTALLER);
    // Runs in the same turn as the installer, which is what an inline script
    // at the top of the document does — before any answer about blob: workers
    // can have arrived.
    if (early) await page.evaluateOnNewDocument(early);
    await page.goto(victim.url, { waitUntil: 'load' });
    await fn(page, victim);
  } finally {
    await page.close();
    await victim.close();
  }
}

// Builds its worker before the probe can have answered, keeps whatever the
// page's own error handler is given, and posts a message the worker has to
// answer — a wrapper that never loads swallows both.
const EARLY_WORKER = `
globalThis.__earlyErrors = [];
globalThis.__early = new Promise(function (resolve) {
  var w = new Worker('/probe.js');
  w.onerror = function (e) { globalThis.__earlyErrors.push(e.message || '(no message)'); };
  var t = setTimeout(function () { resolve({ error: 'timeout' }); }, 8000);
  w.onmessage = function (e) { clearTimeout(t); resolve(e.data); };
  w.postMessage({ leaf: null });
});`;

async function earlyResult(page) {
  return {
    result: await page.evaluate(() => globalThis.__early),
    errors: await page.evaluate(() => globalThis.__earlyErrors.slice()),
  };
}

test('a document that builds no worker never touches the CSP', async (t) => {
  // Asking up front cost one refusal on every load of every site whose
  // worker-src omits blob:, whether or not the page had any use for a worker.
  // A first party sees that (a securitypolicyviolation listener, a report-uri)
  // and nothing in a stock browser does it, so it announced the app.
  await withShimmedPage(t, NO_BLOB_CSP, async (page) => {
    assert.deepEqual(await page.evaluate(() => globalThis.__wsViolations.slice()), [],
      'nothing may be asked of the policy before the page wants a worker');
  });
});

test('a blob-less CSP costs the shim, not the site\'s workers', async (t) => {
  // messenger.com: worker-src without blob: kills every wrapper, and chromium
  // reports that refusal as an async error event rather than a constructor
  // throw, so the WORK-006 fallback never saw it and no worker started at all
  // — the chat worker died and the PIN prompt hung.
  //
  // The site's first worker is what finds this out now. It is rebuilt on the
  // page's own script behind the object the page holds, and every worker after
  // it is handed that script directly.
  await withShimmedPage(t, NO_BLOB_CSP, async (page) => {
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

    assert.deepEqual(await page.evaluate(() => globalThis.__wsViolations.slice()),
      [{ directive: 'worker-src', blocked: 'blob' }],
      'one refusal buys the answer; nothing after it may be wrapped');
  });
});

test('the worker an inline script builds at document start is rebuilt', async (t) => {
  // The historical shape of this failure (#560): the worker exists before the
  // page has run a line of its own script, and the refusal reaches it as an
  // error event with no constructor left to fall open on.
  await withShimmedPage(t, NO_BLOB_CSP, async (page) => {
    const doc = await pageVals(page);
    const { result, errors } = await earlyResult(page);

    assert.ok(result.mine, 'the early worker must run: ' + JSON.stringify(result));
    assert.deepEqual(errors, [],
      "the refused wrapper's error belongs to a worker the page never had");
    assert.equal(result.mine.shimInstalled, false, 'expected the unshimmed rebuild');
    assert.notEqual(result.mine.hardwareConcurrency, doc.hardwareConcurrency);
    assert.deepEqual(await page.evaluate(() => globalThis.__wsViolations.slice()),
      [{ directive: 'worker-src', blocked: 'blob' }]);
  }, { early: EARLY_WORKER });
});

test('PREMISE: the same early worker is wrapped and shimmed where blob: is allowed', async (t) => {
  // Without this the test above proves nothing: a worker that was never
  // wrapped would run for want of anything to refuse.
  await withShimmedPage(t, CSP, async (page) => {
    const doc = await pageVals(page);
    const { result, errors } = await earlyResult(page);

    assert.ok(result.mine, 'the early worker must run here too');
    assert.deepEqual(errors, []);
    assert.equal(result.mine.shimInstalled, true, 'it does get a wrapper');
    assert.equal(result.mine.hardwareConcurrency, doc.hardwareConcurrency);
    assert.deepEqual(await page.evaluate(() => globalThis.__wsViolations.slice()), []);
  }, { early: EARLY_WORKER });
});

test('a SharedWorker survives the refusal too', async (t) => {
  // It cannot be swapped the way a dedicated worker is: the page takes its
  // MessagePort at construction and a port cannot be re-entangled. It is
  // handed one end of a channel of ours instead, and the other end moves.
  await withShimmedPage(t, NO_BLOB_CSP, async (page) => {
    const doc = await pageVals(page);
    const r = await page.evaluate(runShared);
    assert.ok(r.mine, 'the shared worker must start: ' + JSON.stringify(r));
    assert.deepEqual(r.errors, []);
    assert.equal(r.mine.shimInstalled, false, 'expected the WORK-006 fallback');
    assert.notEqual(r.mine.hardwareConcurrency, doc.hardwareConcurrency);
  });
});

test('a port the page transfers survives the channel in the middle', async (t) => {
  // The bridge stands between the page and its shared worker for the life of
  // the worker, on every site, refusing CSP or not. A forward that dropped the
  // transfer list would throw on any message carrying a port and lose it, so
  // both policies have to carry one end to end.
  for (const csp of [CSP, NO_BLOB_CSP]) {
    await withShimmedPage(t, csp, async (page) => {
      assert.equal(await page.evaluate(runSharedPort), 'through-the-transferred-port',
        `port transfer must survive under: ${csp}`);
    });
  }
});

test('PREMISE: that SharedWorker is wrapped and shimmed where blob: is allowed', async (t) => {
  // Otherwise the test above proves only that the channel does not break a
  // worker that was never wrapped in the first place.
  await withShimmedPage(t, CSP, async (page) => {
    const doc = await pageVals(page);
    const r = await page.evaluate(runShared);
    assert.ok(r.mine, 'the shared worker must start here too');
    assert.equal(r.mine.shimInstalled, true, 'it does get a wrapper');
    assert.equal(r.mine.hardwareConcurrency, doc.hardwareConcurrency);
    assert.deepEqual(await page.evaluate(() => globalThis.__wsViolations.slice()), []);
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
// follows it, and the button did nothing.
const SCRIPT_SRC_FALLBACK_CSP = "script-src 'self' 'unsafe-eval' 'unsafe-inline'";

test('a CSP that only sets script-src is answered by the same worker', async (t) => {
  await withShimmedPage(t, SCRIPT_SRC_FALLBACK_CSP, async (page) => {
    const doc = await pageVals(page);
    const { mine } = await page.evaluate(runWorker, null, NO_NEST);
    assert.ok(mine, "the site's worker must start");
    assert.equal(mine.shimInstalled, false, 'expected the WORK-006 fallback');
    assert.notEqual(mine.hardwareConcurrency, doc.hardwareConcurrency,
      'the fallback worker is the one leaking real values');

    // The console message names script-src ("'worker-src' was not explicitly
    // set, so 'script-src' is used as a fallback") while the violation event
    // reports the effective directive instead, and only the directives that
    // govern worker scripts are read as an answer — so pin the name the
    // engine actually emits.
    assert.deepEqual(await page.evaluate(() => globalThis.__wsViolations.slice()),
      [{ directive: 'worker-src', blocked: 'blob' }]);
  });
});

// blob: is admitted for workers and scripts, refused for images. The site
// breaking its own policy over something unrelated must not cost the shim.
const NO_BLOB_IMAGE_CSP =
  "default-src 'self'; script-src 'self' blob:; worker-src 'self' blob:; img-src 'self'";

test('an unrelated blob: refusal says nothing about workers', async (t) => {
  // Reading any blob: refusal as a worker answer would drop the spoof on a
  // site whose workers are fine, which is the WORK-002 disagreement this
  // feature exists to deny. The violation report carries the whole policy,
  // and the policy says workers may have blob:.
  await withShimmedPage(t, NO_BLOB_IMAGE_CSP, async (page) => {
    const before = await page.evaluate(async () => {
      const url = URL.createObjectURL(new Blob([new Uint8Array(1)], { type: 'image/png' }));
      await new Promise((resolve) => {
        const img = document.createElement('img');
        img.onload = img.onerror = resolve;
        img.src = url;
        document.body.appendChild(img);
      });
      return globalThis.__wsViolations.slice();
    });
    assert.ok(before.some((v) => /^img-src/.test(v.directive)),
      'the premise: the page really did get a blob: image refused, saw ' +
      JSON.stringify(before));

    const doc = await pageVals(page);
    const { mine } = await page.evaluate(runWorker, null, NO_NEST);
    assert.ok(mine, 'the worker must run');
    assert.equal(mine.shimInstalled, true,
      'and must still be wrapped: the refusal was about images');
    assert.equal(mine.hardwareConcurrency, doc.hardwareConcurrency);
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
