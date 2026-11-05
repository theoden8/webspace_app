// jsdom tier for WebKit's sub-resource blocker and its stats observer
// (lib/js/block_js_interceptor.js and lib/js/block_resource_observer.js). Until they moved out of
// webview.dart neither ran in any test.
//
// The bridge is stubbed: `getBlockBloom` answers with a Bloom filter, and
// `blockCheckBatch` with one of the three verdicts the Dart handler can
// give per ask: false (allow), true (block), or a `data:` URL to load
// instead ($redirect=). Each ask is `{url, type, issued}`; what the page
// reports without asking goes to `blockRecordBatch`.

const test = require('node:test');
const assert = require('node:assert/strict');
const { makeDom, runInDom, pageJs } = require('./helpers/load_shim');

const INTERCEPTOR = pageJs('block_js_interceptor', { webKitReports: false });
const REPORTING = pageJs('block_js_interceptor', { webKitReports: true });
const OBSERVER = pageJs('block_resource_observer');

const REDIRECT = 'data:text/javascript;base64,KGZ1bmN0aW9uKCl7fSkoKTs=';
const VERDICTS = {
  'blocked.example': true,
  'redirect.example': REDIRECT,
};

// A Bloom filter that answers "maybe" for every host, so each request is
// the Dart handler's to decide.
const SATURATED = { bits64: Buffer.alloc(8, 255).toString('base64'), bitCount: 64, k: 1 };
// One that answers "no" for every host: the synchronous fast path.
const EMPTY = { bits64: Buffer.alloc(8, 0).toString('base64'), bitCount: 64, k: 1 };

const tick = () => new Promise((r) => setTimeout(r, 0));
// Past the interceptor's batching of what it reports without asking.
const reported = () => new Promise((r) => setTimeout(r, 300));

