// Structural gate: a widget test wires AppLocalizations through
// test/helpers/localized.dart (`localizedApp`, `pumpLocalized`).
//
// Twenty-odd tests each built a MaterialApp with the delegates and locales
// by hand; a new locale setting, or a test that forgot one half, was one
// copy away from the others. A test passing the delegates itself is what
// this refuses (rung 5: a MaterialApp takes them from anyone).

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, dartFiles, code, lineAt } = require('./helpers/source');

const OWNER = 'test/helpers/localized.dart';
const WIRED = /\blocalizationsDelegates\s*:/g;

function wired(rel, src) {
  const text = code(src);
  return [...text.matchAll(WIRED)].map((m) => `${rel}:${lineAt(text, m.index)}`);
}

test('only localized.dart wires the localizations into a test app', () => {
  const found = dartFiles('test')
    .filter((rel) => rel !== OWNER)
    .flatMap((rel) => wired(rel, read(rel)));
  assert.deepEqual(found, [], 'use localizedApp(home, ...) or pumpLocalized');
  assert.equal(wired(OWNER, read(OWNER)).length, 1);
});

test('planted: a test wiring them by hand is caught; reading them is not', () => {
  assert.deepEqual(wired('planted_test.dart',
    'MaterialApp(\n  localizationsDelegates: AppLocalizations.localizationsDelegates,\n)'),
  ['planted_test.dart:2']);
  assert.deepEqual(wired('planted_test.dart', 'expect(app.localizationsDelegates, x);'), []);
});
