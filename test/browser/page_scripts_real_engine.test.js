// Real-Chromium tier for the page scripts that moved out of webview.dart
// (block_interceptor_shim.dart, page_zoom_shim.dart's CSS and text zoom).
// jsdom has no layout and no Resource Timing, so these answer what it
// cannot: does the zoom reach the computed style, and does the observer see
// what the page actually loaded.

const test = require('node:test');
const assert = require('node:assert/strict');
const { setupBrowser, requireBrowser, pageJs } = require('./helpers/launch');
const { startBlankServer, originOf } = require('./helpers/blank_server');

const browser = setupBrowser();

const PAGE = '<!doctype html><html><head></head><body><p>x</p></body></html>';

let host = null;
test.before(async () => {
  const server = await startBlankServer(PAGE, 'text/html; charset=utf-8');
  host = { url: `${originOf(server)}/`, server };
});
test.after(async () => {
  if (host) await new Promise((r) => host.server.close(r));
});

async function withPage(t, scripts, body) {
  if (!requireBrowser(browser, t)) return;
  const page = await browser.browser.newPage();
  try {
    for (const s of scripts) await page.evaluateOnNewDocument(s);
    await page.goto(host.url, { waitUntil: 'load' });
    await body(page);
  } finally {
    await page.close();
  }
}

test('the CSS page zoom reaches the root computed style', async (t) => {
  await withPage(t, [pageJs('page_zoom_css', { zoomPercent: 120 })], async (page) => {
    const zoom = await page.evaluate(
      () => getComputedStyle(document.documentElement).zoom);
    assert.equal(zoom, '1.2');
  });
});

test('the text zoom installs its size adjust', async (t) => {
  await withPage(t, [pageJs('text_zoom', { zoomPercent: 150 })], async (page) => {
    const css = await page.evaluate(
      () => document.getElementById('__webspace_text_zoom__').textContent);
    assert.match(css, /-webkit-text-size-adjust:150%/);
  });
});

// The bridge stub, installed ahead of the shims as the plugin's is.
const BRIDGE = `
  window.__calls = [];
  window.flutter_inappwebview = {
    callHandler: function (name, arg) {
      window.__calls.push([name, arg]);
      if (name === 'getBlockBloom') {
        return Promise.resolve({ bits: new Array(8).fill(255), bitCount: 64, k: 1 });
      }
      if (name === 'blockCheck') {
        if (arg.indexOf('redirect.invalid') >= 0) {
          return Promise.resolve('data:text/plain,stub');
        }
        return Promise.resolve(arg.indexOf('blocked.invalid') >= 0);
      }
      return Promise.resolve(null);
    },
  };`;

test('the interceptor drops a blocked fetch and lets the rest through', async (t) => {
  await withPage(t, [BRIDGE, pageJs('block_js_interceptor')],
    async (page) => {
      const out = await page.evaluate(async (origin) => {
        await new Promise((r) => setTimeout(r, 50));
        const ok = await fetch(`${origin}/fine`).then((r) => r.status);
        const blocked = await fetch('https://blocked.invalid/t.js')
          .then(() => 'loaded', (e) => e.message);
        return { ok, blocked };
      }, host.url.replace(/\/$/, ''));
      assert.equal(out.ok, 200);
      assert.match(out.blocked, /^Blocked: /);
    });
});

test('a redirect verdict serves the stub body (CB-010)', async (t) => {
  await withPage(t, [BRIDGE, pageJs('block_js_interceptor')],
    async (page) => {
      const body = await page.evaluate(async () => {
        await new Promise((r) => setTimeout(r, 50));
        return fetch('https://redirect.invalid/gtm.js').then((r) => r.text());
      });
      assert.equal(body, 'stub');
    });
});

test('the observer reports the hosts the page loaded from', async (t) => {
  await withPage(t, [BRIDGE, pageJs('block_resource_observer')],
    async (page) => {
      await new Promise((r) => setTimeout(r, 400));
      const batches = await page.evaluate(() => window.__calls
        .filter(([name]) => name === 'blockResourceLoadedBatch')
        .map(([, hosts]) => hosts));
      assert.deepEqual(batches, [[new URL(host.url).hostname]]);
    });
});
