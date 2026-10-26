// jsdom tier for WebKit's sub-resource blocker and its stats observer
// (lib/js/block_js_interceptor.js and lib/js/block_resource_observer.js). Until they moved out of
// webview.dart neither ran in any test.
//
// The bridge is stubbed: `getBlockBloom` answers with a Bloom filter, and
// `blockCheck` with the three verdicts the Dart handler can give: false
// (allow), true (block), or a `data:` URL to load instead ($redirect=).

const test = require('node:test');
const assert = require('node:assert/strict');
const { makeDom, runInDom, pageJs } = require('./helpers/load_shim');

const INTERCEPTOR = pageJs('block_js_interceptor');
const OBSERVER = pageJs('block_resource_observer');

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

const byHost = (url) => VERDICTS[new URL(url).hostname] ?? false;

// A document at [url] whose `blockCheck` answers [verdict](url, origin): the
// Dart side judges a URL against the asking frame's origin. Every question
// lands in [checks].
async function setup(bloom, { url, verdict = byHost, checks = [] } = {}) {
  const dom = makeDom(url ? { url } : undefined);
  const w = dom.window;
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
        // A handler that throws rejects the page's promise, as the bridge does.
        return new Promise((resolve) => resolve(verdict(arg, w.location.origin)));
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

// CB-020: the verdict cache. A document keeps each answer under the URL it
// asked about, the one input to the verdict that varies within it.

test('a URL asked about once is answered without the bridge after', async () => {
  const { w, checks, fetched } = await setup(SATURATED);
  await assert.rejects(w.fetch('https://blocked.example/1.js'));
  await assert.rejects(w.fetch('https://blocked.example/1.js'));
  await w.fetch('https://allowed.example/a.js');
  await w.fetch('https://allowed.example/a.js');
  assert.deepEqual(checks, ['https://blocked.example/1.js', 'https://allowed.example/a.js']);
  assert.deepEqual(fetched, ['https://allowed.example/a.js', 'https://allowed.example/a.js']);

  const img = w.document.createElement('img');
  img.src = 'https://redirect.example/pixel.gif';
  await tick();
  const again = w.document.createElement('img');
  again.src = 'https://redirect.example/pixel.gif';
  assert.equal(again.getAttribute('src'), REDIRECT,
    'a known verdict, a redirect too, applies in the same task');
  assert.equal(checks.length, 3);
});

test('another URL on the same host is asked about anew', async () => {
  // `||paths.example/ads/`: one host, two answers.
  const verdict = (url) => url.includes('/ads/');
  for (const order of [['app.js', 'ads/x.js'], ['ads/x.js', 'app.js']]) {
    const { w, checks, fetched } = await setup(SATURATED, { verdict });
    for (const path of order) {
      await w.fetch(`https://paths.example/${path}`).catch(() => {});
    }
    assert.equal(checks.length, 2, `${order}: each URL is its own question`);
    assert.deepEqual(fetched, ['https://paths.example/app.js'], `${order}`);
  }
});

test('a request made while the same one is in flight waits on its answer', async () => {
  const { w, checks } = await setup(SATURATED);
  const box = w.document.createElement('div');
  for (let i = 0; i < 3; i++) {
    const img = w.document.createElement('img');
    img.setAttribute('src', 'https://blocked.example/sprite.png');
    box.appendChild(img);
  }
  w.document.body.appendChild(box);
  const fetches = [1, 2, 3].map(() => w.fetch('https://allowed.example/poll'));
  await Promise.all(fetches);
  await tick();
  assert.deepEqual(checks, ['https://allowed.example/poll', 'https://blocked.example/sprite.png']);
  assert.equal(box.querySelectorAll('img').length, 0, 'every copy is blocked');
});

test('another document asks for itself, whatever this one was told', async () => {
  // `||tracker.example^$domain=news.example`: the asking frame's origin is an
  // input, so a document never answers from another one's cache.
  const verdict = (url, origin) => origin === 'https://news.example';
  const checks = [];
  const news = await setup(SATURATED, { url: 'https://news.example/', verdict, checks });
  const blog = await setup(SATURATED, { url: 'https://blog.example/', verdict, checks });
  await assert.rejects(news.w.fetch('https://tracker.example/t.js'));
  await blog.w.fetch('https://tracker.example/t.js');
  assert.equal(checks.length, 2);
  assert.deepEqual(blog.fetched, ['https://tracker.example/t.js']);
});

test('the cache is bounded, and lets the oldest answer go first', async () => {
  const { w, checks } = await setup(SATURATED);
  const url = (i) => `https://allowed.example/r${i}`;
  for (let i = 0; i < 2000; i++) await w.fetch(url(i));
  await w.fetch(url(1999));
  assert.equal(checks.length, 2000, 'the newest answer is kept');
  await w.fetch(url(0));
  assert.equal(checks.length, 2001, 'the oldest is forgotten');
});

test('a failed question is asked again', async () => {
  let fail = true;
  const { w, checks } = await setup(SATURATED, {
    verdict: () => {
      if (!fail) return false;
      fail = false;
      throw new Error('handler threw');
    },
  });
  await assert.rejects(w.fetch('https://allowed.example/a.js'), /handler threw/);
  await w.fetch('https://allowed.example/a.js');
  assert.equal(checks.length, 2);
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
