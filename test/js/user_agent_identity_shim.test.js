// Tier 1 — jsdom assertions for the engine-consistent navigator-identity shim
// (lib/services/user_agent_identity_shim.dart, dumped to
// test/js_fixtures/ua_identity/*.js).
//
// The shim forces navigator.vendor / vendorSub / productSub / oscpu /
// buildID / platform to the values the UA's *claimed* engine really emits,
// so a spoofed UA on a mismatched host engine (Gecko UA on iOS WebKit, etc.)
// doesn't leak the real engine. `oscpu` / `buildID` / `userAgentData` are
// presence-sensitive: on the engines that lack them the property must be
// genuinely absent (`in` === false), not defined as undefined.

const test = require('node:test');
const assert = require('node:assert/strict');
const { loadShim } = require('./helpers/load_shim');

const FX_ANDROID = 'ua_identity/firefox_android.js';
const FX_LINUX_DESKTOP = 'ua_identity/firefox_linux_desktop.js';
const FXIOS = 'ua_identity/fxios.js';
const CHROME_ANDROID = 'ua_identity/chrome_android.js';

// --- Gecko mobile (Firefox for Android) ---

test('Firefox-Android: Gecko vendor / productSub', () => {
  const nav = loadShim(FX_ANDROID).window.navigator;
  assert.equal(nav.vendor, '');
  assert.equal(nav.vendorSub, '');
  assert.equal(nav.productSub, '20100101');
});

test('Firefox-Android: Gecko-only oscpu / buildID present with frozen values', () => {
  const dom = loadShim(FX_ANDROID);
  const nav = dom.window.navigator;
  assert.equal('oscpu' in nav, true);
  assert.equal(nav.oscpu, 'Linux armv8l');
  assert.equal('buildID' in nav, true);
  assert.equal(nav.buildID, '20181001000000');
});

test('Firefox-Android: platform is the frozen "Linux armv8l", not the host', () => {
  assert.equal(loadShim(FX_ANDROID).window.navigator.platform, 'Linux armv8l');
});

// --- Gecko desktop (platform owned by desktop_mode_shim, so NOT set here) ---

test('Firefox-desktop: Gecko identity with desktop oscpu, no platform override', () => {
  const dom = loadShim(FX_LINUX_DESKTOP);
  const nav = dom.window.navigator;
  assert.equal(nav.vendor, '');
  assert.equal(nav.productSub, '20100101');
  assert.equal(nav.oscpu, 'Linux x86_64');
  assert.equal(nav.buildID, '20181001000000');
  // No `def('platform', ...)` on the desktop path — desktop_mode_shim owns it.
  const src = require('./helpers/load_shim').readFixture(FX_LINUX_DESKTOP);
  assert.equal(/def\('platform'/.test(src), false);
});

// --- WebKit mobile (Firefox for iOS — Safari-shaped) ---

test('FxiOS: WebKit vendor / productSub', () => {
  const nav = loadShim(FXIOS).window.navigator;
  assert.equal(nav.vendor, 'Apple Computer, Inc.');
  assert.equal(nav.productSub, '20030107');
});

test('FxiOS: oscpu / buildID are ABSENT (in === false), not undefined', () => {
  const nav = loadShim(FXIOS).window.navigator;
  assert.equal('oscpu' in nav, false);
  assert.equal('buildID' in nav, false);
});

test('FxiOS: platform is "iPhone"', () => {
  assert.equal(loadShim(FXIOS).window.navigator.platform, 'iPhone');
});

// --- Blink mobile (Chrome for Android) ---

test('Chrome-Android: Blink vendor / productSub, no oscpu', () => {
  const nav = loadShim(CHROME_ANDROID).window.navigator;
  assert.equal(nav.vendor, 'Google Inc.');
  assert.equal(nav.productSub, '20030107');
  assert.equal('oscpu' in nav, false);
  assert.equal(nav.platform, 'Linux armv8l');
});

test('Chrome-Android: userAgentData is NOT removed (Blink keeps it)', () => {
  // The shim removes userAgentData only for Gecko/WebKit; the Blink fixture
  // must not carry a removeProp('userAgentData') line.
  const src = require('./helpers/load_shim').readFixture(CHROME_ANDROID);
  assert.equal(/removeProp\('userAgentData'\)/.test(src), false);
});

test('FxiOS DOES remove userAgentData (WebKit lacks it)', () => {
  const src = require('./helpers/load_shim').readFixture(FXIOS);
  assert.equal(/removeProp\('userAgentData'\)/.test(src), true);
});

// --- Detection hardening ---

test('identity getters land on Navigator.prototype, not the instance', () => {
  const dom = loadShim(FX_ANDROID);
  const own = Object.getOwnPropertyNames(dom.window.navigator);
  for (const leaked of ['vendor', 'vendorSub', 'productSub', 'oscpu',
                        'buildID', 'platform']) {
    assert.equal(own.includes(leaked), false,
      `${leaked} leaks as own-property: ${JSON.stringify(own)}`);
  }
});

test('identity getters stringify as [native code]', () => {
  const dom = loadShim(FX_ANDROID);
  const desc = Object.getOwnPropertyDescriptor(
    dom.window.Navigator.prototype, 'vendor');
  const s = dom.window.Function.prototype.toString.call(desc.get);
  assert.match(s, /\[native code\]/);
});

test('shim loads cleanly and is idempotent under jsdom', () => {
  const dom = loadShim(FX_ANDROID);
  assert.doesNotThrow(() =>
    dom.window.eval(require('./helpers/load_shim').readFixture(FX_ANDROID)));
  assert.equal(dom.window.navigator.vendor, '');
});
