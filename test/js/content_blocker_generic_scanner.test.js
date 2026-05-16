// Phase 5 — jsdom assertions for the generic-cosmetic scanner shim
// (test/js_fixtures/content_blocker/generic_scanner.js).
//
// The shim is the page-side half of the Rust engine's
// `hidden_class_id_selectors` lookup: it scans the loaded DOM for
// unique classes and ids, sends them across the InAppWebView bridge
// as `{classes, ids}`, and injects the returned selectors as
// `display: none !important` into a `<style>` tag.
//
// jsdom doesn't ship the real flutter_inappwebview bridge, so each
// test stubs `window.flutter_inappwebview.callHandler` to record the
// payload and resolve with whatever selectors the test wants the
// engine to return.

const test = require('node:test');
const assert = require('node:assert/strict');
const { makeDom, runInDom, readFixture } = require('./helpers/load_shim');

const SCANNER = readFixture('content_blocker/generic_scanner.js');

function setupBridge(dom, returnSelectors) {
  const calls = [];
  dom.window.flutter_inappwebview = {
    callHandler: function(name, payload) {
      calls.push({ name, payload });
      return Promise.resolve(returnSelectors);
    },
  };
  return calls;
}

test('generic scanner: collects every unique class and id on the page',
  async () => {
    const dom = makeDom({ html: `<!doctype html><html><body>
      <div id="hero" class="banner sponsored"></div>
      <span class="banner footer-link" id="ft"></span>
      <p class="real-content"></p>
    </body></html>` });
    const calls = setupBridge(dom, []);
    runInDom(dom, SCANNER);
    await new Promise((r) => setTimeout(r, 10));
    assert.equal(calls.length, 1, 'scanner must call the bridge exactly once');
    assert.equal(calls[0].name, 'genericCosmeticScan');
    const { classes, ids } = calls[0].payload;
    // Set semantics — order doesn't matter, but membership does.
    assert.deepEqual(new Set(classes),
      new Set(['banner', 'sponsored', 'footer-link', 'real-content']));
    assert.deepEqual(new Set(ids), new Set(['hero', 'ft']));
  });

