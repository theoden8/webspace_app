// Replication tests for the user-script shim's CSP-bypass bridge.
//
// The motivating bug: DarkReader works on iOS but degrades on Android as
// the page loads. Root cause: DarkReader's `injectProxy()` does
//
//   const proxy = document.createElement('script');
//   proxy.append('(proxyInjectorCode)()');
//   (document.head || document.documentElement).append(proxy);
//   proxy.remove();
//
// On Android Chromium WebView, that inline-script append fails the page
// CSP. The shim catches the script element before it reaches the live DOM
// and ships its source string through the privileged Dart bridge instead,
// where `controller.evaluateJavascript` bypasses page CSP on both engines.
//
// jsdom doesn't enforce CSP, so we can't replicate the *failure* here.
// What we can replicate is the *interception*: after running the shim,
// DarkReader's exact pattern must trigger a call to the inline-script
// handler, and the script element must never enter the live DOM. Those
// two facts together prove the bridge fires on the production code path.

const test = require('node:test');
const assert = require('node:assert');

const { makeDom, readFixture, runInDom } = require('./helpers/load_shim.js');

const SHIM = readFixture('user_script/shim.js');
const INLINE_HANDLER = '__ws_i_test';
const SRC_HANDLER = '__ws_s_test';
const FETCH_HANDLER = '__ws_f_test';

// Build a jsdom + install a callHandler stub before the shim runs, so
// the shim's lazy bridge capture finds it. Returns { dom, calls } where
// `calls` accumulates every callHandler invocation as [name, ...args].
function setup({ html } = {}) {
  const dom = makeDom({ url: 'https://linkedin.example/', html });
  const calls = [];
  // jsdom omits window.fetch. The shim's __wsFetch CORS-fallback layer
  // does `window.fetch.bind(window)` at install time, so we need *some*
  // function there. The body doesn't need to work; nothing in these
  // tests exercises the fetch fallback path.
  if (typeof dom.window.fetch !== 'function') {
    dom.window.fetch = function unusedFetchStub() {
      return Promise.reject(new Error('fetch stub not exercised'));
    };
  }
  dom.window.flutter_inappwebview = {
    callHandler(name, ...args) {
      calls.push([name, ...args]);
      // Return a thenable so the src-fetch branch (which awaits the
      // result) doesn't blow up. The inline branch doesn't await.
      return Promise.resolve(true);
    },
  };
  runInDom(dom, SHIM);
  return { dom, calls };
}

test('DarkReader injectProxy pattern is bridged through inline-script handler', () => {
  const { dom, calls } = setup();
  const { document } = dom.window;

  // Verbatim copy of DarkReader's injectProxy logic.
  const proxy = document.createElement('script');
  const proxyCode = '(function(){window.__darkReaderProxyInstalled=true;})()';
  proxy.append(proxyCode);
  (document.head || document.documentElement).append(proxy);
  proxy.remove();

  const inlineCalls = calls.filter(c => c[0] === INLINE_HANDLER);
  assert.strictEqual(inlineCalls.length, 1,
    'expected exactly one inline-script bridge call, got ' + inlineCalls.length);
  assert.strictEqual(inlineCalls[0][1], proxyCode,
    'bridged source must match the proxy code DarkReader assembled');

  // The script element must NOT have ended up in the live DOM. If it had,
  // a real browser's CSP would have run (and blocked) it.
  assert.strictEqual(document.head.querySelector('script'), null,
    'inline script must not enter the live DOM — bridge handles execution');
});

test('inline script via appendChild is bridged too', () => {
  const { dom, calls } = setup();
  const { document } = dom.window;
  const s = document.createElement('script');
  s.textContent = 'window.__viaAppendChild = true;';
  document.head.appendChild(s);

  const inlineCalls = calls.filter(c => c[0] === INLINE_HANDLER);
  assert.strictEqual(inlineCalls.length, 1);
  assert.strictEqual(inlineCalls[0][1], 'window.__viaAppendChild = true;');
  assert.strictEqual(s.parentNode, null,
    'native append must be skipped — element stays unattached');
});

test('inline script via insertBefore is bridged too', () => {
  const { dom, calls } = setup();
  const { document } = dom.window;
  // Need an existing reference child so insertBefore has a valid sibling.
  const ref = document.createElement('meta');
  document.head.appendChild(ref);

  const s = document.createElement('script');
  s.text = 'window.__viaInsertBefore = true;';
  document.head.insertBefore(s, ref);

  const inlineCalls = calls.filter(c => c[0] === INLINE_HANDLER);
  assert.strictEqual(inlineCalls.length, 1);
  assert.strictEqual(inlineCalls[0][1], 'window.__viaInsertBefore = true;');
});

