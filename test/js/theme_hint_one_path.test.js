// HINTS-005: the theme hint takes one path on every engine.
//
// Android, iOS, macOS and Linux each get the same script with the same
// value, at document start and again when the theme changes. That holds as
// long as nothing on the way asks which platform it is on: the page script
// reads no engine identity, and the Dart that builds and installs it has no
// platform branch. Rung 5: no type says a path is platform-free; a planted
// `if (hostIsAndroid)` or `navigator.userAgent` read is what this catches.
// test/theme_reapply_test.dart drives the reinstall itself.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, code } = require('./helpers/source');
const { blockAfter } = require('./helpers/dart_blocks');

const PLATFORM = /\bhostIs\w+|\bPlatform\.\w+|\bdefaultTargetPlatform\b|\bkIsWeb\b/;
const ENGINE = /navigator\s*\.\s*(?:userAgent|userAgentData|platform|vendor)\b|\bwebkit\w*|\bchrome\b/i;

const dart = (rel) => code(read(rel), { strings: true });

test('HINTS-005: the page script reads no engine identity', () => {
  const js = code(read('lib/js/theme_color_scheme.js'), { strings: true });
  assert.doesNotMatch(js, ENGINE);
});

test('HINTS-005: the Dart that builds the script has no platform branch', () => {
  assert.doesNotMatch(dart('lib/services/theme_color_scheme_shim.dart'), PLATFORM);
});

test('HINTS-005: a theme change reinstalls it the same way on every platform', () => {
  const src = dart('lib/services/webview_controller.dart');
  for (const method of ['Future<void> setThemePreference(WebViewTheme theme) async', 'Future<void> _rotateShim(']) {
    assert.doesNotMatch(blockAfter(src, method), PLATFORM, method);
  }
});

test('HINTS-005: the first document gets it from the one arm every platform takes', () => {
  const src = dart('lib/services/page_scripts.dart');
  const at = src.indexOf('ShimGroup.themeColorScheme =>');
  assert.ok(at >= 0, 'page_scripts.dart no longer installs the theme group');
  const arm = src.slice(at, src.indexOf('],', at));
  assert.match(arm, /buildThemeColorSchemeShim\(/);
  assert.doesNotMatch(arm, PLATFORM);
  assert.doesNotMatch(arm, /\bif\b/, 'the theme hint is installed unconditionally');
});
