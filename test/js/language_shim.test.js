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

// --- Actual formatting locale (not just the resolvedOptions label) ---
// The whole point of the rewrite: a locale-less Intl formatter must FORMAT
// in the per-site language, not merely report it. Node is full-ICU so the
// output is real.

test('locale-less Intl.NumberFormat FORMATS in the spoofed language', () => {
  const fr = loadShim('language/fr_FR.js');
  // French uses a comma decimal separator; English a dot. If only the label
  // were spoofed (the old bug) this would still format as "0.5".
  assert.equal(new fr.window.Intl.NumberFormat().format(0.5), '0,5');
  const en = loadShim('language/en.js');
  assert.equal(new en.window.Intl.NumberFormat().format(0.5), '0.5');
});

test('locale-less Intl.DateTimeFormat FORMATS month names in the spoofed language', () => {
  const july = Date.UTC(2020, 6, 1);
  const fr = loadShim('language/fr_FR.js');
  const frMonth = new fr.window.Intl.DateTimeFormat(undefined, {
    timeZone: 'UTC', month: 'long',
  }).format(new fr.window.Date(july));
  assert.equal(frMonth, 'juillet');
  const ja = loadShim('language/ja.js');
  const jaMonth = new ja.window.Intl.DateTimeFormat(undefined, {
    timeZone: 'UTC', month: 'long',
  }).format(new ja.window.Date(july));
  assert.equal(jaMonth, '7月');
});

test('Intl.NumberFormat / RelativeTimeFormat resolvedOptions locale is spoofed', () => {
  const dom = loadShim('language/fr_FR.js');
  assert.equal(new dom.window.Intl.NumberFormat().resolvedOptions().locale, 'fr-FR');
  assert.equal(
    new dom.window.Intl.RelativeTimeFormat().resolvedOptions().locale, 'fr-FR');
});

test('an EXPLICIT locale argument is honoured, not overridden', () => {
  // We only inject the default when the caller omits locales. A site that
  // explicitly asks for German must still get German — anything else would
  // be a new (and detectable) lie.
  const dom = loadShim('language/fr_FR.js');
  const loc = new dom.window.Intl.NumberFormat('de-DE').resolvedOptions().locale;
  assert.equal(loc, 'de-DE');
  assert.equal(new dom.window.Intl.NumberFormat('de-DE').format(0.5), '0,5');
  assert.equal(new dom.window.Intl.NumberFormat('en-US').format(1000), '1,000');
});

test('Date.prototype.toLocaleDateString with no locale uses the spoofed lang', () => {
  const fr = loadShim('language/fr_FR.js');
  const s = new fr.window.Date(Date.UTC(2020, 6, 1)).toLocaleDateString(undefined, {
    timeZone: 'UTC', month: 'long',
  });
  assert.equal(s, 'juillet');
});

test('Number.prototype.toLocaleString with no args uses the spoofed lang', () => {
  const fr = loadShim('language/fr_FR.js');
  // Evaluate inside the jsdom realm so the patched Number.prototype is used.
  assert.equal(fr.window.eval('(0.5).toLocaleString()'), '0,5');
});

test('re-running the shim does not compound (idempotent)', () => {
  const dom = loadShim('language/fr_FR.js');
  dom.window.eval(require('./helpers/load_shim').readFixture('language/fr_FR.js'));
  assert.equal(new dom.window.Intl.NumberFormat().format(0.5), '0,5');
  assert.equal(dom.window.navigator.language, 'fr-FR');
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
