// A proxy address is parsed in one place, ProxyAddressParse in
// lib/settings/proxy.dart (PROXY-017). Three copies once took it apart with
// split(':') or lastIndexOf(':'): the process-wide rule refused a bracketed
// IPv6 proxy the screens accepted and wrote a rule for port 0, and each relay
// read the address its own way. Rung 5: a String field cannot say which
// function may read it.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, code, dartFiles, lineAt } = require('./helpers/source');

const OWNER = 'lib/settings/proxy.dart';
const SPLIT = /\baddress[!?]?\s*\.\s*(?:split|lastIndexOf|indexOf)\(\s*['"]:['"]/g;

test('only ProxyAddressParse takes a proxy address apart (PROXY-017)', () => {
  const offenders = [];
  for (const f of dartFiles()) {
    if (f === OWNER) continue;
    const src = code(read(f));
    for (const m of src.matchAll(SPLIT)) offenders.push(`${f}:${lineAt(src, m.index)}`);
  }
  assert.deepEqual(offenders, [], 'read the address through ProxyAddressParse.of');
});
