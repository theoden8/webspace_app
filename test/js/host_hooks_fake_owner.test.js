// Structural gate: tests build a webview host from one owner per tier,
// naming only the answers they watch: `inertHostHooks` in
// test/helpers/host_hooks.dart, `bareHooks` in integration_test/bare_site.dart.
//
// Seven test files each spelled out all fourteen answers; CLAUDE.md keeps one
// fake per interface in test/helpers/, and nothing held that here. A test
// constructing the host itself is what this refuses (rung 5: a test file can
// call any public constructor).

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, dartFiles, code, lineAt } = require('./helpers/source');

const OWNERS = ['test/helpers/host_hooks.dart', 'integration_test/bare_site.dart'];
const BUILT = /\bWebViewHostHooks\s*\(/g;

function built(rel, src) {
  const text = code(src);
  return [...text.matchAll(BUILT)].map((m) => `${rel}:${lineAt(text, m.index)}`);
}

test('only each tier\'s owner builds a test host', () => {
  const found = [...dartFiles('test'), ...dartFiles('integration_test')]
    .filter((rel) => !OWNERS.includes(rel))
    .flatMap((rel) => built(rel, read(rel)));
  assert.deepEqual(found, [], 'use inertHostHooks(...) or bareHooks(...) with the answers the test watches');
  for (const rel of OWNERS) assert.equal(built(rel, read(rel)).length, 1, `${rel} builds it once`);
});

test('planted: a test spelling out the host is caught', () => {
  assert.deepEqual(built('planted_test.dart', 'final h = WebViewHostHooks(\n  save: () async {},\n);\n'),
    ['planted_test.dart:1']);
});
