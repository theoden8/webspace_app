// Tier 1 — jsdom assertions for the theme/color-scheme shim
// (lib/services/theme_color_scheme_shim.dart, dumped to
// test/js_fixtures/theme_color_scheme/*.js).
//
// jsdom's matchMedia is a stub returning {matches:false} for every
// query (see helpers/load_shim.js). The shim wraps matchMedia, so we
// can still assert the prefers-color-scheme branches return the
// shim-decided value rather than the underlying jsdom stub. Real CSS
// engine behaviour is asserted at Tier 2.

const test = require('node:test');
const assert = require('node:assert/strict');
const { loadShim } = require('./helpers/load_shim');

test('dark fixture: matchMedia(prefers-color-scheme: dark) → matches=true', () => {
  const dom = loadShim('theme_color_scheme/dark.js');
  assert.equal(
    dom.window.matchMedia('(prefers-color-scheme: dark)').matches, true);
  assert.equal(
    dom.window.matchMedia('(prefers-color-scheme: light)').matches, false);
});

test('light fixture: matchMedia(prefers-color-scheme: light) → matches=true', () => {
  const dom = loadShim('theme_color_scheme/light.js');
  assert.equal(
    dom.window.matchMedia('(prefers-color-scheme: light)').matches, true);
  assert.equal(
    dom.window.matchMedia('(prefers-color-scheme: dark)').matches, false);
});

test('system fixture: resolves to host preference at install time', () => {
  // jsdom's matchMedia stub returns {matches:false} for every query,
  // so prefers-color-scheme: dark is false → resolved theme is light.
  // The Tier 2 test exercises the real-engine resolution path.
  const dom = loadShim('theme_color_scheme/system.js');
  assert.equal(dom.window.__appThemePreference, 'light');
  assert.equal(
    dom.window.matchMedia('(prefers-color-scheme: light)').matches, true);
});

test('non-color-scheme matchMedia queries fall through to the wrapper', () => {
  // The shim only forges prefers-color-scheme answers; width-based
  // and other queries must defer to the real (or jsdom-stub) matchMedia.
  const dom = loadShim('theme_color_scheme/dark.js');
  const r = dom.window.matchMedia('(min-width: 100px)');
  // jsdom polyfill returns {matches:false}; the wrapper must propagate
  // that without synthesising a fake answer.
  assert.equal(typeof r.matches, 'boolean');
  assert.equal(r.media, '(min-width: 100px)');
});

test('shim creates <meta name="color-scheme"> with the resolved theme', () => {
  const dom = loadShim('theme_color_scheme/dark.js');
  const meta = dom.window.document.querySelector('meta[name="color-scheme"]');
  assert.ok(meta, 'meta tag must be created');
  assert.equal(meta.getAttribute('content'), 'dark');
});

test('shim sets documentElement.style.colorScheme', () => {
  const dom = loadShim('theme_color_scheme/light.js');
  assert.equal(dom.window.document.documentElement.style.colorScheme, 'light');
});

test('synthetic MediaQueryList carries addEventListener / removeEventListener', () => {
  const dom = loadShim('theme_color_scheme/dark.js');
  const mql = dom.window.matchMedia('(prefers-color-scheme: dark)');
  assert.equal(typeof mql.addEventListener, 'function');
  assert.equal(typeof mql.removeEventListener, 'function');
  assert.equal(typeof mql.addListener, 'function');
  assert.equal(typeof mql.removeListener, 'function');
});

test('addEventListener registers a change listener for theme flips', () => {
  const dom = loadShim('theme_color_scheme/dark.js');
  const mql = dom.window.matchMedia('(prefers-color-scheme: dark)');
  let called = 0;
  mql.addEventListener('change', () => { called++; });
  // The shim queues listeners on window.__themeChangeListeners and
  // fires them when the theme changes (driven by re-injection in
  // production). Verify the queue picked up the listener.
  assert.equal(dom.window.__themeChangeListeners.length, 1);
  assert.equal(dom.window.__themeChangeListeners[0].query,
    '(prefers-color-scheme: dark)');
});

test('removeEventListener unregisters a previously added change listener', () => {
  const dom = loadShim('theme_color_scheme/dark.js');
  const mql = dom.window.matchMedia('(prefers-color-scheme: dark)');
  const listener = () => {};
  mql.addEventListener('change', listener);
  assert.equal(dom.window.__themeChangeListeners.length, 1);
  mql.removeEventListener('change', listener);
  assert.equal(dom.window.__themeChangeListeners.length, 0);
});
