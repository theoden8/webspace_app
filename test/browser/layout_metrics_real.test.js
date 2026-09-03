// Tier 2 — real-Chromium tests for the layout/text-metrics half of the
// anti-fingerprinting shim (lib/services/anti_fingerprinting_shim.dart).
//
// jsdom has no TextMetrics and no DOMRectList, and its getClientRects returns
// a plain Array for every element, so the Tier 1 tests can only assert that
// the shim installs. The facts that matter here are types the engine owns:
// that the object handed back is the engine's own, that it carries no own
// properties, and that DOMRectList survives the wrapper. Those are exactly
// what the previous object-literal implementation got wrong, and exactly what
// jsdom cannot fail on.

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  setupBrowser, requireBrowser, readFixture,
} = require('./helpers/launch');

const ALPHA = readFixture('anti_fingerprinting/shim_seed_alpha.js');
const BETA = readFixture('anti_fingerprinting/shim_seed_beta.js');

const PAGE = `<!doctype html><html><body>
  <div id="d" style="width:120px;height:40px;margin:7px">rect</div>
  <span id="s">some measured text that wraps across a couple of lines</span>
  <canvas id="c"></canvas>
</body></html>`;

const browser = setupBrowser();

async function withShim(t, shim, fn) {
  if (!requireBrowser(browser, t)) return;
  const page = await browser.browser.newPage();
  try {
    await page.setContent(PAGE, { waitUntil: 'load' });
    if (shim) await page.evaluate(shim);
    await fn(page);
  } finally {
    await page.close();
  }
}

test('measureText returns the engine TextMetrics with no own properties',
  async (t) => {
    await withShim(t, ALPHA, async (page) => {
      const r = await page.evaluate(() => {
        const ctx = document.getElementById('c').getContext('2d');
        const m = ctx.measureText('hello');
        return {
          isTextMetrics: m instanceof TextMetrics,
          protoIsTextMetrics: Object.getPrototypeOf(m) === TextMetrics.prototype,
          ownProps: Object.getOwnPropertyNames(m),
          widthIsNumber: typeof m.width === 'number',
        };
      });
      assert.equal(r.isTextMetrics, true);
      assert.equal(r.protoIsTextMetrics, true);
      assert.deepEqual(r.ownProps, []);
      assert.equal(r.widthIsNumber, true);
    });
  });

test('the text jitter is real, seeded, and below the visible threshold',
  async (t) => {
    // Measured against the unshimmed engine, which is the only way to know
    // the number moved at all.
    let raw;
    await withShim(t, null, async (page) => {
      raw = await page.evaluate(
        () => document.getElementById('c').getContext('2d').measureText('hello').width);
    });
    const widths = [];
    for (const shim of [ALPHA, ALPHA, BETA]) {
      await withShim(t, shim, async (page) => {
        widths.push(await page.evaluate(
          () => document.getElementById('c').getContext('2d').measureText('hello').width));
      });
    }
    if (widths.length !== 3) return; // tier skipped
    assert.notEqual(widths[0], raw, 'jitter must move the value');
    assert.equal(widths[0], widths[1], 'same seed, same width');
    assert.notEqual(widths[0], widths[2], 'different seed, different width');
    assert.ok(Math.abs(widths[0] - raw) < raw * 0.001,
      `width moved ${Math.abs(widths[0] - raw)} from ${raw}, outside the bound`);
  });

test('getBoundingClientRect returns a real DOMRect', async (t) => {
  await withShim(t, ALPHA, async (page) => {
    const r = await page.evaluate(() => {
      const rect = document.getElementById('d').getBoundingClientRect();
      return {
        isDOMRect: rect instanceof DOMRect,
        hasToJSON: typeof rect.toJSON === 'function',
        ownProps: Object.getOwnPropertyNames(rect),
      };
    });
    assert.equal(r.isDOMRect, true);
    assert.equal(r.hasToJSON, true);
    assert.deepEqual(r.ownProps, []);
  });
});

test('getClientRects stays a DOMRectList and is jittered like the bounding rect',
  async (t) => {
    // Unwrapped, this was the un-jittered geometry of the same element,
    // readable straight past getBoundingClientRect.
    let raw;
    await withShim(t, null, async (page) => {
      raw = await page.evaluate(
        () => document.getElementById('s').getClientRects()[0].x);
    });
    await withShim(t, ALPHA, async (page) => {
      const r = await page.evaluate(() => {
        const list = document.getElementById('s').getClientRects();
        return {
          isDOMRectList: list instanceof DOMRectList,
          isArray: Array.isArray(list),
          length: list.length,
          firstIsDOMRect: list[0] instanceof DOMRect,
          x: list[0].x,
          itemMatches: list.item(0) === list[0],
          itemOutOfRange: list.item(99),
        };
      });
      assert.equal(r.isDOMRectList, true, 'must stay a DOMRectList');
      assert.equal(r.isArray, false);
      assert.ok(r.length >= 1);
      assert.equal(r.firstIsDOMRect, true);
      assert.equal(r.itemMatches, true);
      assert.equal(r.itemOutOfRange, null);
      assert.notEqual(r.x, raw, 'the list must be jittered, not raw geometry');
      assert.ok(Math.abs(r.x - raw) < 0.001);
    });
  });
