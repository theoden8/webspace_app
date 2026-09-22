// Router mode must stay behind developer mode while its premise is
// proven on one WebView build only.
//
// PROXY-013 points the process-wide proxy rule at a loopback relay and
// tells sites apart by the credential each presents. That the credential
// cannot bleed between sites is a property of Chromium's per-profile
// `HttpNetworkSession`, checked at activation by the PROXY-015 probe and
// never yet exercised on hardware that fails it. Until it is, the default
// install serialises under PROXY-008 and only developer mode opts in.
//
// The Dart suite asserts the decision (`isSupportedWhen`) but cannot
// assert the wiring: it runs off Android, where `hostIsAndroid` answers
// false first and every further assertion passes without meaning it. So
// the wiring -- that the live gate feeds developer mode into that
// decision at all -- is pinned here, structurally.

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

test('isSupported feeds developer mode into the decision', () => {
  const body = declaration(src, 'isSupported');
  assert.match(
    body,
    /DeveloperModeService\.instance\.enabled/,
    'the live gate must read developer mode; without it router mode '
      + 'engages on every container-capable device by default',
  );
});

test('the decision requires developer mode', () => {
  const body = declaration(src, 'isSupportedWhen');
  assert.match(body, /developerMode/, 'the decision must use developerMode');
  assert.doesNotMatch(
    body,
    /developerMode\s*\|\|/,
    'developer mode must narrow the gate, never widen it',
  );
});

test('the guard is not vacuous', () => {
  // The pre-gate shape: platform and engine only. Prove this file rejects it.
  const ungated = `
    static bool isSupported({required bool useContainers}) =>
        hostIsAndroid && useContainers;`;
  assert.doesNotMatch(ungated, /DeveloperModeService\.instance\.enabled/);
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
