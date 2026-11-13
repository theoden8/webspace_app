// Structural gate: a yes/no question goes through `confirm` or `choose`
// (lib/widgets/confirm_dialog.dart).
//
// Seven dialogs built their own two-button AlertDialog: the two deletes
// coloured their button red by hand, and a dismissal read as no in some and
// as a third answer in others. A `showDialog<bool>` written elsewhere is that
// copy, and what this refuses (rung 5: showDialog is Flutter's and takes any
// builder).

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, dartFiles, code, lineAt } = require('./helpers/source');

const OWNER = 'lib/widgets/confirm_dialog.dart';
const ASKED = /\bshowDialog\s*<\s*bool\s*>\s*\(/g;

function asked(rel, src) {
  const text = code(src);
  return [...text.matchAll(ASKED)].map((m) => `${rel}:${lineAt(text, m.index)}`);
}

test('only confirm_dialog.dart asks a yes/no question', () => {
  const found = dartFiles().filter((rel) => rel !== OWNER).flatMap((rel) => asked(rel, read(rel)));
  assert.deepEqual(found, [], 'call confirm(...) or choose<bool>(...) instead');
});

test('planted: a hand-built yes/no dialog is caught', () => {
  assert.deepEqual(asked('planted.dart', 'final ok = await showDialog<bool>(\n  context: context,\n);\n'),
    ['planted.dart:1']);
  assert.deepEqual(asked('planted.dart', 'await showDialog<String>(context: c);\n'), []);
});
