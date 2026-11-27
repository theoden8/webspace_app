// Structural gate: the chrome draws no fixed grey, orange, amber, red, green
// or blue of its own, and no border in raw `primary` (A11Y-010).
//
// On white, Colors.grey is 2.68:1, Colors.orange 2.16:1, Colors.red 3.68:1,
// Colors.green 2.78:1 and Colors.blue 3.12:1, all under the 4.5:1 text needs
// and most under the 3:1 a state indicator needs; the green accent as
// `primary` is 1.56:1. The roles that replace them hold both brightnesses and
// every accent in test/accent_theme_contrast_test.dart: `onSurfaceVariant`
// for muted text, `error` for destructive and failed, and from
// lib/theme/accent_theme.dart `warning`, `success`, `info`, `accentText` for
// the accent as text and `accentIndicator` for it as a state. Rung 5: a Color
// says nothing of whether it is drawn as text or as a state, and one reaches a
// TextStyle through a variable as often as directly, so the names are refused
// anywhere in the chrome. A selection border is the commonest state drawn in
// the accent, so `primary` is refused inside a border's call; a dot or a bar
// in `primary` is not caught here.
//
// Scans the same files as design_tokens_no_literals.test.js, so a new UI file
// is covered without an edit here.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, dartFiles, code, lineAt, enclosed } = require('./helpers/source');

const SCANNED = ['lib/main.dart', 'lib/app.dart', ...dartFiles('lib/screens'), ...dartFiles('lib/widgets')];

const FIXED = /\bColors\.(grey|orange|amber|red|green|blue|lightBlue)\b/g;
const BORDER = /\b(Border\.all|BorderSide)\s*\(/g;
const PRIMARY = /\.primary\b/;

function fixed(rel, src) {
  const text = code(src);
  return [...text.matchAll(FIXED)].map((m) => `${rel}:${lineAt(text, m.index)} ${m[0]}`);
}

function primaryBorders(rel, src) {
  const text = code(src);
  return [...text.matchAll(BORDER)]
    .filter((m) => PRIMARY.test(enclosed(text, m.index, '(', rel).body))
    .map((m) => `${rel}:${lineAt(text, m.index)} ${m[1]}`);
}

test('the chrome draws no fixed grey, orange, amber, red, green or blue (A11Y-010)', () => {
  const found = SCANNED.flatMap((rel) => fixed(rel, read(rel)));
  assert.deepEqual(found, [],
    'use a ColorScheme role: onSurfaceVariant, error, warning, success, info or accentText');
});

test('no border in the chrome is drawn in raw primary (A11Y-010)', () => {
  const found = SCANNED.flatMap((rel) => primaryBorders(rel, read(rel)));
  assert.deepEqual(found, [], 'draw a state in accentIndicator');
});

test('planted: a fixed colour as text is caught (A11Y-010)', () => {
  assert.deepEqual(
    fixed('planted.dart', "Text(label, style: const TextStyle(color: Colors.grey));\n"),
    ['planted.dart:1 Colors.grey']);
  assert.deepEqual(
    fixed('planted.dart', 'final muted = isDark\n    ? Colors.grey.shade400\n    : Colors.red[700];\n'),
    ['planted.dart:2 Colors.grey', 'planted.dart:3 Colors.red']);
  assert.deepEqual(
    fixed('planted.dart', 'Icon(Icons.check, color: Colors.green);\n'),
    ['planted.dart:1 Colors.green']);
  assert.deepEqual(
    fixed('planted.dart', '// Colors.orange read 2.16:1\nfinal c = Colors.redAccent;\n'),
    []);
});

test('planted: a selection border in raw primary is caught (A11Y-010)', () => {
  assert.deepEqual(
    primaryBorders('planted.dart',
      'border: Border.all(\n  color: selected\n      ? theme.colorScheme.primary\n      : null,\n),\n'),
    ['planted.dart:1 Border.all']);
  assert.deepEqual(
    primaryBorders('planted.dart', 'side: BorderSide(color: scheme.primary, width: 2),\n'),
    ['planted.dart:1 BorderSide']);
  assert.deepEqual(
    primaryBorders('planted.dart',
      'Border.all(color: scheme.accentIndicator);\nBorderSide(color: scheme.primaryContainer);\n'),
    []);
});
