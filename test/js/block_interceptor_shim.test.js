// jsdom tier for WebKit's sub-resource blocker and its stats observer
// (lib/services/block_interceptor_shim.dart, dumped to
// test/js_fixtures/block_interceptor/). Until they moved out of
// webview.dart neither ran in any test.
//
// The bridge is stubbed: `getBlockBloom` answers with a Bloom filter, and
// `blockCheck` with the three verdicts the Dart handler can give: false
// (allow), true (block), or a `data:` URL to load instead ($redirect=).

const test = require('node:test');
const assert = require('node:assert/strict');
const { makeDom, runInDom, readFixture } = require('./helpers/load_shim');

const INTERCEPTOR = readFixture('block_interceptor/interceptor.js');
const OBSERVER = readFixture('block_interceptor/observer.js');

const REDIRECT = 'data:text/javascript;base64,KGZ1bmN0aW9uKCl7fSkoKTs=';
const VERDICTS = {
  'blocked.example': true,
  'redirect.example': REDIRECT,
};

// A Bloom filter that answers "maybe" for every host, so each request is
// the Dart handler's to decide.
const SATURATED = { bits: new Array(8).fill(255), bitCount: 64, k: 1 };
// One that answers "no" for every host: the synchronous fast path.
const EMPTY = { bits: new Array(8).fill(0), bitCount: 64, k: 1 };

const tick = () => new Promise((r) => setTimeout(r, 0));

async function setup(bloom) {
  const dom = makeDom();
  const w = dom.window;
  const checks = [];
  const fetched = [];
  w.fetch = function (input) {
    fetched.push(typeof input === 'string' ? input : input.url);
    return Promise.resolve('response');
  };
  w.flutter_inappwebview = {
    callHandler(name, arg) {
      if (name === 'getBlockBloom') return Promise.resolve(bloom);
      if (name === 'blockCheck') {
        checks.push(arg);
        return Promise.resolve(VERDICTS[new URL(arg).hostname] ?? false);
      }
      return Promise.resolve(null);
    },
  };
  runInDom(dom, INTERCEPTOR);
  await tick();
  return { w, checks, fetched };
}

test('an allowed fetch goes out unchanged', async () => {
  const { w, fetched } = await setup(SATURATED);
  assert.equal(await w.fetch('https://allowed.example/a.js'), 'response');
  assert.deepEqual(fetched, ['https://allowed.example/a.js']);
});

test('a blocked fetch rejects and never goes out', async () => {
  const { w, fetched } = await setup(SATURATED);
  await assert.rejects(w.fetch('https://blocked.example/t.js'),
    (e) => e.name === 'TypeError' && /Blocked/.test(e.message));
  assert.deepEqual(fetched, []);
});

test('a blocked image src is never assigned', async () => {
  const { w } = await setup(SATURATED);
  const img = w.document.createElement('img');
  img.src = 'https://blocked.example/pixel.gif';
  await tick();
  assert.equal(img.getAttribute('src'), null);
});

test('a host the decision cached is answered without the bridge', async () => {
  const { w, checks } = await setup(SATURATED);
  await assert.rejects(w.fetch('https://blocked.example/1.js'));
  await assert.rejects(w.fetch('https://blocked.example/2.js'));
  assert.equal(checks.length, 1, 'host-level verdicts are cached by host');
});

test('a Bloom miss is allowed synchronously, without the bridge', async () => {
  const { w, checks, fetched } = await setup(EMPTY);
  const img = w.document.createElement('img');
  img.src = 'https://blocked.example/pixel.gif';
  assert.equal(img.getAttribute('src'), 'https://blocked.example/pixel.gif');
  await w.fetch('https://blocked.example/a.js');
  assert.deepEqual(fetched, ['https://blocked.example/a.js']);
  assert.deepEqual(checks, []);
});

test('the observer reports each host once, in one batch', async () => {
  const dom = makeDom();
  const w = dom.window;
  const batches = [];
  let observe;
  w.PerformanceObserver = class {
    constructor(cb) { observe = cb; }
    observe() {}
  };
  w.flutter_inappwebview = {
    callHandler(name, hosts) {
      if (name === 'blockResourceLoadedBatch') batches.push(hosts);
      return Promise.resolve(null);
    },
  };
  runInDom(dom, OBSERVER);
  const entries = ['https://a.example/1', 'https://b.example/2',
    'https://a.example/3', 'data:image/gif;base64,R0lGOD'];
  observe({ getEntries: () => entries.map((name) => ({ name })) });
  await new Promise((r) => setTimeout(r, 300));
  assert.deepEqual(JSON.parse(JSON.stringify(batches)), [['a.example', 'b.example']]);
});
