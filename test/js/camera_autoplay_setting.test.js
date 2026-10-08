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
const { read, code } = require('./helpers/source');

test('the main webview allows media to autoplay so camera streams render', () => {
  const src = code(read('lib/services/webview.dart'));
  assert.match(
    src,
    /mediaPlaybackRequiresUserGesture\s*=\s*false/,
    'webview.dart must set mediaPlaybackRequiresUserGesture = false, or a '
      + 'getUserMedia stream (real or virtual camera) will not play on Android '
      + 'WebView and the page shows a grey frame.',
  );
});

test('the virtual-camera preview also allows autoplay so the loop plays', () => {
  const src = code(read('lib/widgets/virtual_source_preview.dart'));
  assert.match(src, /mediaPlaybackRequiresUserGesture\s*:\s*false/,
    'the preview WebView must autoplay so the looped clip plays without a tap.');
});
