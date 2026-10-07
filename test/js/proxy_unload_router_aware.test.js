// Every proxy-mismatch eviction must know whether router mode is running.
//
// `indicesToUnloadForProxyMismatch` exists because Android's proxy override is
// process-global and last-write-wins. Router mode (PROXY-013) removes that: the
// rule points at the loopback relay permanently and each site is told apart by
// the credential it presents, so evicting a mismatched sibling buys nothing and
// costs the cold start the feature exists to remove.
//
// A call site that hardcodes a process-global topology therefore silently
// reserialises the app on whatever path it sits on. One arrived that way with
// the "Open in site" nested-open fix (SEC-004), reachable from a share intent.
// Cheaper to gate structurally than to notice a site cold-starting.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, callSites } = require('./helpers/source');

const calls = () => callSites('indicesToUnloadForProxyMismatch');

test('there is at least one call site to check', () => {
  assert.ok(calls().length > 0, 'the eviction is called from somewhere');
});

/** The ProxyTopology a call passes, or null. */
function topologyOf(args) {
  const value = /topology:\s*([\s\S]*?)(?:,\s*\w+:|,?\s*$)/.exec(args);
  return value ? value[1].trim() : null;
}

test('no call site hardcodes the topology', () => {
  for (const { file, args } of calls()) {
    const expr = topologyOf(args);
    assert.ok(expr, `${file}: call passes no topology`);
    assert.doesNotMatch(
      expr,
      /ProxyTopology|PerSessionProxy|ProcessGlobalProxy|RoutedProxy/,
      `${file}: topology ${expr} is hardcoded rather than read from `
        + 'SiteNetworkController.topology, which asks whether router mode is running',
    );
  }
});

test('the page derives its topology from the router state', () => {
  assert.match(read('lib/main.dart'),
    /ProxyTopology get proxyTopology => state\._network\.topology;/,
    'the residency plan reads the topology the network controller derives');
  const getter = /ProxyTopology get topology \{([\s\S]*?)\n  \}/.exec(
    read('lib/controllers/site_network_controller.dart'));
  assert.ok(getter, 'SiteNetworkController must define topology');
  assert.match(getter[1], /ProxyRouterService\.instance\.isActive/,
    'Android is process-global only while the router is off (PROXY-013)');
});

test('the guard is not vacuous', () => {
  // The shape that regressed: Android and Linux both global, unconditionally.
  const regressed = 'targetIndex: index, models: m, loadedIndices: l, '
    + 'topology: const ProcessGlobalProxy(),';
  const expr = topologyOf(regressed);
  assert.ok(expr);
  assert.match(expr, /ProcessGlobalProxy/);
});
