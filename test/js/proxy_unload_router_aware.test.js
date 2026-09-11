// Every proxy-mismatch eviction must know whether router mode is running.
//
// `indicesToUnloadForProxyMismatch` exists because Android's proxy override is
// process-global and last-write-wins. Router mode (PROXY-013) removes that: the
// rule points at the loopback relay permanently and each site is told apart by
// the credential it presents, so evicting a mismatched sibling buys nothing and
// costs the cold start the feature exists to remove.
//
// A call site that hardcodes `proxyIsGlobal: true` therefore silently
// reserialises the app on whatever path it sits on. One arrived that way with
// the "Open in site" nested-open fix (SEC-004), reachable from a share intent.
// Cheaper to gate structurally than to notice a site cold-starting.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');

function dartSources(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...dartSources(p));
    else if (entry.name.endsWith('.dart')) out.push(p);
  }
  return out;
}

/** Each `indicesToUnloadForProxyMismatch(...)` call, as `{file, args}`. */
function callSites() {
  const calls = [];
  for (const file of dartSources(path.join(repoRoot, 'lib'))) {
    const src = fs.readFileSync(file, 'utf8');
    let from = 0;
    for (;;) {
      const at = src.indexOf('indicesToUnloadForProxyMismatch(', from);
      if (at === -1) break;
      from = at + 1;
      // The declaration itself is not a call.
      if (/static\s+Set<int>\s*$/.test(src.slice(Math.max(0, at - 40), at))) {
        continue;
      }
      let i = src.indexOf('(', at);
      let depth = 0;
      for (let j = i; j < src.length; j++) {
        if (src[j] === '(') depth++;
        else if (src[j] === ')' && --depth === 0) {
          calls.push({
            file: path.relative(repoRoot, file),
            args: src.slice(i + 1, j),
          });
          break;
        }
      }
    }
  }
  return calls;
}

test('there is at least one call site to check', () => {
  assert.ok(callSites().length > 0, 'the eviction is called from somewhere');
});

test('no call site hardcodes a global proxy on Android', () => {
  for (const { file, args } of callSites()) {
    const value = /proxyIsGlobal:\s*([\s\S]*?)(?:,\s*\w+:|,?\s*$)/.exec(args);
    assert.ok(value, `${file}: call passes no proxyIsGlobal`);
    const expr = value[1];
    if (!/hostIsAndroid/.test(expr)) {
      // A call that never claims Android is global cannot reserialise it.
      continue;
    }
    assert.match(
      expr,
      /ProxyRouterService\.instance\.isActive/,
      `${file}: proxyIsGlobal claims Android without asking whether router `
        + 'mode is running, which evicts siblings PROXY-013 keeps loaded',
    );
  }
});

test('the guard is not vacuous', () => {
  // The shape that regressed: Android and Linux both global, unconditionally.
  const regressed = 'targetIndex: index, models: m, loadedIndices: l, '
    + 'proxyIsGlobal: hostIsAndroid || hostIsLinux,';
  const value = /proxyIsGlobal:\s*([\s\S]*?)(?:,\s*\w+:|,?\s*$)/.exec(regressed);
  assert.ok(value);
  assert.match(value[1], /hostIsAndroid/);
  assert.doesNotMatch(value[1], /ProxyRouterService\.instance\.isActive/);
});
