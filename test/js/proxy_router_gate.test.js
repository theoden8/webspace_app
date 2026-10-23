// Router mode's gate is the platform and the engine, nothing else
// (PROXY-013): on Android it engages wherever the WebView reports
// MULTI_PROFILE, with developer mode on or off. It shipped behind the
// Proxy router experiment (DEVTOOLS-011) while its premise was proven on
// one WebView build only; that gate is lifted, and this file holds it
// lifted, since a switch put back here would return the default install
// to PROXY-008 with nothing else failing.
//
// The Dart suite asserts the decision (`isSupportedWhen`) but cannot
// assert the wiring: it runs off Android, where `hostIsAndroid` answers
// false first and every further assertion passes without meaning it. So
// what feeds the decision is pinned here, structurally.

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

// A read of either gate, by the type that answers it.
const gateRead = /ExperimentalFeature|DeveloperMode/;

test('the live gate reads neither developer mode nor an experiment', () => {
  assert.doesNotMatch(
    src,
    gateRead,
    'router mode is offered with developer mode on or off (PROXY-013); a '
      + 'switch read here puts the default install back on PROXY-008',
  );
  assert.doesNotMatch(
    declaration(src, 'isSupportedWhen'),
    /experimentEnabled|developerMode/,
    'the decision takes the platform and the engine only',
  );
});

test('the guard is not vacuous', () => {
  // The gated shape this file retired. Prove it would be rejected.
  const gated = `
    static bool isSupported({required bool useContainers}) => isSupportedWhen(
        isAndroid: hostIsAndroid,
        useContainers: useContainers,
        experimentEnabled: ExperimentalFeaturesService.instance
            .isEnabled(ExperimentalFeature.proxyRouter));`;
  assert.match(gated, gateRead);
});

test('no screen asks whether the router could run here', () => {
  // `canRunHere` existed so the Experimental group could list the switch;
  // with the switch gone, the one question left is `isSupported`, asked
  // by the activation.
  assert.strictEqual(src.indexOf('canRunHere'), -1, 'canRunHere went with the switch');
  const askers = dartFiles().filter((f) => read(f).includes('proxyRouterRunsHere'));
  assert.deepStrictEqual(askers, [], 'the settings screens no longer take the answer');
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
