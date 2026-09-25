// Behavioural tests for the icon-link watcher
// (lib/services/icon_link_watcher_shim.dart#buildIconLinkWatcherShim).
//
// The watcher tells the site-icon engine when the top document's load event
// fires (ICON-012), which icon links it announced (ICON-013), and when the
// page edits that set afterwards (ICON-011). It mirrors Blink's scope: only
// `rel=icon` links that are direct children of <head>, only after the load
// event, only in the main frame. Whether Chrome requests icons on the same
// edits, and after the load report, is pinned against a real engine in
// test/browser/icon_link_watcher_real.test.js.

const test = require('node:test');
const assert = require('node:assert/strict');
const { makeDom, readFixture, runInDom } = require('./helpers/load_shim');

const HANDLER = 'wsIconLinksChanged';
const LOADED = 'wsIconDocumentLoaded';
const LINKS = 'wsIconLinks';

function boot(headHtml = '', { matchMedia } = {}) {
  const dom = makeDom({
    url: 'https://example.com/',
    html: `<!doctype html><html><head>${headHtml}</head><body></body></html>`,
  });
  if (matchMedia) dom.window.matchMedia = matchMedia;
  const all = [];
  const calls = [];
  dom.window.flutter_inappwebview = {
    callHandler(name, ...args) {
      // The real bridge JSON-encodes the arguments, which also brings them
      // out of the jsdom realm for deepEqual.
      all.push({ name, args: JSON.parse(JSON.stringify(args)) });
      if (name === HANDLER) calls.push(name);
      return Promise.resolve();
    },
  };
  runInDom(dom, readFixture('icon_link_watcher/shim.js'));
  // `calls` holds the change reports, which most tests are about.
  return { dom, all, calls };
}

function loaded(dom) {
  return new Promise((resolve) => {
    const settle = () => setTimeout(resolve, 10);
    if (dom.window.document.readyState === 'complete') settle();
    else dom.window.addEventListener('load', settle, { once: true });
  });
}

const tick = () => new Promise((r) => setTimeout(r, 10));

function iconLink(doc, href, extra = {}) {
  const link = doc.createElement('link');
  link.rel = extra.rel || 'icon';
  link.href = href;
  if (extra.sizes) link.setAttribute('sizes', extra.sizes);
  return link;
}

test('reports the load from inside the load event, ahead of the page',
  async () => {
    const w = boot('<link rel="icon" href="/a.png">');
    let seenByPage = null;
    w.dom.window.addEventListener('load', () => {
      seenByPage = w.all.map((c) => c.name);
    });
    await loaded(w.dom);
    assert.deepEqual(seenByPage, [LOADED]);
    assert.deepEqual(w.all.map((c) => c.name), [LOADED, LINKS]);
    assert.deepEqual(w.all[0].args, []);
  });

test('reports the announced links once, resolved', async () => {
  const w = boot(
    '<link rel="icon" href="/32.png" sizes="32x32" type="image/png">' +
    '<link rel="shortcut icon" href="https://cdn.example.net/f.ico">' +
    '<link rel="apple-touch-icon" href="/touch.png">');
  await loaded(w.dom);
  const reports = w.all.filter((c) => c.name === LINKS);
  assert.equal(reports.length, 1);
  assert.deepEqual(reports[0].args, [[
    { href: 'https://example.com/32.png', sizes: '32x32', type: 'image/png' },
    { href: 'https://cdn.example.net/f.ico', sizes: '', type: '' },
  ]]);
});

test('links whose media does not match are not announced', async () => {
  const w = boot(
    '<link rel="icon" href="/light.png" media="(prefers-color-scheme: light)">' +
    '<link rel="icon" href="/dark.png" media="(prefers-color-scheme: dark)">',
    { matchMedia: (q) => ({ matches: q.includes('light') }) });
  await loaded(w.dom);
  const report = w.all.find((c) => c.name === LINKS);
  assert.deepEqual(report.args[0].map((l) => l.href),
    ['https://example.com/light.png']);
});

