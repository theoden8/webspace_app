#!/usr/bin/env node
// Manual language review for ARB locale files. The CI guard
// (test/js/l10n_language_test.js) checks each file in aggregate; this tool
// adds a --per-string mode to surface individual suspect values for human
// review (the aggregate check can mask a few wrong strings in an otherwise
// correct file).
//
// Usage:
//   node tool/check_l10n_language.js                 # aggregate summary, all locales
//   node tool/check_l10n_language.js fr de pt        # only these locales
//   node tool/check_l10n_language.js --per-string fr # flag suspect strings in fr
//
// Per-string detection on short UI strings is unreliable by nature: "OK",
// "URL", brand names, and one-word labels carry too little signal. CLD3's
// is_reliable flag filters most of that out, but treat the output as a
// review queue, not pass/fail.

const {
  stemOf,
  acceptedCodes,
  localeFiles,
  localeValues,
  loadDetector,
  verifyLocale,
} = require('../test/js/helpers/l10n_language');

const args = process.argv.slice(2);
const perString = args.includes('--per-string');
const wanted = new Set(args.filter((a) => !a.startsWith('--')));

function perStringReport(factory, file) {
  const accept = acceptedCodes(stemOf(file));
  let flagged = 0;
  for (const [key, value] of localeValues(file)) {
    const text = value.replace(/\{[^}]*\}/g, ' ').trim();
    if (text.length < 12) continue; // too short to detect reliably
    const detector = factory.create();
    const r = detector.findLanguage(text);
    detector.dispose && detector.dispose();
    if (r.is_reliable && !accept.includes(r.language)) {
      flagged++;
      console.log(`  [${r.language} ${r.probability.toFixed(2)}] ${key}: ${JSON.stringify(value)}`);
    }
  }
  if (flagged === 0) console.log('  no suspect strings');
}

(async () => {
  const factory = await loadDetector();
  const files = localeFiles().filter((f) => wanted.size === 0 || wanted.has(stemOf(f)));
  let failures = 0;
  for (const file of files) {
    const { ok, lang, prob, reliable, accept } = verifyLocale(factory, file);
    if (!ok) failures++;
    console.log(`${ok ? 'ok ' : 'XX '}${file}  ${lang} (p=${prob.toFixed(2)}, reliable=${reliable}, expect ${accept.join('/')})`);
    if (perString) perStringReport(factory, file);
  }
  if (!perString) {
    console.log(`\n${files.length - failures}/${files.length} locales pass aggregate language check.`);
  }
  process.exit(failures > 0 ? 1 : 0);
})();
