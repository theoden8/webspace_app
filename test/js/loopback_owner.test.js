// Structural gate: whether a host is loopback is answered by `Host` alone
// (`isLoopbackLiteral`, `isLoopback` in lib/services/url_host.dart).
//
// Five hand-written checks once gave five answers: the proxy bypass missed
// 127.0.0.2, the router's challenge check missed ::1, the passkey check took
// 127.999.0.1. A type cannot stop a comparison against a string literal, so
// the comparison itself is what this refuses (rung 5).

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, dartFiles, code, lineAt } = require('./helpers/source');

const OWNER = 'lib/services/url_host.dart';

// A comparison against a loopback address written out, either way round.
const LOOPBACK = String.raw`'(?:127\.0\.0\.1|::1|\[::1\])'`;
const COMPARED = new RegExp(String.raw`(?:==|!=)\s*${LOOPBACK}|${LOOPBACK}\s*(?:==|!=)`, 'g');

// A comparison kept on purpose, with the reason it is not a loopback check.
const KEPT = {
  // Tor binds a SocksPort given as a bare number to 127.0.0.1 exactly; the
  // listener rule names that address, not the loopback range.
  'lib/services/external_tor_posture_engine.dart': 1,
};

function comparisons(rel, src) {
  const text = code(src);
  return [...text.matchAll(COMPARED)].map((m) => `${rel}:${lineAt(text, m.index)}`);
}

test('no file outside url_host.dart compares a host with a loopback address', () => {
  const found = {};
  for (const rel of dartFiles()) {
    if (rel === OWNER) continue;
    const hits = comparisons(rel, read(rel));
    if (hits.length) found[rel] = hits;
  }
  const unexpected = Object.entries(found)
    .filter(([rel, hits]) => hits.length !== KEPT[rel])
    .flatMap(([, hits]) => hits);
  assert.deepEqual(unexpected, [],
    'ask Host(raw).isLoopbackLiteral or .isLoopback instead of comparing');
  for (const rel of Object.keys(KEPT)) {
    assert.ok(found[rel], `${rel} no longer compares; drop it from KEPT`);
  }
});

test('planted: a hand-written loopback check is caught', () => {
  const planted = "bool f(String h) => h == 'localhost' || h == '::1';\n";
  assert.deepEqual(comparisons('planted.dart', planted), ['planted.dart:1']);
  assert.deepEqual(comparisons('planted.dart', "// h == '::1'\n"), [],
    'a comment is not a comparison');
});
