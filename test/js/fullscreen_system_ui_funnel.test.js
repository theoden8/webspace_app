// Full-screen system UI funnel gate (FS-011 / BUG-023). Full screen picks its
// immersive mode in one place, `_fullscreenSystemUiMode`. Android reports
// sticky bars to the app as hidden, so a path that asks for `immersiveSticky`
// itself puts a swiped-in navigation bar back over a kept tab strip
// (github #672), the way the resume path would have if it had kept its own
// literal.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');

function dartFiles(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (full === path.join(repoRoot, 'lib', 'l10n', 'gen')) continue;
      out.push(...dartFiles(full));
    } else if (entry.name.endsWith('.dart')) {
      out.push(full);
    }
  }
  return out;
}

const ALLOWED = new Set(['SystemUiMode.edgeToEdge', '_fullscreenSystemUiMode']);

test('every setEnabledSystemUIMode call leaves the immersive mode to the funnel', () => {
  const offenders = [];
  let calls = 0;
  for (const file of dartFiles(path.join(repoRoot, 'lib'))) {
    const src = fs.readFileSync(file, 'utf8');
    for (const m of src.matchAll(/setEnabledSystemUIMode\(\s*([^,)]+)/g)) {
      calls++;
      const arg = m[1].trim();
      if (ALLOWED.has(arg)) continue;
      const line = src.slice(0, m.index).split('\n').length;
      offenders.push(`${path.relative(repoRoot, file)}:${line} (${arg})`);
    }
  }
  assert.ok(calls >= 2, `expected the funnel and the exit call, found ${calls}`);
  assert.deepEqual(
    offenders,
    [],
    'full screen must set its mode through _fullscreenSystemUiMode ' +
      '(FS-011), not name one itself',
  );
});

test('main.dart hides bars the user revealed under immersive', () => {
  const src = fs.readFileSync(path.join(repoRoot, 'lib', 'main.dart'), 'utf8');
  assert.match(src, /SystemChrome\.setSystemUIChangeCallback\(_onSystemUiChange\)/);
  assert.match(src, /SystemChrome\.setSystemUIChangeCallback\(null\)/);
});