test('script with empty content is NOT bridged (no source to evaluate)', () => {
  const { dom, calls } = setup();
  const { document } = dom.window;
  const s = document.createElement('script');
  // No textContent, no src — nothing to evaluate.
  document.head.appendChild(s);

  const inlineCalls = calls.filter(c => c[0] === INLINE_HANDLER);
  assert.strictEqual(inlineCalls.length, 0);
});

test('whitelisted <script src> still routes through the src handler', () => {
  const { dom, calls } = setup();
  const { document } = dom.window;
  const s = document.createElement('script');
  s.src = 'https://cdn.jsdelivr.net/npm/darkreader/darkreader.min.js';
  document.head.appendChild(s);

  const srcCalls = calls.filter(c => c[0] === SRC_HANDLER);
  const inlineCalls = calls.filter(c => c[0] === INLINE_HANDLER);
  assert.strictEqual(srcCalls.length, 1, 'src-script must use the src handler');
  assert.strictEqual(srcCalls[0][1], s.src);
  assert.strictEqual(inlineCalls.length, 0,
    'src-script must not be misrouted through the inline handler');
});

test('non-whitelisted <script src> from the page is NOT intercepted', () => {
  // Page-authored remote scripts must keep their native CSP-governed path
  // — only whitelisted CDN URLs go through the bridge.
  const { dom, calls } = setup();
  const { document } = dom.window;
  const s = document.createElement('script');
  s.src = 'https://platform.linkedin.com/some-tracker.js';
  document.head.appendChild(s);

  const srcCalls = calls.filter(c => c[0] === SRC_HANDLER);
  assert.strictEqual(srcCalls.length, 0,
    'non-whitelisted src must fall through to native (CSP-governed) append');
  // The script element should be in the DOM, on the native path.
  assert.strictEqual(s.parentNode, dom.window.document.head);
});

test('Element.prototype.append passes non-script args through to native', () => {
  // The shim's append() wrapper iterates variadic args and only diverts
  // <script> elements. Strings and other elements must reach the page DOM.
  const { dom } = setup();
  const { document } = dom.window;
  const div = document.createElement('div');
  document.body.append(div, 'tail-text');
  assert.strictEqual(div.parentNode, document.body);
  assert.strictEqual(document.body.lastChild.textContent, 'tail-text');
});

test('shim is idempotent — running it twice does not double-wrap', () => {
  // The guard `if (window.__wsFetchShimInstalled) return;` matters because
  // the shim re-runs at onLoadStart in production. A double-wrap would
  // intercept twice per append.
  const { dom, calls } = setup();
  runInDom(dom, SHIM);

  const { document } = dom.window;
  const s = document.createElement('script');
  s.textContent = 'noop;';
  document.head.appendChild(s);

  const inlineCalls = calls.filter(c => c[0] === INLINE_HANDLER);
  assert.strictEqual(inlineCalls.length, 1,
    're-installation must be a no-op, not a double-intercept');
});

// ── window.fetch CORS-fallback layer ──
//
// The shim patches window.fetch to retry TypeError failures through
// __wsFetch (the Dart bridge). That bridge carries none of the WebView's
// cookies or request headers, so retrying a *session-bound* request there
// silently drops the user's session (a logged-in github.com starts
// demanding login; LinkedIn's messaging endpoints on same-site subdomains
// see an unauthenticated client). The fallback must be scoped to
// cross-SITE (different registrable domain) bodyless, non-credentialed
// requests only — see BUG-004.
//
// The rejection must be a jsdom-realm TypeError: the shim runs via
// window.eval, so its `err instanceof TypeError` checks the jsdom TypeError,
// not Node's.
function setupFetch({ url = 'https://site.example/', rejectWith } = {}) {
  const dom = makeDom({ url });
  const calls = [];
  const err = rejectWith === undefined
    ? new dom.window.TypeError('Failed to fetch')
    : rejectWith;
  dom.window.fetch = function stubFetch() {
    return Promise.reject(err);
  };
  dom.window.flutter_inappwebview = {
    callHandler(name, ...args) {
      calls.push([name, ...args]);
      return Promise.resolve({ status: 200, body: 'ok', contentType: 'text/plain' });
    },
  };
  // __wsFetch builds `new Response(...)`; jsdom may omit it.
  if (typeof dom.window.Response !== 'function') {
    dom.window.Response = function Response(body, init) {
      this.body = body;
      this.status = (init && init.status) || 200;
    };
  }
  runInDom(dom, SHIM);
  return { dom, calls, err };
}

test('same-origin fetch TypeError is NOT retried through the cookie-less bridge', async () => {
  const { dom, calls, err } = setupFetch({ url: 'https://github.example/' });
  await assert.rejects(
    dom.window.fetch('https://github.example/session/check'),
    (e) => e === err,
    'same-origin failure must propagate unchanged, not fall back');
  assert.strictEqual(calls.filter(c => c[0] === FETCH_HANDLER).length, 0,
    'same-origin request must never hit __wsFetch — it would drop the session cookie');
});