test('generic scanner: injects returned selectors as display:none',
  async () => {
    const dom = makeDom({ html: `<!doctype html><html><body>
      <div class="ad-banner">ad target</div>
      <div class="real-content">keep me</div>
    </body></html>` });
    setupBridge(dom, ['.ad-banner', '#leaderboard']);
    runInDom(dom, SCANNER);
    await new Promise((r) => setTimeout(r, 10));

    const styleEl = dom.window.document.getElementById('_webspace_generic_cosmetic_style');
    assert.ok(styleEl, 'shim must insert its <style> tag');
    const css = styleEl.textContent;
    assert.match(css, /\.ad-banner \{ display: none !important; \}/);
    assert.match(css, /#leaderboard \{ display: none !important; \}/);

    const cs = (sel) =>
      dom.window.getComputedStyle(dom.window.document.querySelector(sel)).display;
    assert.equal(cs('.ad-banner'), 'none',
      'matching element must hide via the injected rule');
    assert.notEqual(cs('.real-content'), 'none',
      'non-matching element stays visible');
  });

test('generic scanner: empty engine response is a no-op', async () => {
  const dom = makeDom({ html: `<!doctype html><html><body>
    <div class="ad-banner">x</div>
  </body></html>` });
  setupBridge(dom, []);
  runInDom(dom, SCANNER);
  await new Promise((r) => setTimeout(r, 10));
  // No <style> tag should be created when there's nothing to inject.
  // (Future engines might return [] frequently — reserving the
  // current shim shape says "skip the DOM mutation entirely".)
  assert.equal(
    dom.window.document.getElementById('_webspace_generic_cosmetic_style'),
    null,
    '<style> tag must not exist when no selectors come back');
});

test('generic scanner: missing flutter_inappwebview bridge is a silent no-op',
  () => {
    // Production scenario: the shim ships in a build where the
    // bridge somehow isn't ready (cold-load race, or the bridge
    // got torn down during navigation). Must not throw.
    const dom = makeDom({ html: '<!doctype html><html><body><div class="x"></div></body></html>' });
    // Deliberately do NOT setupBridge; flutter_inappwebview stays undefined.
    assert.doesNotThrow(() => runInDom(dom, SCANNER));
  });

test('generic scanner: selectors with quotes are escaped before injection',
  async () => {
    // Engine could return attribute selectors like `a[href*="ad"]`.
    // The shim builds a CSS rules string with single-quote-escaped
    // selectors so the surrounding template doesn't get confused.
    const dom = makeDom({ html: `<!doctype html><html><body>
      <a href="https://example.com/ad/x" class="link">x</a>
    </body></html>` });
    setupBridge(dom, ['a[href*="ad"]']);
    runInDom(dom, SCANNER);
    await new Promise((r) => setTimeout(r, 10));
    const styleEl = dom.window.document.getElementById('_webspace_generic_cosmetic_style');
    assert.ok(styleEl);
    // Round-trip: the CSS engine must actually parse and apply the
    // escaped selector. Computed-style is the real signal.
    const cs = dom.window.getComputedStyle(
      dom.window.document.querySelector('a[href*="ad"]'));
    assert.equal(cs.display, 'none',
      'attribute selector must survive escaping and apply');
  });

test('generic scanner: late-added matching elements hide via mutation observer',
  async () => {
    // The phase-5 one-shot scanner missed any element appended
    // AFTER DOMContentLoaded fired — every SPA framework appends
    // its UI in an inline <script> at the end of body, exactly
    // that timing. Phase 14 installs a MutationObserver that
    // rescans for new class/id tokens (deltas, not full DOM) and
    // queries the engine. The bridge stub here pretends the
    // engine sees `.late-promo` only after the page reports it.
    const dom = makeDom({ html: '<!doctype html><html><body></body></html>' });
    const seenClasses = new Set();
    let callIndex = 0;
    dom.window.flutter_inappwebview = {
      callHandler: function(name, payload) {
        callIndex++;
        payload.classes.forEach((c) => seenClasses.add(c));
        // Stubbed engine: return `.late-promo` selector iff the
        // scanner reported the `late-promo` class.
        if (seenClasses.has('late-promo')) {
          return Promise.resolve(['.late-promo']);
        }
        return Promise.resolve([]);
      },
    };
    runInDom(dom, SCANNER);
    // First scan: empty body → no class/id deltas → bridge skipped
    // (the shim short-circuits empty payloads to avoid wasteful
    // roundtrips). callIndex stays 0.
    await new Promise((r) => setTimeout(r, 30));
    assert.equal(callIndex, 0, 'empty page must not invoke bridge');

    // Page appends an element with a new class. The scanner's
    // MutationObserver fires, picks up `late-promo` as a delta,
    // queries the engine, gets back the hide selector.
    const late = dom.window.document.createElement('div');
    late.className = 'late-promo';
    late.id = 'late';
    dom.window.document.body.appendChild(late);
    // Debounce window is 50ms; allow some slack.
    await new Promise((r) => setTimeout(r, 200));
    assert.ok(callIndex >= 1,
      'mutation observer must trigger at least one rescan');
    assert.equal(dom.window.getComputedStyle(late).display, 'none',
      'late-added .late-promo element must hide after engine returns selector');
  });

test('generic scanner: class flip on existing element triggers rescan',
  async () => {
    // Different mutation type — attribute change on an existing
    // element. The observer is configured with attributeFilter
    // for "class" / "id", so adding a tracked class to an
    // already-present element should also fire a rescan.
    const dom = makeDom({ html: '<!doctype html><html><body>' +
      '<div id="el">starts plain</div></body></html>' });
    let seenLateClass = false;
    dom.window.flutter_inappwebview = {
      callHandler: function(name, payload) {
        if (payload.classes.includes('flipped-ad')) seenLateClass = true;
        return Promise.resolve(seenLateClass ? ['.flipped-ad'] : []);
      },
    };
    runInDom(dom, SCANNER);
    await new Promise((r) => setTimeout(r, 30));
    const el = dom.window.document.getElementById('el');
    el.className = 'flipped-ad';
    await new Promise((r) => setTimeout(r, 200));
    assert.equal(dom.window.getComputedStyle(el).display, 'none',
      'element whose class flipped to a matching one must hide');
  });

test('generic scanner: scanner reports only new tokens (delta scanning)',
  async () => {
    // Performance contract: re-scans after the initial one only
    // send classes/ids we haven't already asked the engine about.
    // Otherwise a busy SPA would re-marshall its entire class
    // vocabulary on every DOM burst.
    const dom = makeDom({ html: '<!doctype html><html><body>' +
      '<div class="a"></div><div class="b"></div></body></html>' });
    const callPayloads = [];
    dom.window.flutter_inappwebview = {
      callHandler: function(name, payload) {
        callPayloads.push(payload);
        return Promise.resolve([]);
      },
    };
    runInDom(dom, SCANNER);
    await new Promise((r) => setTimeout(r, 30));
    // Add a third class — only `c` should be in the next payload.
    const late = dom.window.document.createElement('div');
    late.className = 'c';
    dom.window.document.body.appendChild(late);
    await new Promise((r) => setTimeout(r, 200));
    // First payload has both initial classes.
    assert.deepEqual(new Set(callPayloads[0].classes),
      new Set(['a', 'b']));
    // Subsequent payloads ONLY carry the new tokens.
    const latePayload = callPayloads.slice(1).find(
      (p) => p.classes.includes('c'));
    assert.ok(latePayload, 'observer must report `c`');
    assert.equal(latePayload.classes.length, 1,
      'delta scan must NOT include already-seen `a` and `b`; '
        + 'got: ' + JSON.stringify(latePayload.classes));
    assert.equal(latePayload.classes[0], 'c');
  });
