// Structural gate: under the process-wide proxy rule (Android without the
// router, Linux) each Tor site keeps its own circuit (TOR-003, TOR-025).
//
// A Tor site's isolation is the SOCKS credential it presents, and the tag in
// that credential is the site id. On this path two things lose it silently:
// resolving a site's proxy without its id, which hands every Tor site the
// app-global tag, and applying a TOR setting without expanding it, which
// dials the leftover manual address a TOR setting keeps (PROXY-010). Neither
// fails a request; both put sites on one circuit or off Tor altogether.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, dartFiles, code, enclosed } = require('./helpers/source');

test('every setProxySettings call names the site it applies for', () => {
  const missing = [];
  let seen = 0;
  for (const rel of dartFiles()) {
    const text = code(read(rel));
    const re = /\.setProxySettings\s*\(/g;
    let m;
    while ((m = re.exec(text)) !== null) {
      seen++;
      const args = enclosed(text, m.index, '(').body;
      if (!/\bsiteId\s*:/.test(args)) {
        missing.push(`${rel}: setProxySettings(${args})`);
      }
    }
  }
  assert.ok(seen > 0, 'no setProxySettings call sites found; gate is stale');
  assert.deepEqual(missing, []);
});

test('the process-wide rule expands TOR with the site id before applying', () => {
  const text = code(read('lib/services/webview.dart'));
  const at = text.search(/Future<void>\s+setProxySettings\s*\(/);
  assert.ok(at >= 0, 'ProxyManager.setProxySettings not found');
  const body = enclosed(text, text.indexOf(')', at), '{').body;
  assert.match(body, /resolveEffectiveProxy\(\s*settings\s*,\s*siteId:\s*siteId\s*\)/);
  const expand = body.search(/expandTorProxy\(/);
  const override = body.search(/\.setProxyOverride\(/);
  assert.ok(expand >= 0, 'TOR is never expanded on the process-wide path');
  assert.ok(expand < override, 'TOR must be expanded before any override');
});

test('the mismatch unload compares Tor sites by their own tags', () => {
  const text = code(read('lib/services/site_unload_engine.dart'));
  const at = text.search(/static Set<int> indicesToUnloadForProxyMismatch\(/);
  const body = enclosed(text, text.indexOf(')', at), '{').body;
  const calls = body.match(/resolveEffectiveProxy\(([^;]*?)\)\s*;/gs) || [];
  assert.ok(calls.length >= 2, 'expected the target and each loaded site');
  for (const call of calls) {
    assert.match(call, /siteId:/, `resolved without a site id: ${call}`);
  }
});
