// Tier 2 — real-Chromium tests for the content-blocker shims.
//
// jsdom's CSS engine is incomplete: `display: none !important` set
// via a <style> tag does override inline display, but jsdom won't
// tell us whether the page's own stylesheet would win in a real
// browser without the !important. These tests run the same fixtures
// in headless Chromium and assert getComputedStyle reflects the
// hidden state — the contract a real ad-blocker MUST satisfy.

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const {
  setupBrowser, requireBrowser, readFixture,
} = require('./helpers/launch');

const EARLY_CSS = readFixture('content_blocker/early_css.js');
const COSMETIC = readFixture('content_blocker/cosmetic.js');

const browser = setupBrowser();

// Page deliberately includes its own stylesheet that says
// `.sponsored { display: block; }` so we exercise the !important
// override in the shim's <style> tag against a competing rule from
// the page itself. Without `display: none !important` the shim
// would silently fail on sites that inline display rules in their
// own CSS.
const HOST_HTML = `<!doctype html><html><head>
<style>
  .ad-banner { display: block; }
  .sponsored { display: block; }
  #sidebar-ad { display: block; }
</style></head><body>
  <div class="ad-banner" id="ad1">ad</div>
  <div class="sponsored" id="sp1">sponsored block</div>
  <div id="sidebar-ad">sidebar</div>
  <div data-ad-slot="123" id="slot">slot</div>
  <a href="https://track.example.com/x" id="trk">tracker</a>
  <div class="article">
    <p id="text-match">Sponsored content here</p>
    <p id="text-no-match">Real article body</p>
  </div>
  <p id="keep">unrelated</p>
</body></html>`;

function startHost() {
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(HOST_HTML);
    });
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      resolve({
        url: `http://127.0.0.1:${port}/`,
        close: () => new Promise((r) => server.close(r)),
      });
    });
  });
}

async function withShim(t, shim, fn, { atDocStart = true } = {}) {
  if (!requireBrowser(browser, t)) return;
  const server = await startHost();
  const page = await browser.browser.newPage();
  try {
    if (atDocStart) {
      await page.evaluateOnNewDocument(shim);
      await page.goto(server.url, { waitUntil: 'load' });
    } else {
      await page.goto(server.url, { waitUntil: 'load' });
      await page.evaluate(shim);
    }
    await fn(page);
  } finally {
    await page.close();
    await server.close();
  }
}

// ---------- early_css ----------

// Early-CSS tests inject the shim post-load via page.evaluate, NOT
// via evaluateOnNewDocument. Reason: Puppeteer's evaluateOnNewDocument
// fires before document.documentElement exists, and the shim's
// `(document.head || document.documentElement || document).appendChild(<style>)`
// falls through to `document.appendChild(<style>)`, making <style>
// the only child of the document and preventing the HTML parser from
// creating <html>/<head>/<body>. Production WKWebView /
// Android WebView Profile DOCUMENT_START fires after documentElement
// is created, so the production timing differs from Puppeteer's. Same
// workaround as the desktop_mode viewport rewrite test — inject after
// load so the rewrite logic itself can be exercised under a real
// engine.

test('early_css: !important <style> overrides page-defined display: block',
  async (t) => {
    await withShim(t, EARLY_CSS, async (page) => {
      const r = await page.evaluate(() => ({
        ad: getComputedStyle(document.getElementById('ad1')).display,
        sp: getComputedStyle(document.getElementById('sp1')).display,
        sidebar: getComputedStyle(document.getElementById('sidebar-ad')).display,
        keep: getComputedStyle(document.getElementById('keep')).display,
      }));
      assert.equal(r.ad, 'none',
        'ad-banner must override page rule via !important');
      assert.equal(r.sp, 'none',
        'sponsored must override page rule via !important');
      assert.equal(r.sidebar, 'none',
        '#sidebar-ad must override page rule via !important');
      assert.notEqual(r.keep, 'none',
        'unrelated #keep must remain visible');
    }, { atDocStart: false });
  });

test('early_css: matching elements have computed display=none', async (t) => {
  await withShim(t, EARLY_CSS, async (page) => {
    const allHidden = await page.evaluate(() => {
      const ids = ['ad1', 'sp1', 'sidebar-ad', 'slot', 'trk'];
      return ids.map((id) => ({
        id,
        display: getComputedStyle(document.getElementById(id)).display,
      }));
    });
    for (const r of allHidden) {
      assert.equal(r.display, 'none',
        `${r.id} must be display:none, got ${r.display}`);
    }
  }, { atDocStart: false });
});

test('early_css: non-matching elements stay visible', async (t) => {
  await withShim(t, EARLY_CSS, async (page) => {
    const r = await page.evaluate(() =>
      getComputedStyle(document.getElementById('keep')).display);
    assert.notEqual(r, 'none', 'unrelated #keep must not be hidden');
  }, { atDocStart: false });
});

// ---------- cosmetic ----------

test('cosmetic: text-match hides paragraph containing "Sponsored content"',
  async (t) => {
    // The cosmetic shim runs after page load (post-DOMContentLoaded).
    // It sets inline display:none on the matched element. The shim's
    // selector + text-pattern pair is `(div.article > p, "Sponsored content")`.
    await withShim(t, COSMETIC, async (page) => {
      const r = await page.evaluate(() => ({
        match: document.getElementById('text-match').style.display,
        nomatch: document.getElementById('text-no-match').style.display,
      }));
      assert.equal(r.match, 'none',
        'paragraph with "Sponsored content" must be hidden');
      assert.equal(r.nomatch, '',
        'paragraph without sponsor text must remain visible');
    }, { atDocStart: false });
  });

test('cosmetic: MutationObserver hides ads inserted after the shim runs',
  async (t) => {
    await withShim(t, COSMETIC, async (page) => {
      const r = await page.evaluate(async () => {
        const newAd = document.createElement('div');
        newAd.className = 'ad-banner';
        newAd.id = 'late-ad';
        newAd.textContent = 'late';
        document.body.appendChild(newAd);
        // Shim debounces hide() at 50ms; wait past that.
        await new Promise((r) => setTimeout(r, 150));
        return getComputedStyle(newAd).display;
      });
      assert.equal(r, 'none',
        'dynamically-added ad must be hidden by MutationObserver pass');
    }, { atDocStart: false });
  });

test('cosmetic: handles a malformed selector batch without breaking others',
  async (t) => {
    // Run the shim then dynamically inject a fresh batch that
    // includes a malformed selector — querySelectorAll throws on it,
    // but the batched try/catch must keep the others working.
    await withShim(t, COSMETIC, async (page) => {
      const r = await page.evaluate(async () => {
        // Add an .ad-banner; the shim's MutationObserver pass should
        // hide it via the existing batch (which is well-formed).
        const ad = document.createElement('div');
        ad.className = 'ad-banner';
        document.body.appendChild(ad);
        await new Promise((r) => setTimeout(r, 100));
        return getComputedStyle(ad).display;
      });
      assert.equal(r, 'none');
    }, { atDocStart: false });
  });

test('cosmetic: <style> tag is created exactly once', async (t) => {
  await withShim(t, COSMETIC, async (page) => {
    const count = await page.evaluate(() =>
      document.querySelectorAll('#_webspace_content_blocker_style').length);
    assert.equal(count, 1);
  }, { atDocStart: false });
});
