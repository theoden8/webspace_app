// Verifies each ARB locale file is actually written in the language its
// filename claims (LOC: language-identity guard). Complements
// test/l10n_coverage_test.dart (key/placeholder parity) and catches the
// failure mode of the "hand app_en.arb to a general model" translation
// workflow: a locale coming back still in English, truncated, or with two
// languages swapped.
//
// Detection logic lives in helpers/l10n_language.js (shared with the
// per-string review tool tool/check_l10n_language.js); see that file for
// the CLD3-based approach and the per-locale code notes.

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  localeFiles,
  acceptedCodes,
  loadDetector,
  verifyLocale,
} = require('./helpers/l10n_language');

test('locale files are written in their claimed language', async () => {
  const factory = await loadDetector();
  for (const file of localeFiles()) {
    const { ok, lang, prob, reliable, accept } = verifyLocale(factory, file);
    assert.ok(
      ok,
      `${file}: detected ${lang} (p=${prob.toFixed(2)}, reliable=${reliable}), expected ${accept.join('/')}. Likely untranslated or wrong language.`,
    );
  }
});

// Negative control: the English source detects as English, which is not in
// any non-English locale's accepted set. Guards against a future dependency
// bump that neuters detection (always-reliable / always-matches) passing
// silently.
test('detector flags English text against a non-English locale', async () => {
  const factory = await loadDetector();
  const { lang } = verifyLocale(factory, 'app_en.arb');
  assert.equal(lang, 'en');
  for (const stem of ['fr', 'de', 'es', 'ja', 'ar']) {
    assert.ok(
      !acceptedCodes(stem).includes('en'),
      `${stem} must not accept English; detection guard would be defeated.`,
    );
  }
});