test('relative-URL fetch TypeError stays same-origin (no bridge fallback)', async () => {
  const { dom, calls } = setupFetch({ url: 'https://github.example/' });
  await assert.rejects(dom.window.fetch('/notifications/indicator'));
  assert.strictEqual(calls.filter(c => c[0] === FETCH_HANDLER).length, 0,
    'a relative URL resolves same-origin and must not fall back');
});

test('cross-site fetch TypeError DOES fall back to __wsFetch', async () => {
  const { dom, calls } = setupFetch({ url: 'https://github.example/' });
  try { await dom.window.fetch('https://cdn.other.example/lib.css'); } catch (_) { /* Response shape irrelevant */ }
  const fetchCalls = calls.filter(c => c[0] === FETCH_HANDLER);
  assert.strictEqual(fetchCalls.length, 1,
    'a genuine cross-site CORS failure should still use the bridge fallback');
  assert.strictEqual(fetchCalls[0][1], 'https://cdn.other.example/lib.css');
});

test('same-site cross-origin subdomain is NOT retried through the cookie-less bridge', async () => {
  // Cookies scope to the registrable domain, so a subdomain request is as
  // session-bound as a same-origin one. LinkedIn messaging talks to
  // realtime.www.linkedin.com from www.linkedin.com — retrying it through
  // the bridge makes LinkedIn see a logged-out client (BUG-004).
  const { dom, calls, err } = setupFetch({ url: 'https://www.linkedin.example/' });
  await assert.rejects(
    dom.window.fetch('https://realtime.www.linkedin.example/realtime/connect'),
    (e) => e === err,
    'same-site failure must propagate unchanged, not fall back');
  assert.strictEqual(calls.filter(c => c[0] === FETCH_HANDLER).length, 0,
    'same-site request must never hit __wsFetch — it would look unauthenticated');
});

test('cross-site POST is NOT retried (bridge would silently convert it to GET)', async () => {
  const { dom, calls, err } = setupFetch({ url: 'https://github.example/' });
  await assert.rejects(
    dom.window.fetch('https://api.other.example/submit', { method: 'POST', body: 'x' }),
    (e) => e === err);
  assert.strictEqual(calls.filter(c => c[0] === FETCH_HANDLER).length, 0,
    'a POST must never be reissued as a cookie-less GET');
});

test('cross-site credentials:include is NOT retried (explicitly session-bound)', async () => {
  const { dom, calls, err } = setupFetch({ url: 'https://github.example/' });
  await assert.rejects(
    dom.window.fetch('https://sso.other.example/session', { credentials: 'include' }),
    (e) => e === err);
  assert.strictEqual(calls.filter(c => c[0] === FETCH_HANDLER).length, 0,
    'credentialed requests must never be reissued through the cookie-less bridge');
});

test('non-TypeError fetch rejection is never intercepted', async () => {
  // Application errors (e.g. an abort) must propagate untouched, even
  // cross-origin — only a TypeError signals a CORS/network failure.
  const abort = new Error('aborted');
  const { dom, calls } = setupFetch({ url: 'https://github.example/', rejectWith: abort });
  await assert.rejects(dom.window.fetch('https://cdn.other.example/x'), (e) => e === abort);
  assert.strictEqual(calls.filter(c => c[0] === FETCH_HANDLER).length, 0,
    'non-TypeError rejections are not CORS failures and must not fall back');
});

// ── window.__wsFetch direct usage (setFetchMethod pattern) ──

test('__wsFetch rejects non-http(s) URLs', async () => {
  const { dom } = setup();
  await assert.rejects(dom.window.__wsFetch('ftp://example/x'), /only http\/https/);
});

test('__wsFetch rejects when the Dart bridge is unavailable', async () => {
  const dom = makeDom({ url: 'https://site.example/' });
  dom.window.fetch = () => Promise.reject(new dom.window.TypeError('x'));
  // No flutter_inappwebview bridge installed.
  runInDom(dom, SHIM);
  await assert.rejects(dom.window.__wsFetch('https://cdn.example/x'), /bridge not available/);
});

// ── whitelisted <script src> load lifecycle (dedup / onload / onerror) ──

test('whitelisted src is fetched once; a repeat append dedupes and still fires onload', async () => {
  const { dom, calls } = setup();
  const { document } = dom.window;
  const url = 'https://cdn.jsdelivr.net/npm/x/x.js';
  const s1 = document.createElement('script');
  s1.src = url;
  document.head.appendChild(s1);
  await new Promise(r => setTimeout(r, 0));   // let the handler resolve (ok) and mark _loadedUrls

  const s2 = document.createElement('script');
  s2.src = url;
  let onloadFired = false;
  s2.onload = () => { onloadFired = true; };
  document.head.appendChild(s2);
  await new Promise(r => setTimeout(r, 0));

  assert.strictEqual(calls.filter(c => c[0] === SRC_HANDLER).length, 1,
    'the second append of an already-loaded URL must not re-fetch');
  assert.ok(onloadFired, 'the dedup path must still fire onload for the caller');
});

