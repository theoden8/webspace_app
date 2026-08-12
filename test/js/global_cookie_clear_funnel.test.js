// Unscoped global cookie-clear gate (BUG-007, issues #524 / #525).
//
// `CookieManager.deleteAllCookies()` carries no site with it: the plugin
// resolves which jar to empty from its own state. Under the container engine
// every site owns its jar and that state is the only thing standing between
// "clear the unused default jar" and "wipe a live site's session" — which is
// exactly what happened when a container-scoped read poisoned the plugin's
// static CookieManager memo (fixed in the fork at v6.2.0-beta.3-privacy-v6).
//
// The app-side invariant that keeps the class unreachable: never issue an
// unscoped clear while containers are in use. Every call must be gated on the
// engine selection, either lexically (`!_useContainers`) or by sitting behind
// OrphanSweepEngine's `useContainers: false` branch (the
// `clearLegacyGlobalCookieJar` funnel). A new ungated call site re-opens it.
//
// Structural rather than behavioral: reproducing the real defect needs an
// Android device with WebViewFeature.MULTI_PROFILE and two live profiles,
// which no CI tier here has. See test/orphan_sweep_engine_test.dart for the
// behavioral half (the sweep must not ask for the clear under containers).

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');

/// The one place allowed to call it unconditionally: the legacy engine, which
/// only ever runs when containers are unsupported, plus the wrapper's own
/// definition.
const EXEMPT_FILES = new Set([
  'lib/services/cookie_isolation.dart',
  'lib/services/webview.dart',
]);

/// Name of the OrphanSweepTargets method whose only caller is the engine's
/// `if (!useContainers)` branch.
const FUNNEL_METHOD = 'clearLegacyGlobalCookieJar';

function dartSources(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...dartSources(full));
    else if (entry.name.endsWith('.dart')) out.push(full);
  }
  return out;
}

function callSites() {
  const sites = [];
  for (const file of dartSources(path.join(repoRoot, 'lib'))) {
    const rel = path.relative(repoRoot, file);
    if (EXEMPT_FILES.has(rel)) continue;
    const lines = fs.readFileSync(file, 'utf8').split('\n');
    lines.forEach((line, i) => {
      // `deleteAllCookiesForUrl` is URL-scoped and therefore not this class.
      if (!/\.deleteAllCookies\(\)/.test(line)) return;
      sites.push({ rel, line: i + 1, context: lines.slice(Math.max(0, i - 8), i + 1) });
    });
  }
  return sites;
}

test('every unscoped global cookie clear is gated on the engine selection', () => {
  const ungated = callSites().filter(({ context }) => {
    const window = context.join('\n');
    return !window.includes('_useContainers') && !window.includes(FUNNEL_METHOD);
  });

  assert.deepEqual(
    ungated.map((s) => `${s.rel}:${s.line}`),
    [],
    'unscoped deleteAllCookies() must be gated on !_useContainers or reached ' +
      `via ${FUNNEL_METHOD} — an ungated call can empty a live container's jar`,
  );
});

test('the sweep funnel is still routed through the engine', () => {
  // Guards the other half: the funnel method must stay behind the engine's
  // container check rather than being called directly from the host.
  const engine = fs.readFileSync(
    path.join(repoRoot, 'lib/services/orphan_sweep_engine.dart'),
    'utf8',
  );
  assert.match(
    engine,
    /if \(!useContainers\) \{\s*await targets\.clearLegacyGlobalCookieJar\(\);/,
    'OrphanSweepEngine must only clear the legacy jar when containers are off',
  );

  const main = fs.readFileSync(path.join(repoRoot, 'lib/main.dart'), 'utf8');
  const directCalls = main.match(/clearLegacyGlobalCookieJar\(\)/g) ?? [];
  assert.equal(
    directCalls.length,
    1,
    'main.dart should only define the funnel override, never call it directly',
  );
});
