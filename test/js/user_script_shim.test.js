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
