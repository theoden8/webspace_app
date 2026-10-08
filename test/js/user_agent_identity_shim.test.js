// Tier 1 — jsdom assertions for the engine-consistent navigator-identity shim
// (lib/js/ua_identity.js).
//
// The shim forces navigator.vendor / vendorSub / productSub / oscpu /
// buildID / platform to the values the UA's *claimed* engine really emits,
// so a spoofed UA on a mismatched host engine (Gecko UA on iOS WebKit, etc.)
// doesn't leak the real engine. `oscpu` / `buildID` / `userAgentData` are
// presence-sensitive: on the engines that lack them the property must be
// genuinely absent (`in` === false), not defined as undefined.

const test = require('node:test');
const assert = require('node:assert/strict');
const { loadShim, makeDom, runInDom, pageJs } = require('./helpers/load_shim');

const {
  FX_ANDROID, FX_LINUX_DESKTOP, FXIOS, CHROME_ANDROID,
} = require('./helpers/ua_identities');

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

test('Firefox-desktop: Gecko identity with desktop oscpu and platform', () => {
  const dom = loadShim(FX_LINUX_DESKTOP);
  const nav = dom.window.navigator;
  assert.equal(nav.vendor, '');
  assert.equal(nav.productSub, '20100101');
  assert.equal(nav.oscpu, 'Linux x86_64');
  assert.equal(nav.buildID, '20181001000000');
  // Desktop platform is set here too: worker scopes get this shim but never
  // desktop_mode_shim (window-only), so a desktop-UA worker would otherwise
  // report the host's real platform. Same value desktop_mode_shim uses.
  assert.equal(nav.platform, 'Linux x86_64');
});

test('desktop platform agrees with the desktop-mode shim (no contradiction)', () => {
  const identity = loadShim(FX_LINUX_DESKTOP).window.navigator.platform;
  const desktop = loadShim(pageJs('desktop_mode', { platform: 'Linux x86_64' })).window.navigator.platform;
  assert.equal(identity, desktop);
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

// Whether navigator.userAgentData survives the shim on a host that has it.
function keepsUserAgentData(src) {
  const dom = makeDom();
  Object.defineProperty(dom.window.Navigator.prototype, 'userAgentData', {
    get() { return { brands: [], mobile: true, platform: 'Android' }; },
    configurable: true,
  });
  runInDom(dom, src);
  return 'userAgentData' in dom.window.navigator;
}

test('Chrome-Android: userAgentData is NOT removed (Blink keeps it)', () => {
  assert.equal(keepsUserAgentData(CHROME_ANDROID), true);
});

test('FxiOS DOES remove userAgentData (WebKit lacks it)', () => {
  assert.equal(keepsUserAgentData(FXIOS), false);
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
    dom.window.eval(FX_ANDROID));
  assert.equal(dom.window.navigator.vendor, '');
});
