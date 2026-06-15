#!/usr/bin/env node
// Manual language review for ARB locale files. The CI guard
// (test/js/l10n_language_test.js) checks each file in aggregate; this tool
// adds a --per-string mode to surface individual suspect values for human
// review (the aggregate check can mask a few wrong strings in an otherwise
// correct file).
//
// Usage:
//   node tool/check_l10n_language.js                 # aggregate (whole-file) check, all locales
//   node tool/check_l10n_language.js fr de pt        # only these locales
//   node tool/check_l10n_language.js --per-string    # flag individual untranslated strings
//   node tool/check_l10n_language.js --per-string fr # ... in one locale
//
// Aggregate mode uses CLD3 (whole-file language id). Per-string mode uses
// the untranslated-leftover heuristics in the helper (script-absence for
// non-Latin locales, English-vocabulary match for Latin ones).

const {
  stemOf,
  localeFiles,
  loadDetector,
  verifyLocale,
  suspectStrings,
} = require('../test/js/helpers/l10n_language');

const args = process.argv.slice(2);
const perString = args.includes('--per-string');
const wanted = new Set(args.filter((a) => !a.startsWith('--')));

(async () => {
  const files = localeFiles().filter((f) => wanted.size === 0 || wanted.has(stemOf(f)));

  if (perString) {
    let total = 0;
    for (const file of files) {
      const hits = suspectStrings(file);
      if (!hits.length) continue;
      total += hits.length;
      console.log(`${file}:`);
      for (const { key, value, reason } of hits) {
        console.log(`  [${reason}] ${key}: ${JSON.stringify(value)}`);
      }
    }
    console.log(`\n${total} suspect string(s) across ${files.length} locale(s).`);
    process.exit(total > 0 ? 1 : 0);
  }

  const factory = await loadDetector();
  let failures = 0;
  for (const file of files) {
    const { ok, lang, prob, reliable, accept } = verifyLocale(factory, file);
    if (!ok) failures++;
    console.log(`${ok ? 'ok ' : 'XX '}${file}  ${lang} (p=${prob.toFixed(2)}, reliable=${reliable}, expect ${accept.join('/')})`);
  }
  console.log(`\n${files.length - failures}/${files.length} locales pass aggregate language check.`);
  process.exit(failures > 0 ? 1 : 0);
})();