async function setup(bloom, { url, script = INTERCEPTOR } = {}) {
  const dom = makeDom({ url });
  const w = dom.window;
  const checks = [];
  const asks = [];
  const batches = [];
  const records = [];
  const fetched = [];
  w.fetch = function (input) {
    fetched.push(typeof input === 'string' ? input : input.url);
    return Promise.resolve('response');
  };
  w.flutter_inappwebview = {
    callHandler(name, arg) {
      if (name === 'getBlockBloom') return Promise.resolve(bloom);
      if (name === 'blockCheckBatch') {
        const urls = Array.from(arg, (a) => a.url);
        batches.push(urls);
        checks.push(...urls);
        asks.push(...JSON.parse(JSON.stringify(arg)));
        return Promise.resolve(urls.map((u) => VERDICTS[new URL(u).hostname] ?? false));
      }
      if (name === 'blockRecordBatch') records.push(...JSON.parse(JSON.stringify(arg)));
      return Promise.resolve(null);
    },
  };
  runInDom(dom, script);
  await tick();
  return { w, checks, asks, batches, records, fetched };
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

test('a redirect verdict fetches the stub body instead', async () => {
  const { w, fetched } = await setup(SATURATED);
  await w.fetch('https://redirect.example/ads.js');
  assert.deepEqual(fetched, [REDIRECT]);
});

test('a redirect verdict rewrites an image src', async () => {
  const { w } = await setup(SATURATED);
  const img = w.document.createElement('img');
  img.src = 'https://redirect.example/pixel.gif';
  assert.equal(img.getAttribute('src'), null,
    'the assignment waits for the verdict');
  await tick();
  assert.equal(img.getAttribute('src'), REDIRECT);
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

test('the checks one burst asks go to Dart as one call, answered in order', async () => {
  const { w, batches, fetched } = await setup(SATURATED);
  const srcs = ['https://allowed.example/1.png', 'https://blocked.example/2.png',
    'https://redirect.example/3.png', 'https://allowed.example/4.png'];
  const imgs = srcs.map((src) => {
    const img = w.document.createElement('img');
    img.src = src;
    return img;
  });
  const fetches = [w.fetch('https://allowed.example/a.js'),
    w.fetch('https://blocked.example/b.js').catch((e) => e.message)];
  await tick();
  assert.deepEqual(batches, [[...srcs, 'https://allowed.example/a.js',
    'https://blocked.example/b.js']]);
  assert.deepEqual(imgs.map((i) => i.getAttribute('src')),
    ['https://allowed.example/1.png', null, REDIRECT, 'https://allowed.example/4.png']);
  assert.equal((await fetches[1]).startsWith('Blocked'), true);
  assert.deepEqual(fetched, ['https://allowed.example/a.js']);
});

test('a burst the bridge refuses fails every request in it', async () => {
  const dom = makeDom();
  const w = dom.window;
  w.fetch = () => Promise.resolve('response');
  w.flutter_inappwebview = {
    callHandler(name) {
      if (name === 'getBlockBloom') return Promise.resolve(SATURATED);
      return Promise.reject(new Error('bridge gone'));
    },
  };
  runInDom(dom, INTERCEPTOR);
  await tick();
  const outcomes = await Promise.allSettled([
    w.fetch('https://a.example/1'), w.fetch('https://b.example/2')]);
  assert.deepEqual(outcomes.map((o) => o.status), ['rejected', 'rejected']);
});

test('a relative request is checked as the URL the page resolves it to (CB-003)', async () => {
  const { w, checks, fetched } = await setup(SATURATED, { url: 'https://blocked.example/search' });
  await assert.rejects(w.fetch('/rest/event/analytics'), (e) => /Blocked/.test(e.message));
  assert.deepEqual(checks, ['https://blocked.example/rest/event/analytics']);
  assert.deepEqual(fetched, []);
});

test('a URL object or a protocol-relative src is checked like its absolute form (CB-003)', async () => {
  const { w, checks, fetched } = await setup(SATURATED, { url: 'https://allowed.example/' });
  await assert.rejects(w.fetch(new w.URL('https://blocked.example/a.js')));
  const img = w.document.createElement('img');
  img.src = '//redirect.example/pixel.gif';
  await tick();
  assert.equal(img.getAttribute('src'), REDIRECT);
  assert.deepEqual(checks, ['https://blocked.example/a.js', 'https://redirect.example/pixel.gif']);
  assert.deepEqual(fetched, []);
});

test('an element inserted with a relative src is checked by the observer (CB-003)', async () => {
  const { w, checks } = await setup(SATURATED, { url: 'https://blocked.example/' });
  const div = w.document.createElement('div');
  div.innerHTML = '<img id="p" src="/pixel.gif">';
  w.document.body.appendChild(div);
  await tick();
  await tick();
  assert.equal(w.document.getElementById('p'), null);
  assert.deepEqual(checks, ['https://blocked.example/pixel.gif']);
});

test('a data: or blob: URL is never asked about', async () => {
  const { w, checks } = await setup(SATURATED, { url: 'https://blocked.example/' });
  const img = w.document.createElement('img');
  img.src = 'data:image/gif;base64,R0lGODlhAQABAAAAACw=';
  await w.fetch('blob:https://blocked.example/1234');
  assert.equal(img.getAttribute('src'), 'data:image/gif;base64,R0lGODlhAQABAAAAACw=');
  assert.deepEqual(checks, []);
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

test('the observer reports how many requests each host served, in one batch (CB-012)', async () => {
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
  assert.deepEqual(JSON.parse(JSON.stringify(batches)), [{ 'a.example': 2, 'b.example': 1 }],
    'one count per resource: blocks are counted per request too');
});

// A list that lands while the page is open reaches it. The page asked
// for the bloom when its document started; the app asks it to again.
// DNS-023
test('a reload of the bloom blocks what the old one let through', async () => {
  const dom = makeDom();
  const w = dom.window;
  let bloom = EMPTY;
  const fetched = [];
  w.fetch = function (input) {
    fetched.push(typeof input === 'string' ? input : input.url);
    return Promise.resolve('response');
  };
  w.flutter_inappwebview = {
    callHandler(name, arg) {
      if (name === 'getBlockBloom') return Promise.resolve(bloom);
      if (name === 'blockCheckBatch') {
        return Promise.resolve(arg.map((a) => VERDICTS[new URL(a.url).hostname] ?? false));
      }
      return Promise.resolve(null);
    },
  };
  runInDom(dom, INTERCEPTOR);
  await tick();
  await w.fetch('https://blocked.example/before.js');
  assert.deepEqual(fetched, ['https://blocked.example/before.js'],
    'the empty bloom is a hard allow, cached by host');

  bloom = SATURATED;
  w.__wsReloadBlockBloom();
  await tick();
  await assert.rejects(w.fetch('https://blocked.example/after.js'));
  assert.deepEqual(fetched, ['https://blocked.example/before.js'],
    'the host allowed under the old bloom must not stay allowed from cache');
});

test('each ask names its request type, and whether WebKit had issued it (CB-012)', async () => {
  const { w, asks } = await setup(SATURATED);
  // One host each: an allowed host's verdict is cached and asked once.
  const img = w.document.createElement('img');
  img.src = 'https://a1.example/1.png';
  await w.fetch('https://a2.example/a.json');
  const div = w.document.createElement('div');
  div.innerHTML = '<script src="https://a3.example/s.js"></script>'
    + '<link rel="stylesheet" href="https://a4.example/c.css">';
  w.document.body.appendChild(div);
  await tick();
  await tick();
  assert.deepEqual(asks, [
    { url: 'https://a1.example/1.png', type: 'image', issued: false },
    { url: 'https://a2.example/a.json', type: 'xhr', issued: false },
    { url: 'https://a3.example/s.js', type: 'script', issued: true },
    { url: 'https://a4.example/c.css', type: 'stylesheet', issued: true },
  ]);
});

test('a block the host cache answers is still reported, once per request (CB-012)', async () => {
  const { w, checks, records } = await setup(SATURATED);
  await assert.rejects(w.fetch('https://blocked.example/1.js'));
  await assert.rejects(w.fetch('https://blocked.example/2.js'));
  await assert.rejects(w.fetch('https://blocked.example/3.js'));
  await reported();
  assert.deepEqual(checks, ['https://blocked.example/1.js']);
  assert.deepEqual(records, [
    { url: 'https://blocked.example/2.js', type: 'xhr', issued: false, why: 'cached' },
    { url: 'https://blocked.example/3.js', type: 'xhr', issued: false, why: 'cached' },
  ]);
});

test('a load error the page never asked about is reported when the filter names its URL (CB-012)', async () => {
  const { w, records } = await setup(SATURATED);
  const img = w.document.createElement('img');
  w.document.body.appendChild(img);
  await tick();
  img.setAttribute('src', 'https://blocked.example/in-place.png');
  img.dispatchEvent(new w.Event('error'));
  const asked = w.document.createElement('img');
  asked.src = 'https://allowed.example/asked.png';
  await tick();
  asked.dispatchEvent(new w.Event('error'));
  await reported();
  assert.deepEqual(records, [
    { url: 'https://blocked.example/in-place.png', type: 'image', issued: true, why: 'failed' },
  ], 'a URL the page asked about is not reported again');
});

test('a load error that fires before the observer asks is left to the ask (CB-012)', async () => {
  const { w, asks, records } = await setup(SATURATED);
  const img = w.document.createElement('img');
  img.setAttribute('src', 'https://blocked.example/parsed.png');
  img.dispatchEvent(new w.Event('error'));
  w.document.body.appendChild(img);
  await tick();
  await reported();
  assert.equal(asks.length, 1, 'the observer asked about the element');
  assert.deepEqual(records, [], 'and the failure is not a second count');
});

test('a load error on a URL the Bloom filter does not name is a network failure, not reported', async () => {
  const { w, records } = await setup(EMPTY);
  const img = w.document.createElement('img');
  w.document.body.appendChild(img);
  img.setAttribute('src', 'https://allowed.example/gone.png');
  img.dispatchEvent(new w.Event('error'));
  await reported();
  assert.deepEqual(records, []);
});

test('where WebKit reports its blocks, load errors are left to it and its reports reach the app (CB-023)', async () => {
  const { w, records } = await setup(SATURATED, { script: REPORTING });
  const img = w.document.createElement('img');
  w.document.body.appendChild(img);
  img.setAttribute('src', 'https://blocked.example/in-place.png');
  img.dispatchEvent(new w.Event('error'));
  w.__wsWebKitBlocked(['https://blocked.example/beacon', 7]);
  await reported();
  assert.deepEqual(records, [
    { url: 'https://blocked.example/beacon', type: '', issued: true, why: 'webkit' },
  ]);
});

test('without WebKit reports, a report handed to the page is dropped (CB-023)', async () => {
  const { w, records } = await setup(SATURATED);
  w.__wsWebKitBlocked(['https://blocked.example/beacon']);
  await reported();
  assert.deepEqual(records, []);
});
