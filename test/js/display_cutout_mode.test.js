// The window lays out into the display cutout on the short edges, so full
// screen draws the page beside a notch instead of a black letterbox bar
// (FS-010, github #457).
//
// A source gate (rung 5): the cutout mode is a window attribute the
// activity sets, which no Dart tier sees and no tier here runs an activity
// to read. The page's half, insetting left and right only out of full
// screen, is held by test/fullscreen_system_bars_test.dart.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, code } = require('./helpers/source');

const activity = code(read(
  'android/app/src/main/kotlin/org/codeberg/theoden8/webspace/MainActivity.kt'));

test('FS-010: the activity lays its window out into the short-edge cutout', () => {
  assert.match(activity,
    /layoutInDisplayCutoutMode\s*=\s*WindowManager\.LayoutParams\.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES/,
    'MainActivity sets the short-edge cutout mode on its window');
  assert.match(activity,
    /override fun onCreate\([^)]*\)\s*\{[\s\S]*?layoutInDisplayCutoutMode/,
    'set in onCreate, before the first frame lays out');
});
