// Shared language-identity logic for the ARB locale files, used by both the
// CI guard (test/js/l10n_language_test.js) and the manual per-string review
// tool (tool/check_l10n_language.js).
//
// No VRAM / no network. Two verification tiers, picked per locale:
//
//   1. SCRIPT tier (non-Latin languages) - high confidence, zero upkeep.
//      Most of the file's letters must fall in the language's Unicode
//      block(s). A file left in English scores ~0% target script and
//      fails. For shared-script languages (hi/mr/ne all Devanagari,
//      bg/mk/uk/sr/mn all Cyrillic) this proves the *script*, not the
//      exact language - tinyld can't separate close siblings either.
//
//   2. LID tier (Latin-script languages) - statistical n-gram detection
//      via tinyld. Latin UI strings are short and noisy (Swedish reads as
//      Esperanto, Afrikaans as English), so we accept the expected
//      language appearing anywhere above a floor, plus a per-locale
//      sibling allowlist where tinyld lacks the language (Croatian->sr,
//      Malay->id, ...). A handful tinyld can only return noise for
//      (cy/eu/mt/sq) get the weakest check: must not read as confident
//      English.

const fs = require('node:fs');
const path = require('node:path');
const { detectAll, toISO2 } = require('tinyld');

const arbDir = path.resolve(__dirname, '..', '..', '..', 'lib', 'l10n');

// Non-Latin locales -> Unicode script block(s) their letters must occupy.
const SCRIPTS = {
  am: ['Ethiopic'], ar: ['Arabic'], bg: ['Cyrillic'], bn: ['Bengali'],
  el: ['Greek'], fa: ['Arabic'], gu: ['Gujarati'], he: ['Hebrew'],
  hi: ['Devanagari'], hy: ['Armenian'], ja: ['Kana', 'Han'], ka: ['Georgian'],
  km: ['Khmer'], kn: ['Kannada'], ko: ['Hangul'], mk: ['Cyrillic'],
  ml: ['Malayalam'], mn: ['Cyrillic'], mr: ['Devanagari'], ne: ['Devanagari'],
  pa: ['Gurmukhi'], si: ['Sinhala'], sr: ['Cyrillic'], ta: ['Tamil'],
  te: ['Telugu'], th: ['Thai'], uk: ['Cyrillic'], ur: ['Arabic'],
  zh: ['Han'], zh_Hant: ['Han'],
};

// Latin-script locales. Value = extra detected ISO-639-1 codes accepted as
// the top result besides the expected one (siblings tinyld confuses or
// outright lacks). Empty array = expected language only.
const LATIN = {
  af: [], cs: [], da: [], de: [], en: [], es: [], et: [], fi: [], fil: [],
  fr: [], ga: [], hu: [], id: [], is: [], it: [], la: [], lt: [], lv: [],
  nb: [], nl: [], pl: [], pt: [], pt_BR: [], ro: [], sk: [], sv: [], tr: [],
  // tinyld has no model for these; nearest sibling dominates.
  bs: ['sr'], ca: ['es', 'pt'], gl: ['es', 'pt'], hr: ['sr'], ms: ['id'],
  sl: ['sr', 'hr'], sw: ['rn'],
};

// tinyld returns noise for these (Welsh->ber, Maltese->pl, Albanian->nl,
// Basque->ber). Only assert "not confident English" - the best a non-VRAM
// detector can do for them.
const WEAK = new Set(['cy', 'eu', 'mt', 'sq']);

// Locale stem -> tinyld's code for the language, when it differs from the
// stem (Filipino is Tagalog; Bokmal is generic Norwegian).
const ALIAS = { fil: 'tl', nb: 'no' };

