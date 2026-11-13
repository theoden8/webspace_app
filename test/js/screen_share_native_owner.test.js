// SHARE-017 on Android: a share belongs to the engine that started it.
//
// The capture is the process's (one MediaProjection, one foreground
// service), while each activity a share sheet opens runs a Flutter engine,
// and so a Dart side, of its own. Only the plugin that started a share may
// read its frames, stop it or hear that it ended, and the share ends with
// that plugin's engine. Not a type and not a JVM test: the plugin cannot be
// built without an activity and an engine, and its state is a process-wide
// object, so these assertions read the source.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read } = require('./helpers/source');

const ROOT = 'android/app/src/main/kotlin/org/codeberg/theoden8/webspace';
const plugin = read(`${ROOT}/ScreenSharePlugin.kt`);
const service = read(`${ROOT}/ScreenShareService.kt`);
const activity = read(`${ROOT}/MainActivity.kt`);

test('only the owner reads the frames', () => {
  assert.match(plugin,
    /fun frame\(caller: ScreenSharePlugin, [^)]*\) \{\s*if \(live == null \|\| liveOwner !== caller\) \{\s*result\.success\(ENDED\)/,
    'a pull from another engine must read ended, or a site there reads the share '
    + 'the user granted a site here');
});

test('only the owner stops it, and only the owner hears it ended', () => {
  const at = plugin.indexOf('"stop" -> {');
  assert.notEqual(at, -1, 'the stop call is gone');
  const stop = plugin.slice(at, plugin.indexOf('result.success(null)', at));
  assert.match(stop, /if \(ScreenShareSession\.liveOwner === this\) ScreenShareService\.end\(\)/,
    'another engine\'s idle watchdog or page must not end this share');
  assert.equal(stop.match(/ScreenShareService\.end\(\)/g).length, 1,
    'and nothing in the stop call ends it unconditionally');
  assert.ok(!/var onEnded/.test(plugin),
    'an ended share is told to its owner, not to whichever plugin registered last');
  assert.match(plugin, /val owner = liveOwner[\s\S]*?owner\?\.ended\(\)/);
});

test('a share ends with its engine and with the app\'s task', () => {
  assert.match(activity,
    /override fun cleanUpFlutterEngine\([\s\S]*?screenSharePlugin\?\.dispose\(\)/,
    'nothing would end a share whose Dart side is gone');
  assert.match(plugin,
    /fun dispose\(\) \{[\s\S]*?if \(ScreenShareSession\.liveOwner === this\) ScreenShareService\.end\(\)/);
  assert.match(service, /override fun onTaskRemoved\([\s\S]*?end\(\)/,
    'the user swiping the app away takes the page reading the share with it');
  assert.match(service,
    /if \(pending\.abandoned\) \{[\s\S]*?enterForeground\(pending\.request\)\s*end\(\)/,
    'a service started for the foreground enters it before it ends, or the app crashes');
});

test('a share starts only from an app in front', () => {
  assert.match(plugin,
    /isAtLeast\(Lifecycle\.State\.RESUMED\)[\s\S]*?if \(ScreenShareSession\.pendingStart != null \|\| !resumed\) \{\s*result\.success\(null\)/,
    'a prompt raised from the background lands over another app, or never answers');
});

// A share's limits are Dart's (ShareLimits in lib/services/screen_share.dart):
// each native side once invented its own when a value was missing (1280 and
// 10 fps, clamped at 30, against Dart's 15), so a caller that forgot one got
// a share Dart never allowed. Native sides now refuse a missing value; a
// fallback or a clamp written beside one of these keys is what this refuses.
const LIMIT_KEYS = ['maxWidth', 'maxHeight', 'maxLongSide', 'fps'];
const NATIVE = [
  `${ROOT}/ScreenSharePlugin.kt`,
  'macos/Runner/ScreenSharePlugin.swift',
  'linux/screen_share.cc',
];

function restatedLimits(rel, src) {
  const keys = LIMIT_KEYS.join('|');
  const read = new RegExp(String.raw`["'](?:${keys})["'][^\n]*?(?:\?:|\?\?|coerceIn|,\s*-?\d+\s*\))`, 'g');
  return [...src.matchAll(read)].map((m) => `${rel}:${src.slice(0, m.index).split('\n').length}`);
}

test('no native side restates a share limit Dart owns', () => {
  assert.deepEqual(NATIVE.flatMap((rel) => restatedLimits(rel, read(rel))), [],
    'refuse a missing value with bad-args instead of picking one');
});

test('planted: each native fallback shape is caught; a required read is not', () => {
  for (const planted of [
    'maxLongSide = call.argument<Int>("maxLongSide") ?: 1280,',
    'fps: min(max(args["fps"] as? Int ?? 10, 1), 30)',
    'int_arg(args, "maxLongSide", 1280),',
  ]) {
    assert.equal(restatedLimits('planted', planted).length, 1, planted);
  }
  assert.deepEqual(restatedLimits('planted', 'val fps = call.argument<Any>("fps") as? Int'), []);
  assert.deepEqual(restatedLimits('planted', 'const auto fps = required_int(args, "fps");'), []);
});
