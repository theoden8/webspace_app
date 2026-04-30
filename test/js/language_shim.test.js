// Tier 1 — jsdom assertions for the language shim
// (lib/services/language_shim.dart, dumped to test/js_fixtures/language/*.js).
//
// jsdom default navigator.language is 'en-US'; the shim must override
// that on Navigator.prototype, override navigator.languages with a
// frozen array, and shim Intl.DateTimeFormat.prototype.resolvedOptions
// to report the spoofed locale.

const test = require('node:test');
const assert = require('node:assert/strict');
const { loadShim } = require('./helpers/load_shim');

test('en fixture: navigator.language is "en"', () => {
  const dom = loadShim('language/en.js');
  assert.equal(dom.window.navigator.language, 'en');
});

test('fr-FR fixture: navigator.language is "fr-FR"', () => {
  const dom = loadShim('language/fr_FR.js');
  assert.equal(dom.window.navigator.language, 'fr-FR');
});

test('ja fixture: navigator.language is "ja"', () => {
  const dom = loadShim('language/ja.js');
  assert.equal(dom.window.navigator.language, 'ja');
});

test('navigator.languages is a single-element array of the spoofed lang', () => {
  const dom = loadShim('language/fr_FR.js');
  const langs = dom.window.navigator.languages;
  assert.deepEqual(Array.from(langs), ['fr-FR']);
  assert.equal(langs.length, 1);
});

test('navigator.languages is frozen — sites cannot mutate the array', () => {
  // Object.freeze in the shim guards against pages that prepend their
  // own preferred lang to navigator.languages.
  const dom = loadShim('language/en.js');
  const langs = dom.window.navigator.languages;
  assert.equal(Object.isFrozen(langs), true);
});

test('Intl.DateTimeFormat().resolvedOptions().locale reports spoofed lang', () => {
  // jsdom ships a real Intl (Node's), so this is a meaningful test
  // even at Tier 1.
  const dom = loadShim('language/ja.js');
  const locale = new dom.window.Intl.DateTimeFormat().resolvedOptions().locale;
  assert.equal(locale, 'ja');
});

test('shim defines language on Navigator.prototype, not the instance', () => {
  // A clean navigator carries `language` on Navigator.prototype only;
  // if we leaked `language` as an own-property of navigator a
  // fingerprinter could detect the spoof. Assert the shim hits the
  // prototype (it does, per the source).
  const dom = loadShim('language/en.js');
  const own = Object.getOwnPropertyNames(dom.window.navigator);
  assert.equal(own.includes('language'), false,
    `language leaks as own-property: ${JSON.stringify(own)}`);
  assert.equal(own.includes('languages'), false);
});

test('shim does not throw on a navigator without writable getters', () => {
  // The shim wraps the whole body in try/catch. Sanity: the fixture
  // loads cleanly under jsdom even though jsdom's Navigator
  // implementation differs from real Chromium.
  assert.doesNotThrow(() => loadShim('language/en.js'));
});