const SCRIPT_RANGES = {
  Latin: /[A-Za-zÀ-ɏ]/g,
  Cyrillic: /[Ѐ-ӿ]/g,
  Greek: /[Ͱ-Ͽ]/g,
  Arabic: /[؀-ۿݐ-ݿ]/g,
  Hebrew: /[֐-׿]/g,
  Devanagari: /[ऀ-ॿ]/g,
  Bengali: /[ঀ-৿]/g,
  Gujarati: /[઀-૿]/g,
  Gurmukhi: /[਀-੿]/g,
  Tamil: /[஀-௿]/g,
  Telugu: /[ఀ-౿]/g,
  Kannada: /[ಀ-೿]/g,
  Malayalam: /[ഀ-ൿ]/g,
  Sinhala: /[඀-෿]/g,
  Thai: /[฀-๿]/g,
  Khmer: /[ក-៿]/g,
  Georgian: /[Ⴀ-ჿ]/g,
  Armenian: /[԰-֏]/g,
  Ethiopic: /[ሀ-፿]/g,
  Hangul: /[가-힣ᄀ-ᇿ]/g,
  Han: /[一-鿿]/g,
  Kana: /[぀-ヿ]/g,
};

// Letters of the expected script must be at least this share of all
// alphabetic characters (target script + Latin). Brand names ("WebSpace"),
// URLs, and technical terms keep real files well above this; the lowest
// observed is Khmer at 0.66.
const SCRIPT_MIN = 0.5;
// In the LID tier, the expected language passing this accuracy anywhere in
// the ranked results rescues languages tinyld ranks below a sibling
// (Afrikaans, Bokmal, Swedish).
const LID_FLOOR = 0.15;
const ENGLISH_MAX = 0.5;

const stemOf = (file) => file.slice('app_'.length, -'.arb'.length);

function localeFiles() {
  return fs.readdirSync(arbDir).filter((f) => f.endsWith('.arb')).sort();
}

function localeValues(file) {
  const json = JSON.parse(fs.readFileSync(path.join(arbDir, file), 'utf8'));
  return Object.entries(json)
    .filter(([k]) => !k.startsWith('@'))
    .map(([k, v]) => [k, typeof v === 'string' ? v : '']);
}

function localeText(file) {
  return localeValues(file)
    .map(([, v]) => v)
    .join(' ')
    .replace(/\{[^}]*\}/g, ' '); // drop {placeholder} tokens
}

function countMatches(text, re) {
  return (text.match(re) || []).length;
}

function rankLanguages(text) {
  return detectAll(text).map((d) => ({ lang: toISO2(d.lang) || d.lang, acc: d.accuracy }));
}

function unclassifiedStems() {
  return localeFiles()
    .map(stemOf)
    .filter((s) => s !== 'en' && !(s in SCRIPTS) && !(s in LATIN) && !WEAK.has(s));
}

// Returns { ok, tier, detail } for one locale file's aggregate text.
function verifyLocale(file) {
  const stem = stemOf(file);
  const text = localeText(file);

  if (stem in SCRIPTS) {
    const latin = countMatches(text, SCRIPT_RANGES.Latin);
    let expected = 0;
    for (const block of SCRIPTS[stem]) expected += countMatches(text, SCRIPT_RANGES[block]);
    const ratio = expected / (expected + latin || 1);
    return {
      ok: ratio >= SCRIPT_MIN,
      tier: 'script',
      detail: `${(ratio * 100).toFixed(0)}% ${SCRIPTS[stem].join('/')} (need >=${SCRIPT_MIN * 100}%)`,
    };
  }

  const ranked = rankLanguages(text);
  const top = ranked[0] || { lang: '?', acc: 0 };
  const summary = ranked.slice(0, 3).map((d) => `${d.lang}:${d.acc.toFixed(2)}`).join(', ');

  if (WEAK.has(stem)) {
    const english = ranked.find((d) => d.lang === 'en');
    return {
      ok: top.lang !== 'en' && (!english || english.acc < ENGLISH_MAX),
      tier: 'weak',
      detail: `unverifiable directly; reads as [${summary}]`,
    };
  }

  const expected = ALIAS[stem] || stem.split('_')[0];
  const accept = new Set([expected, ...(LATIN[stem] || [])]);
  const floorHit = ranked.some((d) => d.lang === expected && d.acc >= LID_FLOOR);
  return {
    ok: accept.has(top.lang) || floorHit,
    tier: 'lid',
    detail: `detected [${summary}], expected ${[...accept].join('/')}`,
  };
}

module.exports = {
  arbDir,
  SCRIPTS,
  LATIN,
  WEAK,
  ALIAS,
  LID_FLOOR,
  stemOf,
  localeFiles,
  localeValues,
  localeText,
  rankLanguages,
  unclassifiedStems,
  verifyLocale,
};
