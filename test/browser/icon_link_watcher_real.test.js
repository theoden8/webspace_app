// Tier 2: the icon-link watcher (lib/services/icon_link_watcher_shim.dart,
// dumped to test/js_fixtures/icon_link_watcher/shim.js) against Chrome's own
// favicon requests.
//
// The watcher tells the site-icon engine three things Blink decides:
// that the top document's load event fired, ahead of any icon request
// (ICON-012), which icon links it announced (ICON-013), and when a new round
// of candidates starts for a document already announced (ICON-011): the
// round Android WebView answers with fresh `onReceivedIcon` calls. The
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
  '/frame-child.html': `<head><link rel="icon" href="/frame/c1.png"></head><body>
    ${afterLoad(`document.querySelector('link[rel=icon]').href = '/frame/c2.png';`)}
    </body>`,
  '/plain.html': '<head></head><body>no icon</body>',
};

const CHANGED = 'wsIconLinksChanged';
const LOADED = 'wsIconDocumentLoaded';
const LINKS = 'wsIconLinks';

const browser = setupBrowser();
let server;
let origin;
const iconRequests = [];
const iconRequestTimes = [];

test.before(async () => {
  server = http.createServer((req, res) => {
    const path = req.url.split('?')[0];
    if (PAGES[path]) {
      res.writeHead(200, { 'Content-Type': 'text/html' });
      res.end(`<!doctype html><html>${PAGES[path]}</html>`);
      return;
    }
    if (path.endsWith('.png') || path === '/favicon.ico') {
      iconRequests.push(path);
      iconRequestTimes.push(Date.now());
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
    await page.evaluateOnNewDocument(() => {
      window.__wsIconCalls = [];
      window.flutter_inappwebview = {
        callHandler(name, ...args) {
          window.__wsIconCalls.push({ name, args, at: Date.now() });
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
    const names = (calls) => calls.map((c) => c.name);
    const only = (calls, name) => calls.filter((c) => c.name === name);
    return {
      requested: iconRequests.slice(start),
      requestTimes: iconRequestTimes.slice(start),
      top: names(frames[0]),
      changes: names(only(frames[0], CHANGED)),
      loadedAt: only(frames[0], LOADED).map((c) => c.at),
      links: only(frames[0], LINKS).map((c) =>
        c.args[0].map((l) => new URL(l.href).pathname)),
      frames: frames.map(names),
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
    assert.deepEqual(r.top, [LOADED, LINKS, CHANGED]);
    assert.deepEqual(r.links, [['/badge/a.png']]);
  });

test('the load report comes before Chrome requests the icon', async (t) => {
  const r = await visit(t, '/badge.html');
  if (!r) return;
  assert.equal(r.loadedAt.length, 1);
  assert.ok(r.requestTimes.length > 0, 'Chrome requested no icon');
  assert.ok(r.loadedAt[0] <= r.requestTimes[0],
    `icon requested ${r.loadedAt[0] - r.requestTimes[0]}ms before the load report`);
});

test('with no icon links the report is empty and Chrome asks for /favicon.ico',
  async (t) => {
    const r = await visit(t, '/plain.html');
    if (!r) return;
    assert.deepEqual(r.links, [[]]);
    assert.deepEqual(r.requested, ['/favicon.ico']);
  });

test('an edit before load is part of the first round, and is not reported',
  async (t) => {
    const r = await visit(t, '/preload.html');
    if (!r) return;
    assert.ok(r.requested.includes('/preload/b.png'), JSON.stringify(r.requested));
    assert.ok(!r.requested.includes('/preload/a.png'),
      'Blink announced icons before load');
    assert.deepEqual(r.changes, []);
    assert.deepEqual(r.links, [['/preload/b.png']]);
  });

test('the first icon an SPA adds after load starts a round the watcher lets through',
  async (t) => {
    const r = await visit(t, '/spa.html');
    if (!r) return;
    assert.ok(r.requested.includes('/spa/app.png'), JSON.stringify(r.requested));
    assert.deepEqual(r.changes, []);
  });

test('an icon link outside <head> starts no round and is not reported',
  async (t) => {
    const r = await visit(t, '/body.html');
    if (!r) return;
    assert.ok(r.requested.includes('/body/a.png'), JSON.stringify(r.requested));
    assert.ok(!r.requested.includes('/body/b.png'),
      'Blink took an icon from <body>');
    assert.deepEqual(r.changes, []);
  });

test('subframe icons start no round and the subframe copy stays silent',
  async (t) => {
    const r = await visit(t, '/frame.html');
    if (!r) return;
    assert.ok(r.requested.includes('/frame/top.png'), JSON.stringify(r.requested));
    assert.ok(!r.requested.some((p) => p.startsWith('/frame/c')),
      `a subframe icon was requested: ${JSON.stringify(r.requested)}`);
    assert.equal(r.frames.length, 2);
    assert.deepEqual(r.frames[0], [LOADED, LINKS]);
    assert.deepEqual(r.frames[1], [], 'the subframe copy reported');
  });
