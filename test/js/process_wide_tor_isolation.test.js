// Structural gate: under the process-wide proxy rule (Android without the
// router, Linux) each Tor site keeps its own circuit (TOR-003, TOR-025).
//
// A Tor site's isolation is the SOCKS credential it presents, and the tag in
// that credential is the site id. `siteId` is required on `setProxySettings`
// and `resolveEffectiveProxy`, so a call that forgets it no longer compiles.
// What a type cannot say is the order inside the rule: a TOR setting applied
// without expanding it dials the leftover manual address a TOR setting keeps
// (PROXY-010), which fails no request and takes the site off Tor.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, code, enclosed } = require('./helpers/source');

test('the process-wide rule expands TOR with the site id before applying', () => {
  const text = code(read('lib/services/webview_proxy.dart'));
  const at = text.search(/Future<void>\s+setProxySettings\s*\(/);
  assert.ok(at >= 0, 'ProxyManager.setProxySettings not found');
  const body = enclosed(text, text.indexOf(')', at), '{').body;
  assert.match(body, /resolveEffectiveProxy\(\s*settings\s*,\s*siteId:\s*siteId\s*\)/);
  const expand = body.search(/expandTorProxy\(/);
  const override = body.search(/\.setProxyOverride\(/);
  assert.ok(expand >= 0, 'TOR is never expanded on the process-wide path');
  assert.ok(expand < override, 'TOR must be expanded before any override');
});
