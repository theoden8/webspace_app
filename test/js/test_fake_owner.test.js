// Structural gate: a fake test/helpers/ declares is not declared again in a
// test file.
//
// CLAUDE.md keeps one fake per interface in test/helpers/ and says to extend
// it with the knob a test needs. container_isolation_integration_test.dart
// redefined MockContainerNative with a cookie jar added, so the engine's
// tests ran against two models of one platform API. A class in a test file
// named as a helper's is that copy, and what this refuses (rung 5: Dart lets
// a library declare any name its imports do not).

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, dartFiles, code, lineAt } = require('./helpers/source');

const DECLARED = /^(?:(?:abstract|base|final|sealed|interface|mixin)\s+)*(?:class|mixin)\s+(\w+)/gm;

function declared(src) {
  const text = code(src);
  return [...text.matchAll(DECLARED)].map((m) => ({ name: m[1], at: m.index, text }));
}

function copies(helperNames, rel, src) {
  return declared(src)
    .filter((d) => helperNames.has(d.name))
    .map((d) => `${rel}:${lineAt(d.text, d.at)} ${d.name}`);
}

test('no test file declares a class test/helpers/ declares', () => {
  const helpers = dartFiles('test').filter((rel) => rel.startsWith('test/helpers/'));
  const names = new Set(helpers.flatMap((rel) => declared(read(rel)).map((d) => d.name)));
  const found = dartFiles('test')
    .filter((rel) => !rel.startsWith('test/helpers/'))
    .flatMap((rel) => copies(names, rel, read(rel)));
  assert.deepEqual(found, [], 'import the helper and extend it there instead');
});

test('planted: a test redefining a helper fake is caught', () => {
  const names = new Set(['MockContainerNative']);
  assert.deepEqual(
    copies(names, 'planted_test.dart', 'class MockContainerNative implements ContainerNative {}\n'),
    ['planted_test.dart:1 MockContainerNative']);
  assert.deepEqual(copies(names, 'planted_test.dart', 'class _Other {}\n'), []);
});
