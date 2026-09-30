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
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');

function dartFiles(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...dartFiles(full));
    else if (entry.name.endsWith('.dart')) out.push(full);
  }
  return out;
}

function argsAt(text, open) {
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    const c = text[i];
    if (c === '(') depth++;
    else if (c === ')' && --depth === 0) return text.slice(open + 1, i);
  }
  return null;
}

const builds = [];
for (const file of dartFiles(path.join(repoRoot, 'lib'))) {
  const text = fs.readFileSync(file, 'utf8').replace(/^\s*\/\/.*$/gm, '');
  const rel = path.relative(repoRoot, file);
  const re = /InAppWebViewSettings\s*\(/g;
  let m;
  while ((m = re.exec(text)) !== null) {
    const args = argsAt(text, text.indexOf('(', m.index));
    const proxy = args && /\bproxySettings:\s*([^,\n]+)/.exec(args);
    if (proxy) builds.push({ rel, text, value: proxy[1].trim() });
  }
}

test('the gate sees the builders it guards', () => {
  const where = builds.map((b) => b.rel);
  assert.ok(
    where.filter((r) => r === 'lib/services/webview.dart').length >= 2,
    'the site and popup builders in webview.dart pass proxySettings; if they '
      + 'stopped, update this gate rather than letting it pass on nothing',
  );
  assert.ok(where.includes('lib/services/proxy_router_probe.dart'));
});

test('every proxySettings handed to a WebView is recorded', () => {
  for (const b of builds) {
    const noted = new RegExp(
      `noteStoreProxy\\([^,]+,\\s*${b.value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\)`,
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
