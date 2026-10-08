// Native capture-grant gate (MIC-003 / CAM-001 / MIC-015).
//
// `onPermissionRequest` is the one place the app can hand a page a real
// device. What it answers is CapturePermissionEngine's, whose clauses
// test/capture_permission_engine_test.dart holds. What is left is the closure
// that feeds it, which no test can reach without a platform view and a
// permission request:
//
//   - it must ask the GRANT STORE, not read a mode off a model. The store is
//     what applies the on-screen gate (MIC-011) and the archive-tier fold
//     (MIC-006); a closure that read the stored captures directly would grant
//     a backgrounded or archived site and every existing test would stay green.
//   - it must name a device whichever way the platform reports it: iOS and
//     macOS as one CAMERA_AND_MICROPHONE, Android as CAMERA plus MICROPHONE.
//     Android's pair once reached the microphone decision alone, so a frame
//     the shims missed got the camera on the microphone's grant.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, blockAfter, code } = require('./helpers/source');

const SRC = 'lib/services/webview.dart';
const src = read(SRC);

const handler = code(
  blockAfter(src, 'onPermissionRequest: grants == null', '(controller, request) async {', SRC));

test(`${SRC}: the answer is the engine's, asked through the grant store`, () => {
  assert.match(handler, /CapturePermissionEngine\.answer\(/);
  assert.match(handler, /opensDevice: \(kind\) async \{[\s\S]*?grants\.capture\(kind, origin,[\s\S]*?opensRealDevice\(/,
    'the device decision must come from the store, which applies the on-screen '
      + 'gate (MIC-011) and the archive-tier fold (MIC-006)');
  assert.doesNotMatch(handler, /\.captures\b/,
    'reading the stored captures directly bypasses both gates');
});

test(`${SRC}: each device is named however the platform reports it`, () => {
  const camera = /camera: resources\.contains\(inapp\.PermissionResourceType\.CAMERA\) \|\|\s*resources\.contains\(cameraAndMicrophone\)/;
  const microphone = /microphone:\s*resources\.contains\(inapp\.PermissionResourceType\.MICROPHONE\) \|\|\s*resources\.contains\(cameraAndMicrophone\)/;
  assert.match(handler, camera);
  assert.match(handler, microphone);
});
