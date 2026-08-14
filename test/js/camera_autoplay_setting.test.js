// Structural guard for the camera autoplay fix.
//
// Android WebView defaults `mediaPlaybackRequiresUserGesture` to true, which
// blocks a getUserMedia MediaStream assigned to a `<video autoplay>` from
// playing — real OR virtual camera — so a QR-scan page shows a grey frame.
// The fix sets it false on the main webview. This gate is Android-WebView-
// specific (the setting does not exist in the Chromium the browser test tier
// drives), so a real-engine test can't catch a regression; assert the source
// keeps the setting instead.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');

function stripComments(src) {
  return src.replace(/\/\/[^\n]*/g, '').replace(/\/\*[\s\S]*?\*\//g, '');
}

test('the main webview allows media to autoplay so camera streams render', () => {
  const src = stripComments(
    fs.readFileSync(path.join(repoRoot, 'lib/services/webview.dart'), 'utf8'),
  );
  assert.match(
    src,
    /mediaPlaybackRequiresUserGesture\s*=\s*false/,
    'webview.dart must set mediaPlaybackRequiresUserGesture = false, or a '
      + 'getUserMedia stream (real or virtual camera) will not play on Android '
      + 'WebView and the page shows a grey frame.',
  );
});

test('the virtual-camera preview also allows autoplay so the loop plays', () => {
  const src = stripComments(
    fs.readFileSync(
      path.join(repoRoot, 'lib/widgets/virtual_camera_preview.dart'), 'utf8'),
  );
  assert.match(src, /mediaPlaybackRequiresUserGesture\s*:\s*false/,
    'the preview WebView must autoplay so the looped clip plays without a tap.');
});
