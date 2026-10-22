// Full-screen system UI funnel gate (FS-011 / FS-012 / BUG-023). Full screen
// asks for its system UI in one place, `FullscreenSystemUi.request` in
// lib/services/fullscreen_system_ui.dart. Android reports sticky bars to the
// app as hidden, so a path that asks for `immersiveSticky` itself puts a
// swiped-in navigation bar back over a kept tab strip (github #672), the way
// the resume path would have if it had kept its own literal; and a path that
// hides the status bar itself puts a tab strip along the top edge in its
// place.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, dartFiles } = require('./helpers/source');

const FUNNEL = 'lib/services/fullscreen_system_ui.dart';

test('every setEnabledSystemUIMode call outside the funnel leaves full screen', () => {
  const offenders = [];
  let funnelCalls = 0;
  let exitCalls = 0;
  for (const file of dartFiles()) {
    const src = read(file);
    for (const m of src.matchAll(/setEnabledSystemUIMode\(\s*([^,)]+)/g)) {
      const arg = m[1].trim();
      if (file === FUNNEL) {
        funnelCalls++;
        continue;
      }
      if (arg === 'SystemUiMode.edgeToEdge') {
        exitCalls++;
        continue;
      }
      const line = src.slice(0, m.index).split('\n').length;
      offenders.push(`${file}:${line} (${arg})`);
    }
  }
  assert.ok(funnelCalls >= 1, `expected the funnel to ask the platform, found ${funnelCalls} calls`);
  assert.ok(exitCalls >= 1, `expected the exit call, found ${exitCalls}`);
  assert.deepEqual(
    offenders,
    [],
    'full screen must ask for its system UI through FullscreenSystemUi.request ' +
      '(FS-011, FS-012), not name a mode itself',
  );
});

test('full screen hides bars the user revealed where they stay', () => {
  const src = read('lib/controllers/fullscreen_controller.dart');
  assert.match(src, /SystemChrome\.setSystemUIChangeCallback\(onSystemUiChange\)/);
  assert.match(src, /SystemChrome\.setSystemUIChangeCallback\(null\)/);
});
