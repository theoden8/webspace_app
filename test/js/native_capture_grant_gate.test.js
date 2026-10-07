// Native capture-grant gate (MIC-003 / CAM-001 / MIC-015).
//
// `onPermissionRequest` is the one place the app can hand a page a real
// device, and it is a closure inside `WebViewFactory.createWebView`: no unit
// test can reach it without a platform view, and the widget tests that do
// mount one never fire a permission request. So the branch that decides a
// microphone grant has no runtime coverage on any tier, which is why it gets
// a structural one.
//
// The microphone branch used to be an unconditional DENY, which needed no
// gate: there was nothing it could get wrong. It now grants, and every clause
// that makes granting safe is easy to delete without failing a single test:
//
//   - it must ask the GRANT STORE, not read a mode off a model. The store is
//     what applies the on-screen gate (MIC-011) and the archive-tier fold
//     (MIC-006); a branch that read the stored captures directly would grant
//     a backgrounded or archived site and every existing test would stay green.
//   - it must require a mode that opens the device, not merely a decision.
//   - it must hold the app-level permission (MIC-015), or Android's
//     `PermissionRequest.grant()` fails silently and the page sees a dead
//     track instead of a denial.
//   - the combined CAMERA_AND_MICROPHONE resource cannot be half-granted, so
//     it must additionally require the camera to be `real`.
//   - it must never fall through to PROMPT, which iOS 15+/macOS 12+ render as
//     WebKit's own per-site prompt: a second decision the app does not
//     control and cannot reconcile with the one it just made.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, blockAfter, code } = require('./helpers/source');

const SRC = 'lib/services/webview.dart';
const src = read(SRC);

// The handler body, comments removed. `onPermissionRequest:` opens with a
// ternary guard, so the block starts at the `async {` of the callback.
const handler = code(
  blockAfter(src, 'onPermissionRequest: grants == null', '(controller, request) async {', SRC));

// The microphone branch: from the `wantsMicrophone` test to the end of the
// `if` that answers it.
const micBranch = blockAfter(handler, 'if (wantsMicrophone || wantsBoth)', null,
  `${SRC} microphone branch`);

// How the branch asks: one helper over the store, shared with the camera path.
const helperAt = handler.indexOf('Future<bool> opensDevice(');
assert.notEqual(helperAt, -1, `${SRC}: opensDevice is gone`);
const opensDevice = handler.slice(helperAt, handler.indexOf(';', helperAt));

test(`${SRC}: a device grant goes through the grant store`, () => {
  assert.match(opensDevice, /grants\.capture\(kind, origin/,
    'the branch must ask the store, which is what applies the on-screen '
      + 'gate (MIC-011) and the archive-tier fold (MIC-006)');
  assert.match(micBranch, /opensDevice\(\s*CaptureKind\.microphone/);
  assert.doesNotMatch(handler, /\.captures\b/,
    'reading the stored captures directly bypasses both gates');
});

test(`${SRC}: a microphone grant requires a mode that opens the device`, () => {
  assert.match(opensDevice, /opensRealDevice\(/,
    'GRANT must be conditioned on the decision being `real`');
  const grantIdx = micBranch.indexOf('PermissionResponseAction.GRANT');
  assert.notEqual(grantIdx, -1, 'the branch must still be able to grant');
  assert.ok(
    micBranch.indexOf('opensDevice(') < grantIdx,
    'the mode check must precede the grant',
  );
});

test(`${SRC}: a microphone grant requires the app-level permission`, () => {
  assert.match(micBranch, /MicrophonePermissionService\.ensurePermission\(\)/,
    'without RECORD_AUDIO Android grant() fails silently (MIC-015)');
});

test(`${SRC}: the combined resource needs the camera to be real too`, () => {
  // iOS and macOS report camera+microphone as one resource, so granting it on
  // the microphone decision alone would hand over a camera the user set to
  // block, virtual or ask.
  assert.match(micBranch, /wantsBoth/,
    'the branch must distinguish CAMERA_AND_MICROPHONE from MICROPHONE');
  assert.match(micBranch, /if \(granted && wantsBoth\) \{\s*granted = await opensDevice\(CaptureKind\.camera/,
    'a combined grant must also require the camera decision to be real');
});

test(`${SRC}: the microphone branch never falls through to PROMPT`, () => {
  assert.doesNotMatch(micBranch, /PermissionResponseAction\.PROMPT/,
    'PROMPT is WebKit\'s own per-site prompt on iOS/macOS, which would ask a '
      + 'second time for a decision the app has already made');
  // The branch must answer, not fall out of the `if` into the camera-only
  // test below it and from there into the PROMPT fallback.
  assert.match(micBranch, /return inapp\.PermissionResponse\(/);
});

test(`${SRC}: the microphone branch is reached before the camera-only one`, () => {
  const micIdx = handler.indexOf('wantsMicrophone || wantsBoth');
  const camIdx = handler.indexOf('wantsCameraOnly');
  const promptIdx = handler.lastIndexOf('PermissionResponseAction.PROMPT');
  assert.notEqual(micIdx, -1);
  assert.notEqual(camIdx, -1);
  assert.ok(micIdx < camIdx,
    'a request carrying MICROPHONE must be answered by the microphone branch, '
      + 'not fall into the camera path');
  assert.ok(camIdx < promptIdx, 'the PROMPT fallback must stay last');
});
