// Router mode's gate is the binding (PROXY-013): on Android it runs wherever
// the WebView reports MULTI_PROFILE, for the whole run, with developer mode
// on or off and no switch. It shipped behind the Proxy router experiment
// (DEVTOOLS-011), then behind a switch that kept PROXY-008 as the way back;
// both are gone, and PROXY-008 is the binding of devices without per-site
// profiles only.
//
// The Dart suite asserts the decision (`isSupportedWhen`) but cannot
// assert the wiring: it runs off Android, where the binding is the host's
// own and every further assertion passes without meaning it. So what feeds
// the decision is pinned here, structurally (rung 5: no type says which
// value a call site passes; a host-platform seam would lift it).

const test = require('node:test');
const assert = require('node:assert/strict');
const { read } = require('./helpers/source');

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

test('the decision is the routed binding, and nothing narrows it', () => {
  const body = declaration(src, 'isSupportedWhen');
  assert.match(body, /binding == ProxyBinding\.routed \|\|/,
    'wherever the binding routes, router mode runs');
  assert.doesNotMatch(body, /switchOn|AppPref/,
    'no switch takes router mode away where the binding routes');
});

test('the live gate reads the binding the restore decided', () => {
  const network = read('lib/controllers/site_network_controller.dart');
  assert.match(network,
    /ProxyRouterService\.isSupported\(\s*binding: ProxyManager\.binding,/,
    'the controller must ask with the latched binding, not a platform test');
});

test('the live gate reads neither developer mode nor an experiment', () => {
  assert.doesNotMatch(
    src,
    /ExperimentalFeature|DeveloperMode|AppPref/,
    'router mode is offered with developer mode on or off, and no pref '
      + 'gates it (PROXY-013)',
  );
});

test('the restore decides the binding from the isolation it probed', () => {
  const startup = read('lib/controllers/startup_controller.dart');
  const decided = startup.indexOf('final isolation = _sites.isolation = decided;');
  const binds = startup.indexOf('ProxyManager.decideBinding(isolation);');
  assert.notStrictEqual(decided, -1);
  assert.notStrictEqual(binds, -1,
    'the restore must decide the binding, or Android never routes');
  assert.ok(binds > decided, 'after the isolation is decided');
});

test('the router starts only where a site is proxied', () => {
  // The route table is the one owner of what each site's traffic resolves
  // to, so the controller asks the engine over it before binding anything,
  // at the launch and at the first proxy of a run that started without one
  // (PROXY-013). Rung 5: SiteNetworkController has no boundary test; one
  // with a fake ProxyRouterService would lift this, and needs the service
  // behind an interface first.
  const network = read('lib/controllers/site_network_controller.dart');
  const body = (signature) => {
    const at = network.indexOf(signature);
    assert.notStrictEqual(at, -1, `${signature} should still exist`);
    return network.slice(at, network.indexOf('\n  }\n', at));
  };
  for (const signature of [
    'Future<void> activateRouter(',
    'Future<void> refreshRoutes(',
  ]) {
    const fn = body(signature);
    const asks = fn.indexOf('ProxyRouterEngine.anyProxied(');
    const starts = fn.indexOf('_startRouter(');
    assert.notStrictEqual(asks, -1, `${signature} must ask whether any route resolves to a proxy`);
    assert.notStrictEqual(starts, -1, `${signature} must bring the router up`);
    assert.ok(asks < starts, `${signature}: the question comes before the relay is bound`);
  }
  assert.match(body('Future<void> refreshRoutes('), /router\.failed\) return;/,
    'a start that failed is not tried again this run');
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
