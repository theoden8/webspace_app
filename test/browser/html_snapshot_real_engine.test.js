// Tier 2 — real-Chromium test for the offline snapshot serializer
// (lib/js/html_snapshot.js).
//
// The snapshot is rendered again on a cold start without network and after a
// renderer the OS killed in the background, so what matters is how the
// engine lays the bytes out, not what they contain: whether the parser picks
// standards mode, whether the stylesheets resolve, whether rules that only
// ever lived in the CSSOM come back. jsdom has no layout and no compat mode,
// so none of that is observable there.
//
// The page is served from one path and the snapshot from another, as the app
// does: the cache renders at the site's currentUrl, which a pushState moves.

const test = require('node:test');
const assert = require('node:assert/strict');
const { setupBrowser, requireBrowser, pageJs } = require('./helpers/launch');
const { listen } = require('./helpers/blank_server');

const SNAPSHOT = pageJs('html_snapshot');
const LEGACY = "window.document.getElementsByTagName('html')[0].outerHTML;";

const PAGE = `<!doctype html><html><head>
<link rel="stylesheet" href="css/site.css">
<style id="cssinjs"></style>
</head><body>
<div id="box">box</div>
<div id="half" style="height:50%"></div>
</body></html>`;

const browser = setupBrowser();

async function startServer() {
  const routes = new Map([
    ['/app/page', PAGE],
    ['/app/css/site.css', '#box { width: 123px; }'],
  ]);
  const requests = [];
  const server = await listen((req, res) => {
    requests.push(req.url);
    const body = routes.get(req.url);
    if (body === undefined) {
      res.writeHead(404);
      res.end();
      return;
    }
    const type = req.url.endsWith('.css') ? 'text/css'
        : req.url.endsWith('.svg') ? 'image/svg+xml' : 'text/html';
    res.writeHead(200, { 'Content-Type': type, 'Cache-Control': 'no-store' });
    res.end(body);
  });
  return { server, routes, requests };
}

function measure(page) {
  return page.evaluate(() => {
    const box = getComputedStyle(document.getElementById('box'));
    return {
      compatMode: document.compatMode,
      width: box.width,
      height: box.height,
      marginLeft: box.marginLeft,
      half: document.getElementById('half').offsetHeight,
    };
  });
}

async function withServer(t, fn) {
  if (!requireBrowser(browser, t)) return;
  const { server, routes, requests } = await startServer();
  const origin = `http://127.0.0.1:${server.address().port}`;
  const page = await browser.browser.newPage();
  try {
    await fn({ page, origin, routes, requests });
  } finally {
    await page.close();
    server.close();
  }
}

async function capture(page, origin, serializer) {
  await page.goto(`${origin}/app/page`, { waitUntil: 'load' });
  await page.evaluate(() => {
    document.getElementById('cssinjs').sheet
        .insertRule('#box { height: 45px; }');
    const adopted = new CSSStyleSheet();
    adopted.replaceSync('#box { margin-left: 7px; }');
    document.adoptedStyleSheets = [adopted];
    history.pushState({}, '', '/elsewhere/deep/path');
  });
  const live = await measure(page);
  const html = await page.evaluate(serializer);
  return { live, html };
}

async function render(page, origin, routes, html) {
  routes.set('/elsewhere/deep/path', html);
  await page.goto(`${origin}/elsewhere/deep/path`, { waitUntil: 'load' });
  return measure(page);
}

test('the snapshot lays out exactly as the live page did', async (t) => {
  await withServer(t, async ({ page, origin, routes }) => {
    const { live, html } = await capture(page, origin, SNAPSHOT);
    assert.deepEqual(live, {
      compatMode: 'CSS1Compat',
      width: '123px',
      height: '45px',
      marginLeft: '7px',
      half: 0,
    });
    assert.deepEqual(await render(page, origin, routes, html), live);
  });
});

test('the plugin serialization it replaces renders differently', async (t) => {
  // Negative demonstrator: if this starts passing as equal, the engine or the
  // plugin changed and the snapshot script may no longer be needed.
  await withServer(t, async ({ page, origin, routes }) => {
    const { live, html } = await capture(page, origin, LEGACY);
    const rendered = await render(page, origin, routes, html);
    assert.equal(rendered.compatMode, 'BackCompat');
    assert.notEqual(rendered.half, live.half,
        'a percentage height resolves against the viewport in quirks mode');
    assert.notEqual(rendered.width, live.width,
        'the relative stylesheet resolves against the pushed path');
    assert.notEqual(rendered.height, live.height,
        'insertRule rules are not in the markup');
    assert.notEqual(rendered.marginLeft, live.marginLeft,
        'adopted stylesheets are not in the markup');
  });
});

test('a page in quirks mode stays in quirks mode', async (t) => {
  await withServer(t, async ({ page, origin, routes }) => {
    routes.set('/app/page', PAGE.replace('<!doctype html>', ''));
    const { live, html } = await capture(page, origin, SNAPSHOT);
    assert.equal(live.compatMode, 'BackCompat');
    assert.deepEqual(await render(page, origin, routes, html), live);
  });
});

test('a page base element is kept rather than overridden', async (t) => {
  await withServer(t, async ({ page, origin, routes }) => {
    routes.set('/app/page', PAGE.replace('<head>', '<head><base href="/app/">'));
    const { live, html } = await capture(page, origin, SNAPSHOT);
    assert.equal((html.match(/<base /g) || []).length, 1);
    assert.deepEqual(await render(page, origin, routes, html), live);
  });
});

test('capturing runs no page code and fetches nothing', async (t) => {
  await withServer(t, async ({ page, origin, routes, requests }) => {
    routes.set('/app/dot.svg',
        '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>');
    routes.set('/app/page', PAGE.replace('</body>', `<x-el></x-el>
<img src="dot.svg"><video preload="auto" src="clip.webm"></video>
<script>
window.constructed = 0;
customElements.define('x-el', class extends HTMLElement {
  constructor() { super(); window.constructed++; }
});
</script></body>`));
    await page.goto(`${origin}/app/page`, { waitUntil: 'networkidle0' });
    const before = await page.evaluate(() => window.constructed);
    requests.length = 0;
    await page.evaluate(SNAPSHOT);
    await new Promise((r) => setTimeout(r, 500));
    assert.equal(await page.evaluate(() => window.constructed), before);
    assert.deepEqual(requests, []);
  });
});
