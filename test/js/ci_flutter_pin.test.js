// Structural gate: every CI Flutter bootstrap takes its version from `.fvmrc`.
//
// The workflows install Flutter twice over. `subosito/flutter-action` is only
// a bootstrap -- the step is named "Setup Flutter (for Dart SDK)" and exists
// so `dart pub global activate fvm` has a `dart` to run; the build itself then
// goes through `fvm install` / `fvm flutter`, pinned by `.fvmrc`. So an
// unpinned bootstrap does not build the app with the wrong SDK.
//
// It is still a floating dependency on whatever `channel: stable` resolves to
// that day, which can break `pub global activate fvm` with no change in the
// repo, and a literal pin silently diverged: one job pinned 3.38.6 while
// another floated and ran 3.47.2. So the bootstrap reads `.fvmrc` through
// `flutter-version-file`, and `.fvmrc` is the one place the version lives.
// A workflow is YAML no type checks, so this test is what keeps a literal
// `flutter-version:` from coming back.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, files } = require('./helpers/source');

// Each `uses: subosito/flutter-action` line plus the `with:` block under it.
// `with:` is a sibling key at the same indent as `uses:`, so the step ends at
// the first line indented *less* than the `uses:` -- the next `- name:`.
function flutterActionSteps(text, file) {
  const lines = text.split('\n');
  const steps = [];
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(/^(\s*)(?:-\s+)?uses:\s*subosito\/flutter-action/);
    if (!m) continue;
    const indent = lines[i].search(/\S/);
    let end = lines.length;
    for (let j = i + 1; j < lines.length; j++) {
      if (lines[j].trim() === '') continue;
      if (lines[j].search(/\S/) < indent) { end = j; break; }
    }
    steps.push({ file, line: i + 1, body: lines.slice(i + 1, end).join('\n') });
    i = end - 1;
  }
  return steps;
}

const steps = files('.github/workflows', /\.ya?ml$/)
  .flatMap((f) => flutterActionSteps(read(f), f));

test('the workflows still bootstrap Flutter through the action', () => {
  // Guards the extractor: a restructure that matches nothing would make every
  // assertion below pass vacuously.
  assert.ok(steps.length > 0, 'no subosito/flutter-action step found');
});

test('every Flutter bootstrap reads its version from .fvmrc', () => {
  const pinned = JSON.parse(read('.fvmrc')).flutter;
  assert.match(pinned, /^\d+\.\d+\.\d+$/, `.fvmrc pin is not a version: ${pinned}`);
  for (const step of steps) {
    const file = step.body.match(/^\s*flutter-version-file:\s*'?([^'\s]+)'?/m);
    assert.equal(
      file?.[1],
      '.fvmrc',
      `${step.file}:${step.line} must take flutter-version-file: '.fvmrc'; ` +
        `without it the bootstrap floats to whatever stable resolves to`,
    );
    assert.doesNotMatch(
      step.body,
      /^\s*flutter-version:/m,
      `${step.file}:${step.line} names a Flutter version of its own; ` +
        `.fvmrc is the one place it lives`,
    );
  }
});
