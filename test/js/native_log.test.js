// A line the Android code writes reaches the app's log through AppLog.kt and
// nowhere else (DEVTOOLS-014): logcat is what the app cannot show, so a line
// written straight to it is one the user never reads.
//
// Rung 5: Kotlin and Dart share no declarations, so nothing compiled says
// that an AppLog.Tag names a Dart LogTag, or that a Kotlin file logs only
// through AppLog. The Dart side files a line under an unknown tag as Boot.
const test = require('node:test');
const assert = require('node:assert/strict');
const { read, files, code } = require('./helpers/source');

const SINK = 'android/app/src/main/kotlin/org/codeberg/theoden8/webspace/AppLog.kt';
const kotlin = [...files('android/app/src/main', /\.kt$/), ...files('android/app/src/debug', /\.kt$/)];

/** The entries of AppLog's `enum class Tag(...) { a(...), b(...), }`. */
function nativeTags(src) {
  const m = code(src).match(/enum class Tag\b[^{]*\{([^}]*)\}/);
  assert.ok(m, 'AppLog declares enum class Tag');
  return [...m[1].matchAll(/^\s*(\w+)\s*\(/gm)].map((t) => t[1]);
}

/** The values of Dart's `enum LogTag { a('A'), b('B'); ... }`. */
function dartTags(src) {
  const m = code(src).match(/enum LogTag\s*\{([\s\S]*?);/);
  assert.ok(m, 'log_service.dart declares enum LogTag');
  return [...m[1].matchAll(/(\w+)\s*\(/g)].map((t) => t[1]);
}

/** Lines of `src` that log to logcat directly. */
function logcat(src) {
  const masked = code(src, { strings: true });
  return [
    ...masked.matchAll(/^import android\.util\.Log\b.*$/gm),
    ...masked.matchAll(/\bLog\.(v|d|i|w|e|wtf|println)\s*\(/g),
  ].map((m) => masked.slice(0, m.index).split('\n').length);
}

test('every native tag names a Dart LogTag', () => {
  const dart = new Set(dartTags(read('lib/services/log_service.dart')));
  const missing = nativeTags(read(SINK)).filter((t) => !dart.has(t));
  assert.deepEqual(missing, [], 'add the tag to LogTag, or file the line under one it has');
});

test('only AppLog writes to logcat', () => {
  const direct = kotlin
    .filter((f) => f !== SINK)
    .flatMap((f) => logcat(read(f)).map((line) => `${f}:${line}`));
  assert.deepEqual(direct, [], 'write the line through AppLog, which files it where the user reads it');
});

// The gate's own proof: the shapes it must catch, planted.
test('a tag Dart lacks and a direct logcat line are caught (planted)', () => {
  assert.deepEqual(nativeTags('enum class Tag(val namesUserData: Boolean) {\n  a(false),\n  b(true),\n}'), ['a', 'b']);
  assert.deepEqual(dartTags("enum LogTag {\n  a('A'),\n  b('B');\n  const LogTag(this.label);\n}"), ['a', 'b']);
  assert.equal(logcat('import android.util.Log\nfun f() { Log.w(TAG, "x") }').length, 2);
  assert.deepEqual(logcat('fun f() { AppLog.warning(AppLog.Tag.tls, "Log.w(x)") }'), []);
});