// ── FileReader polyfill (WKWebView missing-constructor mitigation) ──
//
// iOS WKWebView has been observed to throw "ReferenceError: Can't find
// variable: FileReader" from page-context code — DarkReader hits it in
// readResponseAsDataURL for every image it inlines after fetching it
// through __wsFetch. The shim installs a minimal FileReader only when
// the native one is absent.

function setupNoFileReader() {
  const dom = makeDom({ url: 'https://linkedin.example/' });
  dom.window.fetch = () => Promise.reject(new dom.window.TypeError('x'));
  delete dom.window.FileReader;
  runInDom(dom, SHIM);
  return dom;
}

test('native FileReader is left untouched when present', () => {
  const dom = makeDom({ url: 'https://linkedin.example/' });
  dom.window.fetch = () => Promise.reject(new dom.window.TypeError('x'));
  const native = dom.window.FileReader;
  assert.strictEqual(typeof native, 'function', 'jsdom provides FileReader');
  runInDom(dom, SHIM);
  assert.strictEqual(dom.window.FileReader, native,
    'polyfill must not clobber a working native FileReader');
});

test('polyfill installs when FileReader is absent; readAsDataURL round-trips', async () => {
  const dom = setupNoFileReader();
  assert.strictEqual(typeof dom.window.FileReader, 'function');

  const bytes = Uint8Array.from([0x48, 0x69, 0x21]); // "Hi!"
  // Only the Blob surface the polyfill consumes: type + arrayBuffer().
  const blob = { type: 'image/png', arrayBuffer: () => Promise.resolve(bytes.buffer) };
  const reader = new dom.window.FileReader();
  const result = await new Promise((resolve) => {
    // DarkReader's exact usage: onloadend + .result.
    reader.onloadend = () => resolve(reader.result);
    reader.readAsDataURL(blob);
  });
  assert.strictEqual(result,
    'data:image/png;base64,' + Buffer.from(bytes).toString('base64'));
  assert.strictEqual(reader.readyState, 2, 'DONE after read');
  assert.strictEqual(reader.error, null);
});

test('polyfill readAsDataURL falls back to octet-stream for untyped blobs', async () => {
  const dom = setupNoFileReader();
  const blob = { type: '', arrayBuffer: () => Promise.resolve(new Uint8Array([1]).buffer) };
  const reader = new dom.window.FileReader();
  const result = await new Promise((resolve) => {
    reader.onloadend = () => resolve(reader.result);
    reader.readAsDataURL(blob);
  });
  assert.ok(result.startsWith('data:application/octet-stream;base64,'));
});

test('polyfill readAsText resolves blob text', async () => {
  const dom = setupNoFileReader();
  const blob = { type: 'text/css', text: () => Promise.resolve('body{}') };
  const reader = new dom.window.FileReader();
  const result = await new Promise((resolve) => {
    reader.onload = () => resolve(reader.result);
    reader.readAsText(blob);
  });
  assert.strictEqual(result, 'body{}');
});

test('polyfill surfaces read failure via onerror and error', async () => {
  const dom = setupNoFileReader();
  const boom = new Error('read failed');
  const blob = { type: 'image/png', arrayBuffer: () => Promise.reject(boom) };
  const reader = new dom.window.FileReader();
  let onerrorFired = false;
  reader.onerror = () => { onerrorFired = true; };
  await new Promise((resolve) => {
    reader.onloadend = resolve;
    reader.readAsDataURL(blob);
  });
  assert.ok(onerrorFired, 'onerror must fire on a failed read');
  assert.strictEqual(reader.error, boom);
  assert.strictEqual(reader.result, null);
});

test('whitelisted src whose bridge fetch fails fires onerror', async () => {
  const dom = makeDom({ url: 'https://linkedin.example/' });
  dom.window.fetch = () => Promise.reject(new dom.window.TypeError('x'));
  dom.window.flutter_inappwebview = { callHandler: () => Promise.resolve(false) };
  runInDom(dom, SHIM);
  const { document } = dom.window;
  const s = document.createElement('script');
  s.src = 'https://cdn.jsdelivr.net/npm/x/x.js';
  let errFired = false;
  s.onerror = () => { errFired = true; };
  document.head.appendChild(s);
  await new Promise(r => setTimeout(r, 0));
  assert.ok(errFired, 'a failed (ok=false) bridge fetch must fire onerror');
});
