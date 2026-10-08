// Full-screen system UI funnel gate (FS-011 / BUG-023). Full screen picks its
// immersive mode in one place, `FullscreenController._systemUiMode`. Android reports
// sticky bars to the app as hidden, so a path that asks for `immersiveSticky`
// itself puts a swiped-in navigation bar back over a kept tab strip
// (github #672), the way the resume path would have if it had kept its own
// literal.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, dartFiles } = require('./helpers/source');

const ALLOWED = new Set(['SystemUiMode.edgeToEdge', '_systemUiMode']);

test('every setEnabledSystemUIMode call leaves the immersive mode to the funnel', () => {
  const offenders = [];
  let calls = 0;
  for (const file of dartFiles()) {
    const src = read(file);
    for (const m of src.matchAll(/setEnabledSystemUIMode\(\s*([^,)]+)/g)) {
      calls++;
      const arg = m[1].trim();
      if (ALLOWED.has(arg)) continue;
      const line = src.slice(0, m.index).split('\n').length;
      offenders.push(`${file}:${line} (${arg})`);
    }
  }
  assert.ok(calls >= 2, `expected the funnel and the exit call, found ${calls}`);
  assert.deepEqual(
    offenders,
    [],
    'full screen must set its mode through FullscreenController._systemUiMode ' +
      '(FS-011), not name one itself',
  );
});

test('full screen hides bars the user revealed under immersive', () => {
  const src = read('lib/controllers/fullscreen_controller.dart');
  assert.match(src, /SystemChrome\.setSystemUIChangeCallback\(onSystemUiChange\)/);
  assert.match(src, /SystemChrome\.setSystemUIChangeCallback\(null\)/);
});
