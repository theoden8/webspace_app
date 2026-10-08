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

// The site, popup and headless builders share `WebViewFactory.siteSettings`,
// which is handed the binding: each caller records the proxy it hands over.
const shared = dartFiles().flatMap((rel) => {
  const text = read(rel);
  return [...text.matchAll(/\bsiteSettings\(\s*binding,/g)].map((m) => ({ rel, text, at: m.index }));
});

test('every caller of the shared builder records its proxy', () => {
  assert.ok(shared.length >= 3,
    'expected the site, popup and headless webviews to share the builder');
  for (const { rel, text, at } of shared) {
    const fn = text.lastIndexOf('\n  static ', at);
    assert.match(text.slice(fn, at),
      /ProxyManager\.noteStoreProxy\(\s*(binding\.)?containerId,\s*proxy:\s*(binding\.proxy|inappProxy)\)/,
      `${rel}: a webview built through siteSettings must record its container `
        + 'proxy (PROXY-029)');
  }
});

test('every proxySettings handed to a WebView is recorded', () => {
  // The shared builder hands over the binding's proxy; its callers record
  // it, which the test above holds.
  for (const b of builds.filter((b) => !(b.rel === 'lib/services/webview.dart' && b.value === 'binding.proxy'))) {
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
