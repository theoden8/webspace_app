// NAV-016: an arrow pressed in a frame reaches only that frame's document, so
// lib/js/remote_edge.js runs in every frame and passes an arrow its frame had
// no use for up to the top document, which alone calls the bridge. jsdom's
// postMessage names no source and its frames share an origin; here the frames
// are cross-origin and the keys are Chromium's.

const test = require('node:test');
const assert = require('node:assert/strict');
const { setupBrowser, requireBrowser, pageJs } = require('./helpers/launch');
const { listen, originOf } = require('./helpers/blank_server');

// Spatial navigation on, as the Android TV WebView has it: an arrow moves
// focus between links, and scrolls only where none is that way.
const browser = setupBrowser({
  args: ['--no-sandbox', '--disable-setuid-sandbox', '--enable-spatial-navigation'],
});

const BUTTONS = '<button id="b0">b0</button><button id="b1">b1</button>';

// Two origins: the top page on one, its frames on the other; a frame of a
// frame back on the first.
async function servers() {
  const pages = {};
  const serve = (req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(`<!doctype html><html><head><style>body{margin:0}</style></head>` +
      `<body>${pages[req.url] ?? ''}</body></html>`);
  };
  const site = await listen(serve);
  const other = await listen(serve);
  return { pages, site: originOf(site), other: originOf(other), all: [site, other] };
}

async function newPage() {
  const page = await browser.browser.newPage();
  await page.evaluateOnNewDocument(() => {
    window.__calls = [];
    window.flutter_inappwebview = {
      callHandler: (name, direction) => {
        window.__calls.push([name, direction]);
        return Promise.resolve();
      },
    };
  });
  await page.evaluateOnNewDocument(pageJs('remote_edge', { handler: 'wsRemoteEdge' }));
  return page;
}

const frameAt = (page, path) => page.frames().find((f) => f.url().endsWith(path));
const calls = (frame) => frame.evaluate(() => window.__calls);
const settle = () => new Promise((r) => setTimeout(r, 400));

test('an arrow a cross-origin frame had no use for reaches the bridge from the top (NAV-016)', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const s = await servers();
  const page = await newPage();
  try {
    s.pages['/frame'] = BUTTONS;
    s.pages['/'] = `<iframe src="${s.other}/frame" style="border:0;width:300px;height:100px"></iframe>`;
    await page.goto(`${s.site}/`, { waitUntil: 'load' });
    const frame = frameAt(page, '/frame');
    await (await frame.$('#b0')).click();

    await page.keyboard.press('ArrowUp');
    await settle();

    assert.deepEqual(await calls(page.mainFrame()), [['wsRemoteEdge', 'up']]);
    assert.deepEqual(await calls(frame), [], 'a frame never calls the bridge itself');
  } finally {
    await page.close();
    for (const server of s.all) server.close();
  }
});

test('a frame of a frame passes the arrow up through both', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const s = await servers();
  const page = await newPage();
  try {
    s.pages['/inner'] = BUTTONS;
    s.pages['/frame'] = `<iframe src="${s.site}/inner" style="border:0;width:280px;height:80px"></iframe>`;
    s.pages['/'] = `<iframe src="${s.other}/frame" style="border:0;width:300px;height:100px"></iframe>`;
    await page.goto(`${s.site}/`, { waitUntil: 'load' });
    await (await frameAt(page, '/inner').$('#b0')).click();

    await page.keyboard.press('ArrowLeft');
    await settle();

    assert.deepEqual(await calls(page.mainFrame()), [['wsRemoteEdge', 'left']]);
  } finally {
    await page.close();
    for (const server of s.all) server.close();
  }
});

test('only the frame holding focus can pass an arrow on', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const s = await servers();
  const page = await newPage();
  try {
    s.pages['/a'] = BUTTONS;
    s.pages['/b'] = BUTTONS;
    s.pages['/'] = `<iframe src="${s.other}/a"></iframe><iframe src="${s.other}/b"></iframe>`;
    await page.goto(`${s.site}/`, { waitUntil: 'load' });
    await (await frameAt(page, '/a').$('#b0')).click();

    await settle();
    await frameAt(page, '/b').evaluate(() => {
      window.parent.postMessage({ __wsRemoteEdge: { direction: 'up', since: Date.now() } }, '*');
    });
    await settle();

    assert.deepEqual(await calls(page.mainFrame()), [],
      'a frame the user is not in, an ad say, cannot move the app\'s focus');
  } finally {
    await page.close();
    for (const server of s.all) server.close();
  }
});

test('an arrow that scrolled the page around a frame was the page\'s', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const s = await servers();
  const page = await newPage();
  try {
    s.pages['/frame'] = BUTTONS;
    s.pages['/'] = `<iframe src="${s.other}/frame" style="border:0;width:300px;height:100px"></iframe>` +
      '<div style="height:3000px"></div>';
    await page.goto(`${s.site}/`, { waitUntil: 'load' });
    await (await frameAt(page, '/frame').$('#b0')).click();

    await page.keyboard.press('ArrowDown');
    await settle();

    const scrolled = await page.evaluate(() => window.scrollY);
    t.diagnostic(`the page scrolled to ${scrolled}`);
    assert.ok(scrolled > 0, 'Chromium scrolls the page when the frame cannot');
    assert.deepEqual(await calls(page.mainFrame()), []);
  } finally {
    await page.close();
    for (const server of s.all) server.close();
  }
});

test('an arrow that moved focus out of a frame onto the page was the page\'s', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const s = await servers();
  const page = await newPage();
  try {
    s.pages['/frame'] = BUTTONS;
    s.pages['/'] = '<button id="above">above</button><br>' +
      `<iframe src="${s.other}/frame" style="border:0;width:300px;height:100px"></iframe>`;
    await page.goto(`${s.site}/`, { waitUntil: 'load' });
    await (await frameAt(page, '/frame').$('#b0')).click();

    await page.keyboard.press('ArrowUp');
    await settle();

    assert.equal(await page.evaluate(() => document.activeElement.id), 'above');
    assert.deepEqual(await calls(page.mainFrame()), []);
  } finally {
    await page.close();
    for (const server of s.all) server.close();
  }
});
