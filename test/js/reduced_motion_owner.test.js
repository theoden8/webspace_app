// Structural gate (A11Y-011): only lib/services/reduced_motion.dart reads
// the OS's reduced-motion flags; every widget asks `ReducedMotion.of`, and
// code that builds no widget `ReducedMotion.instance.reduced`.
//
// Each flag alone misses a platform: `MediaQuery.disableAnimations` never
// carries iOS's Reduce Motion, `accessibilityFeatures.reduceMotion` is iOS
// alone, and the Mac's comes over a channel only the helper hears. Both
// Flutter flags are public members of Flutter's own types, and Dart cannot
// hide another package's member from a library, so a read is refused here
// (rung 5). Setting the fork's `InAppWebViewSettings.disableAnimations` is a
// write of another thing and is not a read.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, dartFiles, code, lineAt } = require('./helpers/source');

const OWNER = 'lib/services/reduced_motion.dart';
const READ =
  /\b(?:maybe)?[dD]isableAnimationsOf\b|\.disableAnimations\b(?!\s*=[^=])|\.reduceMotion\b/g;

function reads(rel, src) {
  const text = code(src);
  return [...text.matchAll(READ)].map((m) => `${rel}:${lineAt(text, m.index)}`);
}

test('only reduced_motion.dart reads the reduced-motion flags (A11Y-011)', () => {
  const found = dartFiles()
    .filter((rel) => rel !== OWNER)
    .flatMap((rel) => reads(rel, read(rel)));
  assert.deepEqual(found, [], 'ask ReducedMotion.of(context) instead');
  assert.ok(reads(OWNER, read(OWNER)).length > 0,
    `${OWNER} reads no flag; point the gate at the helper's new home`);
});

test('planted: a direct read is caught, a write or a comment is not (A11Y-011)', () => {
  const planted = [
    'bool a(BuildContext context) => MediaQuery.disableAnimationsOf(context);',
    'bool b(BuildContext context) => MediaQuery.of(context).disableAnimations;',
    'bool c() => PlatformDispatcher.instance.accessibilityFeatures.reduceMotion;',
    'bool d(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;',
    '',
  ].join('\n');
  assert.deepEqual(reads('planted.dart', planted),
    ['planted.dart:1', 'planted.dart:2', 'planted.dart:3', 'planted.dart:4']);
  assert.deepEqual(reads('planted.dart', [
    '  ..disableAnimations = reduced',
    '// MediaQuery.disableAnimationsOf(context)',
    '',
  ].join('\n')), []);
});
