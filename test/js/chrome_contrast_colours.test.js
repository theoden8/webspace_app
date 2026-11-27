// Structural gate: the chrome draws no grey, orange, amber or red of its own
// (A11Y-010).
//
// On white, Colors.grey is 2.68:1, Colors.orange 2.16:1 and Colors.red 3.68:1,
// all under the 4.5:1 text needs, and grey and orange under the 3:1 a state
// indicator needs. The roles that replace them hold both brightnesses and
// every accent in test/accent_theme_contrast_test.dart: `onSurfaceVariant`
// for muted text, `error` for destructive and failed, `warning` and
// `accentText` (lib/theme/accent_theme.dart) for a warning and for the accent
// drawn as text. Rung 5: a Color says nothing of whether it is drawn as text,
// and one reaches a TextStyle through a variable as often as directly, so the
// names are refused anywhere in the chrome, not only inside a TextStyle.
//
// Scans the same files as design_tokens_no_literals.test.js, so a new UI file
// is covered without an edit here.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, dartFiles, code, lineAt } = require('./helpers/source');

const SCANNED = ['lib/main.dart', 'lib/app.dart', ...dartFiles('lib/screens'), ...dartFiles('lib/widgets')];

const FIXED = /\bColors\.(grey|orange|amber|red)\b/g;

function fixed(rel, src) {
  const text = code(src);
  return [...text.matchAll(FIXED)].map((m) => `${rel}:${lineAt(text, m.index)} ${m[0]}`);
}

test('the chrome draws no fixed grey, orange, amber or red (A11Y-010)', () => {
  const found = SCANNED.flatMap((rel) => fixed(rel, read(rel)));
  assert.deepEqual(found, [],
    'use a ColorScheme role: onSurfaceVariant, error, warning or accentText');
});

test('planted: a fixed colour as text is caught (A11Y-010)', () => {
  assert.deepEqual(
    fixed('planted.dart', "Text(label, style: const TextStyle(color: Colors.grey));\n"),
    ['planted.dart:1 Colors.grey']);
  assert.deepEqual(
    fixed('planted.dart', 'final muted = isDark\n    ? Colors.grey.shade400\n    : Colors.red[700];\n'),
    ['planted.dart:2 Colors.grey', 'planted.dart:3 Colors.red']);
  assert.deepEqual(
    fixed('planted.dart', '// Colors.orange read 2.16:1\nfinal c = Colors.redAccent;\n'),
    []);
});
