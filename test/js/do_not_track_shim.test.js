// Tier 1 — jsdom assertions for the always-on Do Not Track / Global
// Privacy Control shim (lib/services/do_not_track_shim.dart, dumped to
// test/js_fixtures/do_not_track/shim.js).
//
// Fingerprinting probes look at:
//   - navigator.doNotTrack ('1' = opt out per the WHATWG draft)
//   - navigator.msDoNotTrack (legacy IE / pre-Chromium Edge)
//   - window.doNotTrack (legacy Safari / old Firefox)
//   - navigator.globalPrivacyControl (modern GPC standard, true = opt out)
// All four must read as opt-out and must not appear as own-properties of
// `navigator` (a leak that would tell a fingerprinter the override is JS,
// not native).

const test = require('node:test');
const assert = require('node:assert/strict');
const { loadShim } = require('./helpers/load_shim');

test('navigator.doNotTrack is "1"', () => {
  const dom = loadShim('do_not_track/shim.js');
  assert.equal(dom.window.navigator.doNotTrack, '1');
});

test('navigator.msDoNotTrack is "1"', () => {
  const dom = loadShim('do_not_track/shim.js');
  assert.equal(dom.window.navigator.msDoNotTrack, '1');
});

test('window.doNotTrack is "1"', () => {
  const dom = loadShim('do_not_track/shim.js');
  assert.equal(dom.window.doNotTrack, '1');
});

test('navigator.globalPrivacyControl is true', () => {
  const dom = loadShim('do_not_track/shim.js');
  assert.equal(dom.window.navigator.globalPrivacyControl, true);
});

test('overrides hit Navigator.prototype, not the navigator instance', () => {
  // Defining `doNotTrack` directly on `navigator` would leak it as an
  // own-property — a fingerprinter could enumerate own-properties and
  // detect the override. The shim defines getters on Navigator.prototype.
  const dom = loadShim('do_not_track/shim.js');
  const own = Object.getOwnPropertyNames(dom.window.navigator);
  assert.equal(own.includes('doNotTrack'), false,
    `doNotTrack leaks as own-property: ${JSON.stringify(own)}`);
  assert.equal(own.includes('msDoNotTrack'), false);
  assert.equal(own.includes('globalPrivacyControl'), false);
});

test('shim does not throw under jsdom', () => {
  // The body is wrapped in try/catch so a missing API can never break
  // page boot. Sanity-check that the fixture loads cleanly.
  assert.doesNotThrow(() => loadShim('do_not_track/shim.js'));
});

test('properties read consistently across multiple accesses', () => {
  // A getter that returns different values on repeated access would let
  // a fingerprinter identify the shim. Confirm the getter is stable.
  const dom = loadShim('do_not_track/shim.js');
  const a = dom.window.navigator.doNotTrack;
  const b = dom.window.navigator.doNotTrack;
  const c = dom.window.navigator.globalPrivacyControl;
  const d = dom.window.navigator.globalPrivacyControl;
  assert.equal(a, b);
  assert.equal(c, d);
});
