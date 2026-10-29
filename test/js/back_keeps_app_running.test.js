// Back at the root sends the app's task behind; it never finishes the
// activity (NAV-009).
//
// The Dart side leaves with `SystemNavigator.pop()`, which the Flutter
// embedding turns into `Activity.finish()` unless the activity's
// `popSystemNavigator()` hook consumes it (PlatformPlugin). Finishing takes
// the engine with it: a 0.4.0 log shows every Back from the site list
// followed by "Flutter engine detached" and a cold start with no site
// loaded, notification sites included. Android 12 itself moves a task's root
// to the back on Back.
//
// A source gate (rung 5): Kotlin compiles the embedding's default just as
// well, and no tier here runs an activity. `moveTaskToBack(false)` and not
// `true`: an instance a share started in another app's task is not its
// task's root, and `true` would send that app's task away.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, code } = require('./helpers/source');

const activity = code(read(
  'android/app/src/main/kotlin/org/codeberg/theoden8/webspace/MainActivity.kt'));

test('NAV-009: leaving the app sends its task behind instead of finishing it', () => {
  assert.match(activity,
    /override fun popSystemNavigator\(\): Boolean = moveTaskToBack\(false\)/,
    'MainActivity consumes the pop by moving its task to the back, and only '
    + 'as its task\'s root');
  assert.ok(!/\bfinish\(\)/.test(activity),
    'nothing in the activity finishes it: the engine and its sites go with it');
});
