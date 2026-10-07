// BUG-030: a fetch made on a site's behalf carries the site's Tor isolation
// tag, which only WebViewModel.outboundProxySettings adds; the stored
// proxySettings sends a Tor site's request down the app-global circuit,
// where it can be linked to the site. Rung 5 because every outbound API takes
// a plain UserProxySettings; an OutboundProxy type that only
// outboundProxySettings returns would make this a compile error.
const test = require('node:test');
const assert = require('node:assert');
const { read, dartFiles, code, lineAt } = require('./helpers/source');

// Takes the stored settings with the site id beside them and adds the tag
// itself (ProxyRouterEngine.buildRoutes).
const ALLOWED = new Set(['lib/controllers/site_network_controller.dart']);

test('no fetch is handed a site\'s stored proxySettings (BUG-030)', () => {
  const offenders = [];
  for (const file of dartFiles('lib')) {
    if (ALLOWED.has(file)) continue;
    const src = code(read(file));
    for (const m of src.matchAll(/\bproxy:\s*[\w.]+\.proxySettings\b/g)) {
      offenders.push(`${file}:${lineAt(src, m.index)}`);
    }
  }
  assert.deepEqual(offenders, [], 'pass outboundProxySettings, which carries the site\'s Tor tag');
});
