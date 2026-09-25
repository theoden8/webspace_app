// Router mode must stay behind its experimental switch (DEVTOOLS-011:
// developer mode and the Proxy router switch) while its premise is proven
// on one WebView build only.
//
// PROXY-013 points the process-wide proxy rule at a loopback relay and
// tells sites apart by the credential each presents. That the credential
// cannot bleed between sites is a property of Chromium's per-profile
// `HttpNetworkSession`, checked at activation by the PROXY-015 probe and
// never yet exercised on hardware that fails it. Until it is, the default
// install serialises under PROXY-008 and only the experiment opts in.
//
// The Dart suite asserts the decision (`isSupportedWhen`) but cannot
// assert the wiring: it runs off Android, where `hostIsAndroid` answers
// false first and every further assertion passes without meaning it. So
// the wiring -- that the live gate feeds the experiment into that
// decision at all -- is pinned here, structurally. That the experiment
// needs developer mode is `experimentalFeatureEnabled`'s truth table.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const rel = 'lib/services/proxy_router_service.dart';
const src = fs.readFileSync(path.join(repoRoot, rel), 'utf8');

/** Source of one `static bool <name>(...)` declaration, up to its `;`. */
function declaration(source, name) {
  const at = source.indexOf(`static bool ${name}(`);
  assert.notStrictEqual(at, -1, `${name} should still exist`);
  const end = source.indexOf(';', at);
  assert.notStrictEqual(end, -1, `${name} should terminate`);
  return source.slice(at, end + 1);
}

const experimentRead =
  /experimentEnabled:\s*ExperimentalFeaturesService\.instance\s*\.isEnabled\(ExperimentalFeature\.proxyRouter\)/;

test('isSupported feeds the experiment into the decision', () => {
  const body = declaration(src, 'isSupported');
  assert.match(
    body,
    experimentRead,
    'the live gate must read the Proxy router experiment; without it router '
      + 'mode engages on every container-capable device by default',
  );
});

test('the decision requires the experiment', () => {
  const body = declaration(src, 'isSupportedWhen');
  assert.match(body, /experimentEnabled/, 'the decision must use experimentEnabled');
  assert.doesNotMatch(
    body,
    /experimentEnabled\s*\|\|/,
    'the experiment must narrow the gate, never widen it',
  );
});

test('the guard is not vacuous', () => {
  // The pre-gate shape: platform and engine only. Prove this file rejects it.
  const ungated = `
    static bool isSupported({required bool useContainers}) =>
        hostIsAndroid && useContainers;`;
  assert.doesNotMatch(ungated, experimentRead);
});

test('only the settings row may ask with the experiment assumed on', () => {
  // canRunHere answers "could this device run it", so the Experimental group
  // lists the switch. Anything that activates the relay must go through
  // isSupported instead.
  assert.match(declaration(src, 'canRunHere'), /experimentEnabled: true/);
  const libDir = path.join(repoRoot, 'lib');
  const callers = [];
  const walk = (dir) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith('.dart')
        && fs.readFileSync(p, 'utf8').includes('ProxyRouterService.canRunHere(')) {
        callers.push(path.relative(repoRoot, p));
      }
    }
  };
  walk(libDir);
  assert.deepStrictEqual(callers, ['lib/main.dart']);
  const main = fs.readFileSync(path.join(repoRoot, 'lib/main.dart'), 'utf8');
  const uses = [...main.matchAll(/ProxyRouterService\.canRunHere\(/g)];
  assert.strictEqual(uses.length, 1);
  assert.match(main.slice(uses[0].index - 40, uses[0].index),
    /proxyRouterRunsHere:\s*$/,
    'canRunHere only decides whether App settings lists the switch');
});

test('the Apple relay branch is off unless a caller opts in', () => {
  // Apple does not need the relay: each container store carries its own
  // proxyConfigurations, and BUG-014 measured that delivering
  // distinct upstreams AND distinct credentials per store on both SOCKS5
  // and HTTP CONNECT. The implementation stays for parity testing, so the
  // branch has to be reachable -- and off by default, or it comes back by
  // omission the way `isApple` nearly did.
  const body = declaration(src, 'isSupportedWhen');
  assert.match(
    body,
    /isApple\s*&&\s*appleRelayEnabled/,
    'the Apple branch must be ANDed with appleRelayEnabled, or Apple runs '
      + 'the relay again',
  );
  assert.match(
    body,
    /bool appleRelayEnabled = false/,
    'appleRelayEnabled must default false, so a caller that has not thought '
      + 'about Apple cannot widen the gate by omission',
  );
  assert.match(
    src,
    /static bool appleRelayEnabled = false;/,
    'the live flag must ship off',
  );
  assert.match(
    declaration(src, 'isSupported'),
    /appleRelayEnabled: appleRelayEnabled/,
    'the live gate must feed the flag into the decision, or the decision is '
      + 'gated and the app is not',
  );
});
