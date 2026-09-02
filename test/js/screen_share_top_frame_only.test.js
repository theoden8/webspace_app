// SHARE-005 — a screen share reaches only the top-level document.
//
// This is the literal "and not to anyone else" property: a third-party frame
// inside a site the user granted (an ad, a payment widget, an embedded chat)
// must not be able to obtain the surface, and must not be able to raise the
// popup in the host site's name either.
//
// Three separate mechanisms carry it, and losing any one of them is silent —
// the app still works, the suite still passes, and a frame quietly gets a
// grant. So each is pinned structurally here:
//
//   1. The shim is injected `forMainFrameOnly: true`, unlike the camera and
//      microphone shims. On Android the plugin implements that by wrapping
//      the source in `if (window === window.top) {...}`; on iOS/macOS WebKit
//      enforces it natively.
//   2. The shim re-reads the same test itself, so the guard survives a
//      platform that stops honouring the flag, and denies BEFORE the bridge
//      is reached (a frame must not be able to raise a popup at all).
//   3. The Dart handler is registered with the frame-aware callback signature
//      and denies `!isMainFrame`. This is the layer that is not in the page's
//      realm: `isMainFrame` is computed by the plugin's own bridge preamble
//      and reaches Dart behind the bridge secret, so page script can neither
//      forge it nor call the handler around it.
//
// The behavioural half lives in test/js/screen_share_shim.test.js, which runs
// the dumped shim inside a real jsdom iframe.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');

function read(rel) {
  return fs.readFileSync(path.join(repoRoot, rel), 'utf8');
}

const webview = read('lib/services/webview.dart');
const shim = read('test/js_fixtures/screen_share/shim.js');

// The `UserScript(...)` block that injects a given shim, by groupName.
function injectionBlock(source, groupName) {
  const at = source.indexOf(`groupName: '${groupName}'`);
  assert.notEqual(at, -1, `no UserScript with groupName '${groupName}'`);
  const end = source.indexOf('));', at);
  assert.notEqual(end, -1, 'unterminated UserScript block');
  return source.slice(at, end);
}

test('the screen-share shim is injected main-frame-only', () => {
  const block = injectionBlock(webview, 'screen_share');
  assert.match(
    block,
    /forMainFrameOnly:\s*true/,
    'forMainFrameOnly:false would install getDisplayMedia in every frame, so ' +
      'a third-party iframe could ask for — and be served — the surface the ' +
      "user granted the host site (SHARE-005).",
  );
});

test('the camera and microphone shims stay all-frames', () => {
  // Not incidental: those two deliberately cover cross-origin iframes (a QR
  // scanner embedded in one). Asserting it here keeps a future "make them
  // consistent" edit from silently narrowing them.
  for (const group of ['camera_stream', 'microphone_stream']) {
    assert.match(injectionBlock(webview, group), /forMainFrameOnly:\s*false/,
      `${group} must keep reaching cross-origin iframes`);
  }
});

test('the shim refuses a subframe on its own, before the bridge', () => {
  assert.match(shim, /globalThis\.top === globalThis/,
    'the shim must re-read the top-frame test rather than trusting the flag');
  const guard = shim.indexOf('if (!IS_TOP)');
  const fetchDecision = shim.indexOf('return fetchDecision()');
  assert.notEqual(guard, -1, 'no IS_TOP guard in getDisplayMedia');
  assert.notEqual(fetchDecision, -1, 'no decision fetch in getDisplayMedia');
  assert.ok(guard < fetchDecision,
    'the subframe deny must come first: a frame that can reach the bridge can ' +
      "raise a popup in the visible site's name.");
});

test('the Dart handler denies a subframe with data the page cannot forge', () => {
  const at = webview.indexOf("handlerName: 'webScreenShareRequest'");
  assert.notEqual(at, -1, 'the screen-share bridge handler is not registered');
  const block = webview.slice(at, at + 900);
  assert.match(
    block,
    /callback:\s*\(inapp\.JavaScriptHandlerFunctionData data\)/,
    'the handler must take the frame-aware callback signature; the plain ' +
      '(args) one cannot see which frame called, so the deny would exist ' +
      'only in the page\'s own realm.',
  );
  const denyAt = block.indexOf('if (!data.isMainFrame)');
  const resolveAt = block.indexOf('onScreenShareDecision!');
  assert.notEqual(denyAt, -1, 'no !isMainFrame deny in the handler');
  assert.notEqual(resolveAt, -1, 'the handler never resolves a decision');
  assert.ok(denyAt < resolveAt,
    'the deny must precede the resolver, which is what shows the popup');
  assert.match(block, /ScreenShareDecision\.block\(\)\.toBridgeJson\(\)/,
    'a denied frame must get the block payload, not a partial answer');
});
