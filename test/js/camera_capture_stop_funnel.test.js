// Camera-stop funnel gate (CAM-012). Every path that stops a site from being
// the one on screen must end its device capture, and must do so BEFORE the
// pause: on iOS the per-instance pause blocks the page's JS thread (the
// plugin's alert() hack, see openspec/specs/webview-pause-lifecycle/spec.md),
// so JS posted after it would sit queued until the site is resumed — i.e. the
// camera would keep capturing for exactly as long as the site is backgrounded,
// which is the case the requirement exists for.
//
// A structural gate rather than a runtime one because the failure is invisible
// at runtime on every platform except iOS-on-device: the tests pass, the
// camera stays on.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { blockAfter } = require('./helpers/dart_blocks');

const repoRoot = path.resolve(__dirname, '..', '..');
const MAIN = 'lib/main.dart';

const src = fs.readFileSync(path.join(repoRoot, MAIN), 'utf8');
const lines = src.split('\n');

// Every deactivation path (go-home, site switch, the sweep of the sites left
// in the background) runs the same step list through one funnel, so the
// ordering is asserted once, where it is decided. See NAV-010.
test(`${MAIN}: the deactivation funnel stops capture before it pauses`, () => {
  const funnel = blockAfter(
    src, 'Future<void> _quiesceOutgoingSite(', ') async {', MAIN);
  const stopIdx = funnel.indexOf('stopRealCameraCapture');
  const pauseIdx = funnel.indexOf('pauseWebView');
  assert.notEqual(stopIdx, -1,
    'a site being backgrounded must have its device capture ended (CAM-012)');
  assert.notEqual(pauseIdx, -1, 'the funnel must still pause the webview');
  assert.ok(
    stopIdx < pauseIdx,
    'the stop must be posted before the pause, or iOS freezes the JS ' +
      'thread with the capture still running',
  );
});

// Deactivation sites outside the funnel: a pause issued directly against a
// site that is losing (or has lost) active status. pauseForAppLifecycle is a
// different axis — the whole app going to background — and is deliberately
// not covered here.
const pauseSites = lines
  .map((line, i) => ({ line, i }))
  .filter(({ line }) => /\.pauseWebView\(\)/.test(line));

for (const { line, i } of pauseSites) {
  test(`${MAIN}:${i + 1}: capture stop precedes the pause`, () => {
    // The stop is either chained onto this same statement or issued in the
    // preceding lines of the same block. Comments are stripped first: prose
    // naming either call would otherwise decide the ordering check.
    const window = lines
      .slice(Math.max(0, i - 12), i + 3)
      .map((l) => l.replace(/\/\/.*$/, ''))
      .join('\n');
    assert.match(
      window,
      /stopRealCameraCapture\(\)/,
      `a site being backgrounded must have its device capture ended first ` +
        `(CAM-012). Offending pause: ${line.trim()}`,
    );
    const stopIdx = window.indexOf('stopRealCameraCapture()');
    const pauseIdx = window.indexOf('pauseWebView()');
    assert.ok(
      stopIdx < pauseIdx,
      'the stop must be posted before the pause, or iOS freezes the JS ' +
        'thread with the capture still running',
    );
  });
}

test('WebViewModel.stopRealCameraCapture is not folded into pauseWebView', () => {
  const model = fs.readFileSync(
    path.join(repoRoot, 'lib/web_view_model.dart'),
    'utf8',
  );
  const pauseBody = model.slice(
    model.indexOf('Future<void> pauseWebView()'),
    model.indexOf('Future<void> stopRealCameraCapture()'),
  );
  assert.ok(
    !/stopRealCameraCapture\(/.test(pauseBody),
    'pauseWebView() early-returns for notification and background-audio ' +
      'sites; folding the camera stop into it would exempt exactly the sites ' +
      'whose JS keeps running in the background',
  );
});
