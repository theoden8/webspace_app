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
  assert.match(text.slice(at, text.indexOf(';', at)),
    /_platformTakes\(\s*\(\)\s*=>\s*_applyRule\(\s*settings\s*,\s*siteId:\s*siteId\s*(?:,\s*\w+:\s*\w+\s*)*,?\s*\)\s*\)/,
    'setProxySettings applies the rule through _applyRule');
  const rule = text.search(/Future<void>\s+_applyRule\s*\(/);
  assert.ok(rule >= 0, 'ProxyManager._applyRule not found');
  const body = enclosed(text, text.indexOf(')', rule), '{').body;
  assert.match(body, /resolveEffectiveProxy\(\s*settings\s*,\s*siteId:\s*siteId\s*\)/);
  const expand = body.search(/expandTorProxy\(/);
  const override = body.search(/\.setProxyOverride\(/);
  assert.ok(expand >= 0, 'TOR is never expanded on the process-wide path');
  assert.ok(expand < override, 'TOR must be expanded before any override');
});
