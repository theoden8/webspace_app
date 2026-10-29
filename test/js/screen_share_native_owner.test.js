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
