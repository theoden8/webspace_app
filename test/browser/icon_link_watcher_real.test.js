// Tier 2: the icon-link watcher (lib/services/icon_link_watcher_shim.dart,
// dumped to test/js_fixtures/icon_link_watcher/shim.js) against Chrome's own
// favicon requests.
//
// The watcher exists to tell the site-icon engine when Blink starts a new
// round of icon candidates for a document it already announced (ICON-011):
// the round Android WebView answers with fresh `onReceivedIcon` calls. The
// candidate list and its re-announcement are Blink (`Document::IconURLs`,
// `LocalFrame::UpdateFaviconURL`), shared by desktop Chrome and Android
// WebView, so desktop Chrome's favicon requests show when a round happened.
// Which candidates get downloaded differs (Chrome picks one, WebView takes
// every `rel=icon`), so every page here declares a single icon and names
// each one uniquely. What WebView then delivers is pinned by the emulator
// tier (integration_test/site_icon_test.dart).
//
// Needs a Chrome with a favicon driver: new-headless Chrome (what
// `npx puppeteer browsers install chrome` gives CI) has one,
// chrome-headless-shell does not.

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const {
  setupBrowser, requireBrowser, readFixture,
} = require('./helpers/launch');

const SHIM = readFixture('icon_link_watcher/shim.js');
const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
  'base64');

const afterLoad = (js) =>
  `<script>addEventListener('load', () => setTimeout(() => { ${js} }, 300));</script>`;

const PAGES = {
  '/badge.html': `<head><link rel="icon" href="/badge/a.png"></head><body>
    ${afterLoad(`
      document.querySelector('link[rel=icon]').remove();
      const l = document.createElement('link');
      l.rel = 'icon'; l.href = '/badge/b.png';
      document.head.append(l);`)}</body>`,
  '/preload.html': `<head><link rel="icon" href="/preload/a.png"></head><body>
    <script>document.querySelector('link[rel=icon]').href = '/preload/b.png';</script>
    </body>`,
  '/spa.html': `<head></head><body>
    ${afterLoad(`
      const l = document.createElement('link');
      l.rel = 'icon'; l.href = '/spa/app.png';
      document.head.append(l);`)}</body>`,
  '/body.html': `<head><link rel="icon" href="/body/a.png"></head><body>
    ${afterLoad(`
      const l = document.createElement('link');
      l.rel = 'icon'; l.href = '/body/b.png';
      document.body.append(l);`)}</body>`,
  '/frame.html': `<head><link rel="icon" href="/frame/top.png"></head><body>
    <iframe src="/frame-child.html"></iframe></body>`,
  '/order.html': `<head><link rel="icon" href="/order/a.png"></head><body></body>`,
  '/frame-child.html': `<head><link rel="icon" href="/frame/c1.png"></head><body>
    ${afterLoad(`document.querySelector('link[rel=icon]').href = '/frame/c2.png';`)}
    </body>`,
};

const browser = setupBrowser();
let server;
let origin;
const iconRequests = [];