test('icons a page load handler adds are announced, not reported as a change',
  async () => {
    const w = boot('');
    w.dom.window.addEventListener('load', () => {
      const doc = w.dom.window.document;
      doc.head.append(iconLink(doc, '/late.png'));
    });
    await loaded(w.dom);
    await tick();
    const report = w.all.find((c) => c.name === LINKS);
    assert.deepEqual(report.args[0].map((l) => l.href),
      ['https://example.com/late.png']);
    assert.deepEqual(w.calls, []);
  });

test('a page with no icon links reports an empty set', async () => {
  const w = boot('');
  await loaded(w.dom);
  const report = w.all.find((c) => c.name === LINKS);
  assert.deepEqual(report.args, [[]]);
});

test('swapping the announced icon for a badge reports once', async () => {
  const w = boot('<link rel="icon" href="/a.png">');
  const { dom } = w;
  await loaded(dom);
  const doc = dom.window.document;
  doc.querySelector('link').remove();
  doc.head.append(iconLink(doc, '/badge.png'));
  await tick();
  doc.head.append(iconLink(doc, '/badge2.png'));
  await tick();
  assert.deepEqual(w.calls, [HANDLER]);
  assert.equal(w.all.filter((c) => c.name === LINKS).length, 1,
    'a change does not re-announce the links');
});

test('editing the href of an announced icon reports', async () => {
  const { dom, calls } = boot('<link rel="shortcut icon" href="/a.png">');
  await loaded(dom);
  dom.window.document.querySelector('link').href = '/a-unread.png';
  await tick();
  assert.deepEqual(calls, [HANDLER]);
});

test('the first icon a page adds after load is not a change', async () => {
  const { dom, calls } = boot('');
  await loaded(dom);
  const doc = dom.window.document;
  doc.head.append(iconLink(doc, '/app.png'));
  await tick();
  assert.deepEqual(calls, []);
  doc.head.querySelector('link').href = '/app-badge.png';
  await tick();
  assert.deepEqual(calls, [HANDLER]);
});

test('edits before the load event finishes are part of the announced set',
  async () => {
    const { dom, calls } = boot('<link rel="icon" href="/a.png">');
    const doc = dom.window.document;
    doc.querySelector('link').href = '/b.png';
    await loaded(dom);
    await tick();
    assert.deepEqual(calls, []);
  });

test('non-icon links and icons outside <head> are ignored', async () => {
  const { dom, calls } = boot('<link rel="icon" href="/a.png">');
  await loaded(dom);
  const doc = dom.window.document;
  const css = doc.createElement('link');
  css.rel = 'stylesheet';
  css.href = '/x.css';
  doc.head.append(css);
  doc.head.append(iconLink(doc, '/touch.png', { rel: 'apple-touch-icon' }));
  doc.body.append(iconLink(doc, '/body.png'));
  const wrapper = doc.createElement('div');
  doc.head.append(wrapper);
  wrapper.append(iconLink(doc, '/nested.png'));
  await tick();
  assert.deepEqual(calls, []);
});

test('a change to sizes or media is a change', async () => {
  const { dom, calls } = boot('<link rel="icon" href="/a.png" sizes="32x32">');
  await loaded(dom);
  dom.window.document.querySelector('link').setAttribute('sizes', '64x64');
  await tick();
  assert.deepEqual(calls, [HANDLER]);
});

test('defines no globals', async () => {
  const before = makeDom();
  const baseline = new Set(Object.getOwnPropertyNames(before.window));
  const { dom } = boot('<link rel="icon" href="/a.png">');
  await loaded(dom);
  const added = Object.getOwnPropertyNames(dom.window)
    .filter((k) => !baseline.has(k) && k !== 'flutter_inappwebview');
  assert.deepEqual(added, []);
});
