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
