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
// Per-string detection on short UI strings is noisy by nature: "OK", "URL",
// brand names, and one-word labels misclassify constantly. Treat the output
// as a review queue, not a pass/fail.

const {
  LATIN,
  ALIAS,
  LID_FLOOR,
  stemOf,
  localeFiles,
  localeValues,
  rankLanguages,
  verifyLocale,
} = require('../test/js/helpers/l10n_language');

const args = process.argv.slice(2);
const perString = args.includes('--per-string');
const wanted = new Set(args.filter((a) => !a.startsWith('--')));

const files = localeFiles().filter((f) => wanted.size === 0 || wanted.has(stemOf(f)));

function perStringReport(file) {
  const stem = stemOf(file);
  if (!(stem in LATIN)) {
    console.log(`  (per-string LID only applies to Latin-script locales; ${stem} is verified by script coverage)`);
    return;
  }
  const expected = ALIAS[stem] || stem.split('_')[0];
  const accept = new Set([expected, ...(LATIN[stem] || [])]);
  let flagged = 0;
  for (const [key, value] of localeValues(file)) {
    const text = value.replace(/\{[^}]*\}/g, ' ').trim();
    if (text.length < 12) continue; // too short to detect reliably
    const ranked = rankLanguages(text);
    const top = ranked[0];
    if (!top) continue;
    const floorHit = ranked.some((d) => d.lang === expected && d.acc >= LID_FLOOR);
    if (!accept.has(top.lang) && !floorHit) {
      flagged++;
      const summary = ranked.slice(0, 2).map((d) => `${d.lang}:${d.acc.toFixed(2)}`).join(', ');
      console.log(`  [${top.lang}] ${key}: ${JSON.stringify(value)}  (${summary})`);
    }
  }
  if (flagged === 0) console.log('  no suspect strings');
}

let failures = 0;
for (const file of files) {
  const { ok, tier, detail } = verifyLocale(file);
  const mark = ok ? 'ok ' : 'XX ';
  if (!ok) failures++;
  console.log(`${mark}${file}  [${tier}] ${detail}`);
  if (perString) perStringReport(file);
}

if (!perString) {
  console.log(`\n${files.length - failures}/${files.length} locales pass aggregate language check.`);
}
process.exit(failures > 0 ? 1 : 0);
