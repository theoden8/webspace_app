// Structural gate: every client that lets a rejected certificate through on
// its pin asks `TrustedHostsService.honours`, which owns "a pin is honoured
// unless the OS last reported a captive portal" (TLS-012, SEC-055).
//
// The webview path read the portal verdict and the Dart clients did not, so
// favicons, downloads and user-script fetches trusted a portal's certificate
// on a pin the user made for the host. A call to the bare pin lookup
// (`isTrusted`) outside its owner is that client, and what this refuses
// (rung 5: Dart has no way to make a public method callable from one file).

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, dartFiles, code, lineAt } = require('./helpers/source');

const OWNER = 'lib/services/trusted_hosts_service.dart';
const BARE = /\.isTrusted\s*\(/g;

function bare(rel, src) {
  const text = code(src);
  return [...text.matchAll(BARE)].map((m) => `${rel}:${lineAt(text, m.index)}`);
}

test('no client honours a pin past TrustedHostsService.honours', () => {
  const found = dartFiles().filter((rel) => rel !== OWNER).flatMap((rel) => bare(rel, read(rel)));
  assert.deepEqual(found, [], 'ask TrustedHostsService.instance.honours(...)');
  assert.match(read(OWNER), /bool honours\(/, `${OWNER} owns honours`);
});

test('planted: a client that skips the verdict is caught', () => {
  assert.deepEqual(bare('planted.dart',
    'onBadCertificate: (c) => TrustedHostsService.instance.isTrusted(\n  host: h, port: p, fingerprint: f),\n'),
  ['planted.dart:1']);
  assert.deepEqual(bare('planted.dart', '// .isTrusted(x)\n'), []);
});
