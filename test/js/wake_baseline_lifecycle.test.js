// The unread baselines a background wake compares against are taken on every
// step away from the foreground (NOTIF-014), not on `paused` alone. A swipe
// from Android's Recents can end the process before `paused` arrives, and a
// baseline never taken made the first message after that close post nothing.
// Rung 5: no type says which lifecycle states a call runs on. The emulator
// tier would lift it with a scenario that swipes the task away, which adb
// drives only as `am kill` of a process that already saw `paused`.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, code, dartFiles, blockAfter } = require('./helpers/source');

const lifecycleRel = 'lib/controllers/app_lifecycle_controller.dart';
const lifecycle = code(read(lifecycleRel));
const background = code(read('lib/controllers/background_sites_controller.dart'));

test('NOTIF-014: baselines are taken on every step away from the foreground', () => {
  const changed = blockAfter(lifecycle, 'void changed(AppLifecycleState state) {', null, lifecycleRel);
  const away = blockAfter(changed, 'if (state != AppLifecycleState.resumed) {', null, 'changed()');
  assert.match(away, /\bbackground\.noteBaselines\(\);/,
    'a state-specific branch misses the close that never reaches it');
});

test('NOTIF-014: one call takes them, and it persists what it read', () => {
  const calls = dartFiles().flatMap((f) =>
    [...code(read(f)).matchAll(/\.noteBaselines\(\)/g)].map(() => f));
  assert.deepEqual(calls, [lifecycleRel],
    'a second call in one lifecycle branch reads as coverage the funnel gives');
  const body = blockAfter(background, 'void noteBaselines() {', null,
    'background_sites_controller.dart');
  assert.match(body, /_persistBaselines\(\)/,
    'the next process is the one a swiped-away app wakes in');
});
