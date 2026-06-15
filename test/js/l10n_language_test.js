// Verifies each ARB locale file is actually written in the language its
// filename claims (LOC: language-identity guard). Complements
// test/l10n_coverage_test.dart (key/placeholder parity) and catches the
// failure mode of the "hand app_en.arb to a general model" translation
// workflow: a locale coming back still in English, truncated, or with two
// languages swapped.
//
// Verification logic lives in helpers/l10n_language.js (shared with the
// per-string review tool tool/check_l10n_language.js); see that file for
// the two-tier (script / LID) strategy and per-locale notes.

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  localeFiles,
  stemOf,
  unclassifiedStems,
  verifyLocale,
} = require('./helpers/l10n_language');

test('every locale file is classified (script or LID tier)', () => {
  const unclassified = unclassifiedStems();
  assert.deepEqual(
    unclassified,
    [],
    `New locale(s) ${unclassified.join(', ')} must be added to SCRIPTS, LATIN, or WEAK in test/js/helpers/l10n_language.js.`,
  );
});

for (const file of localeFiles()) {
  test(`${file} is written in ${stemOf(file)}`, () => {
    const { ok, detail } = verifyLocale(file);
    assert.ok(ok, `${file}: ${detail}. Likely untranslated or wrong language.`);
  });
}