test.before(async () => {
  server = http.createServer((req, res) => {
    const path = req.url.split('?')[0];
    if (PAGES[path]) {
      res.writeHead(200, { 'Content-Type': 'text/html' });
      res.end(`<!doctype html><html>${PAGES[path]}</html>`);
      return;
    }
    if (path.startsWith('/report/')) {
      iconRequests.push(path);
      res.writeHead(204);
      res.end();
      return;
    }
    if (path.endsWith('.png') || path === '/favicon.ico') {
      iconRequests.push(path);
      res.writeHead(200, { 'Content-Type': 'image/png', 'Cache-Control': 'no-store' });
      res.end(PNG);
      return;
    }
    res.writeHead(404);
    res.end();
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  origin = `http://127.0.0.1:${server.address().port}`;
});

test.after(() => new Promise((resolve) => server.close(resolve)));

async function visit(t, path) {
  if (!requireBrowser(browser, t)) return null;
  const page = await browser.browser.newPage();
  try {
    // The document reports go to the server synchronously, as the bridge
    // reaches Java before callHandler returns, so the request log shows them
    // in order against Chrome's own icon requests.
    await page.evaluateOnNewDocument(() => {
      window.__wsIconCalls = [];
      window.flutter_inappwebview = {
        callHandler(name, phase, token) {
          if (name === 'wsIconDocument') {
            if (window === window.top) {
              const xhr = new XMLHttpRequest();
              xhr.open('GET', `/report/${phase}?${token}`, false);
              xhr.send();
            }
          } else {
            window.__wsIconCalls.push(name);
          }
          return Promise.resolve();
        },
      };
    });
    await page.evaluateOnNewDocument(SHIM);
    const start = iconRequests.length;
    await page.goto(origin + path, { waitUntil: 'load' });
    await new Promise((r) => setTimeout(r, 1500));
    const frames = [];
    for (const frame of page.frames()) {
      frames.push(await frame.evaluate(() => window.__wsIconCalls.slice()));
    }
    const log = iconRequests.slice(start);
    return {
      log,
      requested: log.filter((p) => !p.startsWith('/report/')),
      top: frames[0],
      frames,
    };
  } finally {
    await page.close();
  }
}

test('a badge swap after load is a new Blink round, and the watcher reports it',
  async (t) => {
    const r = await visit(t, '/badge.html');
    if (!r) return;
    assert.ok(r.requested.includes('/badge/a.png'),
      'Chrome never requested the announced icon: this tier needs a Chrome ' +
      `with a favicon driver (requests: ${JSON.stringify(r.requested)})`);
    assert.ok(r.requested.includes('/badge/b.png'),
      `the badge swap started no new round: ${JSON.stringify(r.requested)}`);
    assert.deepEqual(r.top, ['wsIconLinksChanged']);
  });

test('an edit before load is part of the first round, and is not reported',
  async (t) => {
    const r = await visit(t, '/preload.html');
    if (!r) return;
    assert.ok(r.requested.includes('/preload/b.png'), JSON.stringify(r.requested));
    assert.ok(!r.requested.includes('/preload/a.png'),
      'Blink announced icons before load');
    assert.deepEqual(r.top, []);
  });

test('the first icon an SPA adds after load starts a round the watcher lets through',
  async (t) => {
    const r = await visit(t, '/spa.html');
    if (!r) return;
    assert.ok(r.requested.includes('/spa/app.png'), JSON.stringify(r.requested));
    assert.deepEqual(r.top, []);
  });

test('an icon link outside <head> starts no round and is not reported',
  async (t) => {
    const r = await visit(t, '/body.html');
    if (!r) return;
    assert.ok(r.requested.includes('/body/a.png'), JSON.stringify(r.requested));
    assert.ok(!r.requested.includes('/body/b.png'),
      'Blink took an icon from <body>');
    assert.deepEqual(r.top, []);
  });

test('subframe icons start no round and the subframe copy stays silent',
  async (t) => {
    const r = await visit(t, '/frame.html');
    if (!r) return;
    assert.ok(r.requested.includes('/frame/top.png'), JSON.stringify(r.requested));
    assert.ok(!r.requested.some((p) => p.startsWith('/frame/c')),
      `a subframe icon was requested: ${JSON.stringify(r.requested)}`);
    assert.equal(r.frames.length, 2);
    for (const calls of r.frames) assert.deepEqual(calls, []);
  });

test('the page reports its load event before Chrome asks for its icon',
  async (t) => {
    const r = await visit(t, '/order.html');
    if (!r) return;
    const loadedAt = r.log.indexOf('/report/loaded');
    const iconAt = r.log.indexOf('/order/a.png');
    assert.ok(iconAt >= 0, `no icon request: ${JSON.stringify(r.log)}`);
    assert.equal(r.log.indexOf('/report/started'), 0, JSON.stringify(r.log));
    assert.ok(loadedAt >= 0 && loadedAt < iconAt,
      `the icon was requested before the load report: ${JSON.stringify(r.log)}`);
  });
