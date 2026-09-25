// Behavioural tests for the icon-link watcher
// (lib/services/icon_link_watcher_shim.dart#buildIconLinkWatcherShim).
//
// The watcher tells the site-icon engine when the top document edits the
// icon set Blink announced at load (ICON-011). It mirrors Blink's scope:
// only `rel=icon` links that are direct children of <head>, only after the
// load event, only in the main frame. Whether Chrome re-requests icons on the
// same edits is pinned against a real engine in
// test/browser/icon_link_watcher_real.test.js.

const test = require('node:test');
const assert = require('node:assert/strict');
const { makeDom, readFixture, runInDom } = require('./helpers/load_shim');

const HANDLER = 'wsIconLinksChanged';

function boot(headHtml = '') {
  const dom = makeDom({
    url: 'https://example.com/',
    html: `<!doctype html><html><head>${headHtml}</head><body></body></html>`,
  });
  const calls = [];
  dom.window.flutter_inappwebview = {
    callHandler(name) {
      calls.push(name);
      return Promise.resolve();
    },
  };
  runInDom(dom, readFixture('icon_link_watcher/shim.js'));
  return { dom, calls };
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

test('swapping the announced icon for a badge reports once', async () => {
  const { dom, calls } = boot('<link rel="icon" href="/a.png">');
  await loaded(dom);
  const doc = dom.window.document;
  doc.querySelector('link').remove();
  doc.head.append(iconLink(doc, '/badge.png'));
  await tick();
  doc.head.append(iconLink(doc, '/badge2.png'));
  await tick();
  assert.deepEqual(calls, [HANDLER]);
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
