// Structural gate: every WebView built with a proxy is recorded (PROXY-029).
//
// The fork keeps a container's proxy for the rest of the process once a
// WebView is built on it naming one, and a WebView built naming none leaves
// it in force. The app clears it through `ProxyController` only for the
// containers `ProxyManager.containerProxies` knows about, and it learns of
// them from `noteStoreProxy`. A new builder that hands `proxySettings` to
// `InAppWebViewSettings` without recording it gives a container a proxy the
// app can no longer take off: its site moves to DEFAULT and keeps loading
// through the old proxy.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, dartFiles, code, callArgs } = require('./helpers/source');

const builds = [];
for (const rel of dartFiles()) {
  const text = code(read(rel));
  const re = /InAppWebViewSettings\s*\(/g;
  let m;
  while ((m = re.exec(text)) !== null) {
    const args = callArgs(text, m.index, rel);
    const proxy = args && /\bproxySettings:\s*([^,\n]+)/.exec(args);
    if (proxy) builds.push({ rel, text, value: proxy[1].trim() });
  }
}

test('the gate sees the builders it guards', () => {
  const where = builds.map((b) => b.rel);
  assert.ok(
    where.includes('lib/services/webview.dart'),
    'the builder the site and popup webviews share passes proxySettings; if '
      + 'it stopped, update this gate rather than letting it pass on nothing',
  );
  assert.ok(where.includes('lib/services/proxy_router_probe.dart'));
});

// The site and popup builders share `_siteSettings`, which is handed the
// binding: each caller records the proxy it hands over.
test('every caller of the shared builder records its proxy', () => {
  const webview = read('lib/services/webview.dart');
  const calls = [...webview.matchAll(/_siteSettings\(\s*binding,/g)];
  assert.ok(calls.length >= 2, 'expected the site and popup webviews to share the builder');
  for (const call of calls) {
    const fn = webview.lastIndexOf('\n  static ', call.index);
    assert.match(webview.slice(fn, call.index),
      /ProxyManager\.noteStoreProxy\(\s*(binding\.)?containerId,\s*proxy:\s*(binding\.proxy|inappProxy)\)/,
      'a webview built through _siteSettings must record its container proxy '
        + '(PROXY-029)');
  }
});

test('every proxySettings handed to a WebView is recorded', () => {
  for (const b of builds) {
    const noted = new RegExp(
      `noteStoreProxy\\([^,]+,\\s*proxy:\\s*${b.value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\)`,
    );
    assert.match(
      b.text,
      noted,
      `${b.rel} builds a WebView with proxySettings: ${b.value} but never `
        + `calls ProxyManager.noteStoreProxy(containerId, ${b.value}). `
        + 'Without it a site moved off that proxy keeps it (PROXY-029).',
    );
  }
});
