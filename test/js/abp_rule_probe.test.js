// jsdom coverage for the ABP rule probe page
// (test/fixtures/abp_rule_probe.html). The probe's own measurement +
// diagnostic logic had no test: it ran only by being loaded in the app
// on a device. These tests load the real fixture in jsdom, stub the
// flutter_inappwebview bridge, and assert two things:
//
//   1. measure() classifies a row OK/FAIL correctly against the
//      computed display of its sample element (the verdict logic).
//   2. refreshDiagnostics() names the actual reason a cosmetic section
//      produced nothing — engine off, per-site toggle off, or the
//      probe's sample list absent — instead of implying reliability
//      from the (unrelated) DNS bloom.
//
// jsdom's CSS cascade handles the simple class selectors used here
// (the same `display: none !important` via <style> the content-blocker
// shim tests rely on). Combinator/:has() rows need a real engine and
// are intentionally not asserted — that's the browser tier's job.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const PROBE_HTML = path.resolve(
  __dirname, '..', 'fixtures', 'abp_rule_probe.html');
const HTML = fs.readFileSync(PROBE_HTML, 'utf8');

// Build the probe page in jsdom with a stubbed bridge. `url` defaults
// to a file:// origin to mirror the real-world scenario that surfaced
// the diagnostics gap (empty host, scheme file:).
function makeProbe({ url = 'file:///probe.html', abp = null, bloom = null } = {}) {
  const dom = new JSDOM(HTML, {
    url,
    runScripts: 'dangerously',
    pretendToBeVisual: true,
    beforeParse(window) {
      // Record self-scheduled timers so we can cancel the fixture's
      // own setTimeout(measure, …) / 5s network-probe timeouts before
      // they fire — the tests drive measure()/refreshDiagnostics()
      // explicitly and must not race the page's bootstrap.
      window.__timers = [];
      const origSet = window.setTimeout;
      window.setTimeout = function (fn, ms) {
        const id = origSet.call(window, fn, ms);
        window.__timers.push(id);
        return id;
      };
      // The network-probe section is out of scope here; keep fetch from
      // ever resolving so probeFetch()'s post-load DOM writes can't run
      // against a torn-down document.
      window.fetch = function () { return new Promise(function () {}); };
      window.flutter_inappwebview = {
        callHandler(name) {
          if (name === 'getBlockBloom') return Promise.resolve(bloom);
          if (name === 'getAbpProbeStatus') return Promise.resolve(abp);
          return Promise.resolve(null);
        },
      };
    },
  });
  // renderSections() has run synchronously by now; cancel the bootstrap's
  // pending timers so only the test drives the page.
  for (const id of dom.window.__timers) dom.window.clearTimeout(id);
  return dom;
}

// Inject an early-CSS <style> exactly as the content blocker would, so
// measure() sees a real computed display:none on the targeted rows.
function injectHides(doc, selectors) {
  const s = doc.createElement('style');
  s.textContent = selectors.map((sel) => sel + '{display:none !important;}').join(' ');
  doc.head.appendChild(s);
}

function resultClass(doc, rowId) {
  const cell = doc.querySelector('#row-' + rowId + ' [data-result]');
  return cell ? cell.className : null;
}

const tick = () => new Promise((r) => setTimeout(r, 0));

test('measure() marks a supported row BLOCKED (ok) when its target is hidden', async () => {
  const dom = makeProbe();
  const doc = dom.window.document;
  injectHides(doc, ['.advert', '.ad-banner', '.sponsored-content']);
  dom.window.measure();

  for (const id of ['class-advert', 'class-ad-banner', 'class-sponsored']) {
    assert.match(resultClass(doc, id), /\bok\b/, id + ' should be ok when hidden');
  }
  await tick();
  dom.window.close();
});

test('measure() marks a supported row FAIL when its target is NOT hidden', async () => {
  const dom = makeProbe();
  const doc = dom.window.document;
  // Hide nothing; a "supported" row that does not get hidden is a real
  // failure for that section.
  dom.window.measure();
  assert.match(resultClass(doc, 'class-advert'), /\bfail\b/,
    'unhidden supported row should be fail');
  await tick();
  dom.window.close();
});

test('measure() keeps negative-control + FP-guard rows visible (ok)', async () => {
  const dom = makeProbe();
  const doc = dom.window.document;
  // Hide the real supported class, but NOT the FP guard look-alike.
  injectHides(doc, ['.advert']);
  dom.window.measure();

  // Negative control: expected visible, nothing hides it -> ok.
  assert.match(resultClass(doc, 'control-real'), /\bok\b/,
    'editorial control should stay visible/ok');
  // FP guard: .fp_probe_classy must NOT be caught by a .fp_probe_class
  // rule. We never hid it, so it stays visible/ok.
  assert.match(resultClass(doc, 'fp-class-suffix'), /\bok\b/,
    'fp guard look-alike should stay visible/ok');
  await tick();
  dom.window.close();
});

test('diagnostics name the sample list when the canary is loaded', async () => {
  const dom = makeProbe({
    abp: {
      engineActive: true,
      contentBlockEnabled: true,
      pageHideCount: 4,
      pageProceduralCount: 2,
      canaryHits: ['.fp_probe_class'],
      netVerdicts: { 'doubleclick.net': true, 'en.wikipedia.org': false },
    },
  });
  await dom.window.refreshDiagnostics();
  await tick();
  const doc = dom.window.document;
  assert.match(doc.getElementById('diag-cosmetic').textContent, /loaded/);
  assert.match(doc.getElementById('diag-abpnet').textContent, /doubleclick\.net=BLOCK/);
  assert.match(doc.getElementById('diag-warning').textContent, /should fire/);
  dom.window.close();
});

test('diagnostics blame the per-site toggle when content blocking is OFF', async () => {
  const dom = makeProbe({
    abp: {
      engineActive: true,
      contentBlockEnabled: false,
      pageHideCount: 0,
      pageProceduralCount: 0,
      canaryHits: [],
      netVerdicts: {},
    },
  });
  await dom.window.refreshDiagnostics();
  await tick();
  const warn = dom.window.document.getElementById('diag-warning').textContent;
  assert.match(warn, /Content blocker is OFF/i);
  dom.window.close();
});

test('diagnostics blame an absent engine when ABP is not loaded', async () => {
  const dom = makeProbe({
    abp: {
      engineActive: false,
      contentBlockEnabled: true,
      pageHideCount: 0,
      pageProceduralCount: 0,
      canaryHits: [],
      netVerdicts: {},
    },
  });
  await dom.window.refreshDiagnostics();
  await tick();
  const warn = dom.window.document.getElementById('diag-warning').textContent;
  assert.match(warn, /ABP cosmetic engine is not loaded/i);
  dom.window.close();
});
