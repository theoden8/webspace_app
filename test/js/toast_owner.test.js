// Structural gate: a SnackBar is shown through `toast`
// (lib/widgets/toast.dart), whose message is a `Localized`.
//
// settings_backup.dart, in services, showed its own with English literals
// ("Export failed", "Invalid backup file format") that the L10N-002 guard
// never scans, since it reads screens and widgets only. Showing one past
// `toast` is what this refuses (rung 5: ScaffoldMessengerState is Flutter's,
// and its showSnackBar takes any widget).

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, dartFiles, code, lineAt } = require('./helpers/source');

const OWNER = 'lib/widgets/toast.dart';
const SHOWN = /\bshowSnackBar\s*\(/g;

function shown(rel, src) {
  const text = code(src);
  return [...text.matchAll(SHOWN)].map((m) => `${rel}:${lineAt(text, m.index)}`);
}

test('only toast.dart shows a SnackBar', () => {
  const found = dartFiles().filter((rel) => rel !== OWNER).flatMap((rel) => shown(rel, read(rel)));
  assert.deepEqual(found, [], 'call messenger.toast(loc.x) instead');
  assert.equal(shown(OWNER, read(OWNER)).length, 1);
});

test('planted: a SnackBar built by hand is caught, a mention in a comment is not', () => {
  assert.deepEqual(
    shown('planted.dart', "ScaffoldMessenger.of(context).showSnackBar(\n  SnackBar(content: Text('x')));\n"),
    ['planted.dart:1']);
  assert.deepEqual(shown('planted.dart', '// showSnackBar(x)\n'), []);
});
