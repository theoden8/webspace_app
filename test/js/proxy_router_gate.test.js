// Router mode's gate is the platform, the engine and its own switch
// (PROXY-013): on Android it runs wherever the WebView reports MULTI_PROFILE
// and the Proxy router switch in App settings > Network is on, with
// developer mode on or off. It shipped behind the Proxy router experiment
// (DEVTOOLS-011) while its premise was proven on one WebView build only;
// that gate is lifted and the switch is the user's way back to PROXY-008.
//
// The Dart suite asserts the decision (`isSupportedWhen`) but cannot
// assert the wiring: it runs off Android, where `hostIsAndroid` answers
// false first and every further assertion passes without meaning it. So
// what feeds the decision is pinned here, structurally (rung 5: no type
// says which value a call site passes; a host-platform seam would lift it).

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, dartFiles } = require('./helpers/source');

const rel = 'lib/services/proxy_router_service.dart';
const src = read(rel);

/** Source of one `static bool <name>(...)` declaration, up to its `;`. */
function declaration(source, name) {
  const at = source.indexOf(`static bool ${name}(`);
  assert.notStrictEqual(at, -1, `${name} should still exist`);
  const end = source.indexOf(';', at);
  assert.notStrictEqual(end, -1, `${name} should terminate`);
  return source.slice(at, end + 1);
}

const switchRead = /switchOn:\s*AppPref\.proxyRouter\.value/;

test('the live gate reads its switch', () => {
  assert.match(
    declaration(src, 'isSupported'),
    switchRead,
    'isSupported must read the Proxy router switch; without it the switch '
      + 'shows a value the app ignores',
  );
});

test('the live gate reads neither developer mode nor an experiment', () => {
  assert.doesNotMatch(
    src,
    /ExperimentalFeature|DeveloperMode/,
    'router mode is offered with developer mode on or off (PROXY-013)',
  );
});

test('the decision requires the switch', () => {
  const body = declaration(src, 'isSupportedWhen');
  assert.match(body, /required bool switchOn/, 'a caller must say what the switch reads');
  assert.match(body, /&&\s*switchOn/, 'the switch must narrow the gate');
  assert.doesNotMatch(body, /switchOn\s*\|\|/, 'the switch must narrow the gate, never widen it');
});

test('the guard is not vacuous', () => {
  // The ungated shape: platform and engine only. Prove this file rejects it.
  const ungated = `
    static bool isSupported({required bool useContainers}) =>
        isSupportedWhen(isAndroid: hostIsAndroid, useContainers: useContainers);`;
  assert.doesNotMatch(ungated, switchRead);
});

test('only the settings row may ask with the switch assumed on', () => {
  // canRunHere answers "could this device run it", so the Network screen
  // lists the switch. Anything that activates the relay must go through
  // isSupported instead.
  assert.match(declaration(src, 'canRunHere'), /switchOn: true/);
  const callers = dartFiles()
    .filter((f) => read(f).includes('ProxyRouterService.canRunHere('));
  assert.deepStrictEqual(callers, ['lib/screens/webspace_page.dart']);
  const page = read('lib/screens/webspace_page.dart');
  const uses = [...page.matchAll(/ProxyRouterService\.canRunHere\(/g)];
  assert.strictEqual(uses.length, 1);
  assert.match(page.slice(uses[0].index - 40, uses[0].index),
    /proxyRouterRunsHere:\s*$/,
    'canRunHere only decides whether App settings lists the switch');
});

test('the router starts only where a site is proxied', () => {
  // The route table is the one owner of what each site's traffic resolves
  // to, so the controller asks the engine over it before binding anything
  // (PROXY-013). Rung 5: SiteNetworkController has no boundary test; one
  // with a fake ProxyRouterService would lift this, and needs the service
  // behind an interface first.
  const network = read('lib/controllers/site_network_controller.dart');
  const asks = network.indexOf('ProxyRouterEngine.anyProxied(');
  const binds = network.indexOf('ProxyRouterService.instance.activate(');
  assert.notStrictEqual(asks, -1, 'activateRouter must ask whether any route resolves to a proxy');
  assert.notStrictEqual(binds, -1, 'activateRouter must still bring the router up');
  assert.ok(asks < binds, 'the question comes before the relay is bound');
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
