// Behavioural tests for the desktop-mode shim
// (lib/services/desktop_mode_shim.dart).
//
// Goal: prove the shim actually mutates the JS surface a fingerprinter
// would inspect, not just that the source contains the right substrings —
// the existing test/desktop_mode_shim_test.dart already covers string
// matching. These tests run the dumped fixture inside jsdom and assert
// the post-injection navigator/window state.

const test = require('node:test');
const assert = require('node:assert/strict');
const { loadShim, makeDom, runInDom, readFixture } = require('./helpers/load_shim');

test('Linux fixture sets navigator.platform to "Linux x86_64"', () => {
  const dom = loadShim('desktop_mode/linux.js');
  assert.equal(dom.window.navigator.platform, 'Linux x86_64');
});

test('macOS fixture sets navigator.platform to "MacIntel"', () => {
  const dom = loadShim('desktop_mode/macos.js');
  assert.equal(dom.window.navigator.platform, 'MacIntel');
});

test('Windows fixture sets navigator.platform to "Win32"', () => {
  const dom = loadShim('desktop_mode/windows.js');
  assert.equal(dom.window.navigator.platform, 'Win32');
});

test('navigator.userAgentData is undefined (Firefox-shaped UA)', () => {
  const dom = loadShim('desktop_mode/linux.js');
  // Firefox does not implement Client Hints; sites feature-detecting
  // userAgentData must see undefined, not a Chromium-WebView-populated
  // mobile object.
  assert.equal(dom.window.navigator.userAgentData, undefined);
});

test('navigator.maxTouchPoints is forced to 0', () => {
  const dom = loadShim('desktop_mode/linux.js');
  assert.equal(dom.window.navigator.maxTouchPoints, 0);
});

test('window.ontouchstart is undefined after the shim runs', () => {
  const dom = loadShim('desktop_mode/linux.js');
  // The "in" check is what touch detection libraries use.
  assert.equal(dom.window.ontouchstart, undefined);
});

test('matchMedia(pointer: fine) → matches=true; (pointer: coarse) → false', () => {
  const dom = loadShim('desktop_mode/linux.js');
  const fine = dom.window.matchMedia('(pointer: fine)');
  const coarse = dom.window.matchMedia('(pointer: coarse)');
  assert.equal(fine.matches, true, 'pointer: fine should match on desktop');
  assert.equal(coarse.matches, false, 'pointer: coarse should NOT match');
  assert.equal(fine.media, '(pointer: fine)');
});

test('matchMedia(hover: hover) → matches=true; (hover: none) → false', () => {
  const dom = loadShim('desktop_mode/linux.js');
  assert.equal(dom.window.matchMedia('(hover: hover)').matches, true);
  assert.equal(dom.window.matchMedia('(hover: none)').matches, false);
});

test('matchMedia falls through for non-pointer/hover queries', () => {
  // Width-based queries must not be hijacked — the shim must only forge
  // pointer/hover responses, not affect responsive breakpoints.
  const dom = loadShim('desktop_mode/linux.js');
  const result = dom.window.matchMedia('(min-width: 100px)');
  // jsdom's stub returns { matches: false, media }. The shim should leave
  // it alone (and the wrapper doesn't synthesise a response for this
  // query), so we should get the underlying jsdom result back.
  assert.equal(typeof result.matches, 'boolean');
  assert.equal(result.media, '(min-width: 100px)');
});

test('synthetic matchMedia result has addEventListener / removeEventListener', () => {
  // CSS-in-JS libraries (emotion, styled-components media-query helpers)
  // call addEventListener('change', ...) on MediaQueryList. If the
  // synthetic wrapper drops these methods the page throws.
  const dom = loadShim('desktop_mode/linux.js');
  const fine = dom.window.matchMedia('(pointer: fine)');
  assert.equal(typeof fine.addEventListener, 'function');
  assert.equal(typeof fine.removeEventListener, 'function');
  assert.equal(typeof fine.addListener, 'function');
  assert.equal(typeof fine.removeListener, 'function');
  // Should not throw when a listener is attached/detached.
  const listener = () => {};
  fine.addEventListener('change', listener);
  fine.removeEventListener('change', listener);
});

test('existing <meta name="viewport"> is rewritten to width=1366', () => {
  // A site shipping `width=device-width` defeats useWideViewPort. The
  // shim rewrites every viewport meta — including ones present at
  // injection time — to width=1366, initial-scale=1.0. 1366 clears
  // Bluesky's `(min-width: 1300px)` desktop breakpoint; a smaller
  // value would ship the tablet layout on Android.
  const html = `<!doctype html><html><head>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
  </head><body></body></html>`;
  const dom = makeDom({ html });
  runInDom(dom, readFixture('desktop_mode/linux.js'));
  const meta = dom.window.document.querySelector('meta[name="viewport"]');
  assert.ok(meta);
  assert.equal(meta.getAttribute('content'), 'width=1366, initial-scale=1.0');
});

test('viewport meta added later is rewritten via MutationObserver', async () => {
  const dom = loadShim('desktop_mode/linux.js');
  const meta = dom.window.document.createElement('meta');
  meta.setAttribute('name', 'viewport');
  meta.setAttribute('content', 'width=device-width');
  dom.window.document.head.appendChild(meta);
  // MutationObserver callbacks are queued as microtasks. Yield to let
  // them flush.
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(meta.getAttribute('content'), 'width=1366, initial-scale=1.0');
});

test('re-entrance guard: running the shim twice is a no-op', () => {
  // WebKit and Android WebView re-run initialUserScripts on every frame
  // load. Without the __ws_desktop_shim__ guard, the matchMedia wrapper
  // would wrap itself and recurse forever the second time around.
  const dom = loadShim('desktop_mode/linux.js');
  runInDom(dom, readFixture('desktop_mode/linux.js'));
  // matchMedia should still produce the right answer (not blow the stack
  // or return an unexpected shape).
  assert.equal(dom.window.matchMedia('(pointer: fine)').matches, true);
  assert.equal(dom.window.__ws_desktop_shim__, true);
});
