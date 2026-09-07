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
//   - it must ask the RESOLVER, not read a mode off a model. The resolver is
//     what applies the on-screen gate (MIC-011) and the archive-tier fold
//     (MIC-006); a branch that read `microphoneMode` directly would grant a
//     backgrounded or archived site and every existing test would stay green.
//   - it must require `MicrophoneAccessMode.real`, not merely a decision.
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
const fs = require('node:fs');
const path = require('node:path');
const { blockAfter } = require('./helpers/dart_blocks');

const repoRoot = path.resolve(__dirname, '..', '..');
const SRC = 'lib/services/webview.dart';
const src = fs.readFileSync(path.join(repoRoot, SRC), 'utf8');

// Prose in the comment block above the handler names every symbol asserted
// below, so the checks have to run against code alone.
function stripComments(text) {
  let out = '';
  let str = null;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    const c2 = text[i + 1];
    if (str) {
      out += c;
      if (c === '\\') { out += (c2 ?? ''); i++; continue; }
      if (c === str) str = null;
      continue;
    }
    if (c === '/' && c2 === '/') {
      while (i < text.length && text[i] !== '\n') i++;
      out += '\n';
      continue;
    }
    if (c === '"' || c === "'") { str = c; out += c; continue; }
    out += c;
  }
  return out;
}

// The handler body, comments removed. `onPermissionRequest:` opens with a
// ternary guard, so the block starts at the `async {` of the callback.
const handler = stripComments(
  blockAfter(src, 'onPermissionRequest: ((', '(controller, request) async {', SRC));

// The microphone branch: from the `wantsMicrophone` test to the end of the
// `if` that answers it.
const micBranch = blockAfter(handler, 'if (wantsMicrophone || wantsBoth)', null,
  `${SRC} microphone branch`);

test(`${SRC}: the microphone grant goes through the resolver`, () => {
  assert.match(micBranch, /config\.onMicrophoneDecision!\(/,
    'the branch must ask the resolver, which is what applies the on-screen '
      + 'gate (MIC-011) and the archive-tier fold (MIC-006)');
  assert.doesNotMatch(micBranch, /\bmicrophoneMode\b/,
    'reading the stored mode directly bypasses both gates');
});

test(`${SRC}: a microphone grant requires the real mode`, () => {
  assert.match(micBranch, /MicrophoneAccessMode\.real/,
    'GRANT must be conditioned on the decision being `real`');
  const grantIdx = micBranch.indexOf('PermissionResponseAction.GRANT');
  assert.notEqual(grantIdx, -1, 'the branch must still be able to grant');
  assert.ok(
    micBranch.indexOf('MicrophoneAccessMode.real') < grantIdx,
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
  assert.match(micBranch, /CameraAccessMode\.real/,
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
