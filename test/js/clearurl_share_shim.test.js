// jsdom tier for the ClearURLs copy/share shim
// (lib/services/clearurl_share_shim.dart, dumped to
// test/js_fixtures/clearurl_share/shim.js).

const test = require('node:test');
const assert = require('node:assert/strict');
const { makeDom, runInDom, readFixture } = require('./helpers/load_shim');

const SHIM = readFixture('clearurl_share/shim.js');
const CLEAN = 'https://shop.example/item';

function setup() {
  const dom = makeDom();
  const w = dom.window;
  const written = [];
  const shared = [];
  Object.defineProperty(w.navigator, 'clipboard', {
    value: { writeText: (t) => { written.push(t); return Promise.resolve(); } },
    configurable: true,
  });
  w.navigator.share = (data) => { shared.push(data); return Promise.resolve(); };
  w.document.execCommand = () => true;
  w.flutter_inappwebview = {
    callHandler: (name, url) =>
      Promise.resolve(name === 'clearUrl' && url.startsWith(CLEAN) ? CLEAN : url),
  };
  runInDom(dom, SHIM);
  return { w, written, shared };
}

test('a copied URL is cleaned before it reaches the clipboard', async () => {
  const { w, written } = setup();
  await w.navigator.clipboard.writeText(`${CLEAN}?utm_source=x`);
  assert.deepEqual(written, [CLEAN]);
});

test('text that is not a URL is copied as is', async () => {
  const { w, written } = setup();
  await w.navigator.clipboard.writeText('hello');
  assert.deepEqual(written, ['hello']);
});

test('a shared URL and a URL shared as text are both cleaned', async () => {
  const { w, shared } = setup();
  await w.navigator.share({ url: `${CLEAN}?fbclid=1`, text: `${CLEAN}?gclid=2` });
  assert.equal(shared[0].url, CLEAN);
  assert.equal(shared[0].text, CLEAN);
});
