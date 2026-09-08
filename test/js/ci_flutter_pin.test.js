// Structural gate: every CI Flutter bootstrap pins the version `.fvmrc` pins.
//
// The workflows install Flutter twice over. `subosito/flutter-action` is only
// a bootstrap -- the step is named "Setup Flutter (for Dart SDK)" and exists
// so `dart pub global activate fvm` has a `dart` to run; the build itself then
// goes through `fvm install` / `fvm flutter`, pinned by `.fvmrc`. So an
// unpinned bootstrap does not build the app with the wrong SDK.
//
// It is still a floating dependency on whatever `channel: stable` resolves to
// that day, which can break `pub global activate fvm` with no change in the
// repo, and it silently diverged: one job pinned 3.38.6 while another floated
// and ran 3.47.2. Pinning it puts the version in three places, so this test is
// what keeps those three and `.fvmrc` from drifting apart.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const workflowDir = path.join(repoRoot, '.github', 'workflows');

const pinned = JSON.parse(
  fs.readFileSync(path.join(repoRoot, '.fvmrc'), 'utf8'),
).flutter;

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

const steps = fs
  .readdirSync(workflowDir)
  .filter((f) => f.endsWith('.yml') || f.endsWith('.yaml'))
  .flatMap((f) =>
    flutterActionSteps(
      fs.readFileSync(path.join(workflowDir, f), 'utf8'),
      path.join('.github', 'workflows', f),
    ),
  );

test('the workflows still bootstrap Flutter through the action', () => {
  // Guards the extractor: a restructure that matches nothing would make every
  // assertion below pass vacuously.
  assert.ok(steps.length > 0, 'no subosito/flutter-action step found');
});

test('every Flutter bootstrap pins the version from .fvmrc', () => {
  assert.match(pinned, /^\d+\.\d+\.\d+$/, `.fvmrc pin is not a version: ${pinned}`);
  for (const step of steps) {
    const found = step.body.match(/^\s*flutter-version:\s*'?([^'\s]+)'?/m);
    assert.ok(
      found,
      `${step.file}:${step.line} does not pin flutter-version; it would float ` +
        `to whatever the stable channel resolves to`,
    );
    assert.equal(
      found[1],
      pinned,
      `${step.file}:${step.line} pins ${found[1]} but .fvmrc pins ${pinned}`,
    );
  }
});
