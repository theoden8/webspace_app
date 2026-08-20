// Real-Chromium tests for the mobile page-zoom shim
// (lib/services/page_zoom_shim.dart, dumped to
// test/js_fixtures/page_zoom/*.js).
//
// jsdom has no layout and no viewport-meta semantics, so test/js can only
// assert which directives the shim writes. What actually matters is what
// an engine does with them: does the layout viewport widen to
// deviceWidth/z (browser zoom) or stay put (the page shrinking into a
// gutter), and do the site's responsive breakpoints follow it. Chromium
// under mobile emulation resolves the viewport meta the same way the
// WebViews do, so those questions get real answers here.
//
// BUG-008 is the reason for the third question this file asks: the
// Android build pins an explicit `width` to dodge Chromium's
// wide-viewport quirk, and that pin must produce the *same* layout as the
// width-less meta WebKit gets. If the two ever diverge, one platform's
// users see a different page than the other's.

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const {
  setupBrowser, requireBrowser, readFixture,
} = require('./helpers/launch');

// Matches the view extents baked into the page_zoom fixtures.
const DEVICE_WIDTH = 393;
const DEVICE_HEIGHT = 851;

const browser = setupBrowser();

// A responsive page: full-width content (so any horizontal overflow is
// the engine's, not the page's) plus breakpoint probes.
const PAGE = `<!doctype html><html><head>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>html,body{margin:0}#c{width:100%;height:600px;background:#123524}</style>
</head><body><div id="c"></div></body></html>`;

let host = null;
test.before(async () => {
  await new Promise((resolve) => {
    const s = http.createServer((req, res) => {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(PAGE);
    });
    s.listen(0, '127.0.0.1', () => {
      host = { url: `http://127.0.0.1:${s.address().port}/`, server: s };
      resolve();
    });
  });
});
test.after(async () => {
  if (host) await new Promise((r) => host.server.close(r));
});

// Load the page under mobile emulation with `shim` injected at document
// start, and report what the engine made of the viewport.
async function measure(t, shim) {
  if (!requireBrowser(browser, t)) return null;
  const page = await browser.browser.newPage();
  try {
    await page.setViewport({
      width: DEVICE_WIDTH,
      height: DEVICE_HEIGHT,
      deviceScaleFactor: 2.75,
      isMobile: true,
      hasTouch: true,
    });
    if (shim) await page.evaluateOnNewDocument(shim);
    await page.goto(host.url, { waitUntil: 'load' });
    return await page.evaluate(() => {
      const d = document.documentElement;
      return {
        layoutWidth: d.clientWidth,
        scrollWidth: Math.max(d.scrollWidth, document.body.scrollWidth),
        meta: (document.querySelector('meta[name="viewport"]') || {})
          .getAttribute?.('content') ?? null,
        wide768: matchMedia('(min-width: 768px)').matches,
        wide480: matchMedia('(min-width: 480px)').matches,
        rootZoom: getComputedStyle(d).zoom,
      };
    });
  } finally {
    await page.close();
  }
}

test('baseline: no zoom shim lays out at the device width', async (t) => {
  const m = await measure(t, null);
  if (!m) return;
  assert.equal(m.layoutWidth, DEVICE_WIDTH);
  assert.equal(m.wide480, false);
  assert.equal(m.wide768, false);
});

test('80%: the layout viewport widens to deviceWidth/z and reflows', async (t) => {
  const m = await measure(t, readFixture('page_zoom/android_80.js'));
  if (!m) return;
  // Browser zoom means more CSS pixels fit across the same screen.
  assert.ok(
    Math.abs(m.layoutWidth - DEVICE_WIDTH / 0.8) <= 2,
    `layout width ${m.layoutWidth}, expected ~${Math.round(DEVICE_WIDTH / 0.8)}`,
  );
  // The gutter face of BUG-008: the page kept the device width and was
  // merely scaled down.
  assert.notEqual(m.layoutWidth, DEVICE_WIDTH);
  // The 980px face: the wide-viewport fallback.
  assert.ok(m.layoutWidth < 980, `layout width ${m.layoutWidth} hit the wide fallback`);
  assert.equal(m.wide768, false, 'a phone at 80% must not cross a 768px breakpoint');
  assert.equal(m.wide480, true, 'breakpoints must follow the widened layout');
});

test('80%: full-width content still fits — no horizontal overflow', async (t) => {
  const m = await measure(t, readFixture('page_zoom/android_80.js'));
  if (!m) return;
  assert.ok(
    m.scrollWidth <= m.layoutWidth + 1,
    `scrollWidth ${m.scrollWidth} exceeds layout width ${m.layoutWidth}`,
  );
});

test('150%: the layout viewport narrows to deviceWidth/z', async (t) => {
  const m = await measure(t, readFixture('page_zoom/android_150.js'));
  if (!m) return;
  assert.ok(
    Math.abs(m.layoutWidth - DEVICE_WIDTH / 1.5) <= 2,
    `layout width ${m.layoutWidth}, expected ~${Math.round(DEVICE_WIDTH / 1.5)}`,
  );
  assert.equal(m.wide480, false, 'zooming in must move breakpoints down');
  assert.ok(m.scrollWidth <= m.layoutWidth + 1);
});

test('the pinned Android width lays out identically to the WebKit meta', async (t) => {
  // The two builds write different directives for the same zoom — Android
  // pins the width, WebKit lets the engine resolve extend-to-zoom. On an
  // engine that honours both, they must land on the same layout, or the
  // platforms show users different pages.
  const pinned = await measure(t, readFixture('page_zoom/android_80.js'));
  const engine = await measure(t, readFixture('page_zoom/webkit_80.js'));
  if (!pinned || !engine) return;
  assert.ok(
    Math.abs(pinned.layoutWidth - engine.layoutWidth) <= 1,
    `pinned ${pinned.layoutWidth} vs extend-to-zoom ${engine.layoutWidth}`,
  );
  assert.equal(pinned.wide768, engine.wide768);
  assert.equal(pinned.wide480, engine.wide480);
});

test('an under-estimated pin is raised back to extend-to-zoom', async (t) => {
  // The shim errs low on purpose: the width directive implies
  // `min-width: extend-to-zoom`, so a too-small number resolves to the
  // exact engine-derived width. This is what makes the fallback paths
  // (no view extents, a stale innerWidth sample) safe.
  const shim = readFixture('page_zoom/android_80.js')
    .replace(/var PORTRAIT=\d+;/, 'var PORTRAIT=120;')
    .replace(/measured=w>0\?w:-1;/, 'measured=-1;');
  const m = await measure(t, shim);
  if (!m) return;
  assert.match(m.meta, /^width=150,/, `meta was ${m.meta}`);
  assert.ok(
    Math.abs(m.layoutWidth - DEVICE_WIDTH / 0.8) <= 2,
    `layout width ${m.layoutWidth} did not recover from an under-estimate`,
  );
});

test('the zoom rides the viewport, never root CSS zoom, on mobile', async (t) => {
  // Two writers to page scale is what BUG-008 is about; the mobile build
  // must leave the CSS channel alone.
  const m = await measure(t, readFixture('page_zoom/android_80.js'));
  if (!m) return;
  assert.ok(
    m.rootZoom === 'normal' || m.rootZoom === '1',
    `root zoom should be untouched on the viewport channel, got ${m.rootZoom}`,
  );
});
