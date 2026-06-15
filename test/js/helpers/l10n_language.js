// Shared language-identity logic for the ARB locale files, used by both the
// CI guard (test/js/l10n_language_test.js) and the manual per-string review
// tool (tool/check_l10n_language.js).
//
// Detection uses CLD3 (Google's Compact Language Detector v3) via cld3-asm,
// a pure-WASM build: no native compile, no model download, no VRAM. CLD3
// reliably identifies all locales the app ships (Latin and non-Latin alike,
// including low-resource ones like Welsh/Basque/Maltese/Albanian that
// trigram detectors miss), so no Unicode-script fallback or sibling
// allowlist is needed beyond the three benign deviations below.
//
// Catches the failure mode of the "hand app_en.arb to a general model"
// translation workflow: a locale coming back still in English, truncated,
// or with two languages swapped - which key/placeholder parity can't see.

const fs = require('node:fs');
const path = require('node:path');
const { loadModule } = require('cld3-asm');

const arbDir = path.resolve(__dirname, '..', '..', '..', 'lib', 'l10n');

// Locale stem -> acceptable CLD3 language codes, when they differ from the
// region-stripped stem:
//   he  -> CLD3 emits the legacy ISO-639-1 code "iw" for Hebrew.
//   nb  -> Bokmal is reported as the Norwegian macrolanguage "no".
//   bs  -> Bosnian/Croatian/Serbian (Latin) are one dialect continuum;
//          CLD3 cannot separate Bosnian from Croatian. Accept the siblings.
const ACCEPT = {
  he: ['he', 'iw'],
  nb: ['nb', 'no'],
  bs: ['bs', 'hr', 'sr'],
};

const stemOf = (file) => file.slice('app_'.length, -'.arb'.length);

// Region-stripped expected code: pt_BR -> pt, zh_Hant -> zh.
const expectedCode = (stem) => stem.split('_')[0];

function acceptedCodes(stem) {
  return ACCEPT[stem] || [expectedCode(stem)];
}

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

// --- Per-string check -------------------------------------------------
//
// CLD3 is reliable on a whole file but not on a single short UI string
// (it returns "und" for clear English and confident wrong guesses for
// short non-Latin text), so per-string review uses cheaper, higher-signal
// heuristics targeting the one realistic per-string failure: a value left
// untranslated (i.e. in English) when its neighbours were translated.
//
//   - Non-Latin locale: any value that has NO character in the expected
//     script but >=3 Latin words is untranslated. (Brand/acronym tokens
//     like "URL", "SHA-256" are 1-2 words and pass.)
//   - Latin locale: a value whose words are almost all English-source
//     vocabulary AND contains an unambiguous English stopword (the, and,
//     with, that, ... - words that effectively never occur in the other
//     shipped languages). Catches English left in a Latin-script locale
//     without flagging real translations that reuse a technical noun.

const SCRIPTS = {
  am: ['Ethiopic'], ar: ['Arabic'], bg: ['Cyrillic'], bn: ['Bengali'],
  el: ['Greek'], fa: ['Arabic'], gu: ['Gujarati'], he: ['Hebrew'],
  hi: ['Devanagari'], hy: ['Armenian'], ja: ['Kana', 'Han'], ka: ['Georgian'],
  km: ['Khmer'], kn: ['Kannada'], ko: ['Hangul'], mk: ['Cyrillic'],
  ml: ['Malayalam'], mn: ['Cyrillic'], mr: ['Devanagari'], ne: ['Devanagari'],
  pa: ['Gurmukhi'], si: ['Sinhala'], sr: ['Cyrillic'], ta: ['Tamil'],
  te: ['Telugu'], th: ['Thai'], uk: ['Cyrillic'], ur: ['Arabic'],
  zh: ['Han'], zh_Hant: ['Han', 'Kana'],
};

const SCRIPT_RANGES = {
  Cyrillic: /[Ѐ-ӿ]/, Greek: /[Ͱ-Ͽ]/, Arabic: /[؀-ۿݐ-ݿ]/, Hebrew: /[֐-׿]/,
  Devanagari: /[ऀ-ॿ]/, Bengali: /[ঀ-৿]/, Gujarati: /[઀-૿]/, Gurmukhi: /[਀-੿]/,
  Tamil: /[஀-௿]/, Telugu: /[ఀ-౿]/, Kannada: /[ಀ-೿]/, Malayalam: /[ഀ-ൿ]/,
  Sinhala: /[඀-෿]/, Thai: /[฀-๿]/, Khmer: /[ក-៿]/, Georgian: /[Ⴀ-ჿ]/,
  Armenian: /[԰-֏]/, Ethiopic: /[ሀ-፿]/, Hangul: /[가-힣ᄀ-ᇿ]/, Han: /[一-鿿]/,
  Kana: /[぀-ヿ]/,
};

// English function words with effectively no collision in the other shipped
// languages (excludes "to"/"for"/"have"/"den" which are real words in
// Danish/Czech/Polish/Dutch).
const STOP_WORDS = new Set(
  ('the and with this that from your which there would these because through '
  + 'between whether while about should could their they what when into more '
  + 'such only other also').split(' '),
);

const cleanValue = (v) => v.replace(/\{[^}]*\}/g, ' ').replace(/[a-z]+:\/\/\S+/gi, ' ');
const wordsOf = (v) => (cleanValue(v).toLowerCase().match(/[a-zà-ÿ]{2,}/gi) || []).map((w) => w.toLowerCase());

let _enVocab;
function englishVocab() {
  if (!_enVocab) {
    _enVocab = new Set();
    for (const [, v] of localeValues('app_en.arb')) for (const w of wordsOf(v)) _enVocab.add(w);
  }
  return _enVocab;
}

// Returns [{ key, value, reason }] for values that look untranslated.
function suspectStrings(file) {
  const stem = stemOf(file);
  if (stem === 'en') return [];
  const scripts = SCRIPTS[stem];
  const vocab = englishVocab();
  const out = [];
  for (const [key, value] of localeValues(file)) {
    const cleaned = cleanValue(value);
    let reason = null;
    if (scripts) {
      const hasScript = scripts.some((s) => SCRIPT_RANGES[s].test(cleaned));
      if (!hasScript && (cleaned.match(/[A-Za-z]{2,}/g) || []).length >= 3) reason = 'latin-in-non-latin';
    } else {
      const w = wordsOf(value);
      const enRatio = w.length ? w.filter((x) => vocab.has(x)).length / w.length : 0;
      if (w.length >= 4 && enRatio >= 0.8 && w.some((x) => STOP_WORDS.has(x))) reason = 'english';
    }
    if (reason) out.push({ key, value, reason });
  }
  return out;
}

let _factory;
// CLD3 ships as WASM; load and instantiate it once per process.
async function loadDetector() {
  if (!_factory) _factory = await loadModule();
  return _factory;
}

// { ok, lang, prob, reliable, accept } for one locale file's aggregate text.
// Pass a CLD3 factory from loadDetector(). Do NOT set create()'s byte-range
// args: a non-default maxNumBytes truncates mid-codepoint and corrupts
// detection of multibyte scripts.
function verifyLocale(factory, file) {
  const stem = stemOf(file);
  const accept = acceptedCodes(stem);
  const detector = factory.create();
  try {
    const r = detector.findLanguage(localeText(file));
    return {
      ok: r.is_reliable && accept.includes(r.language),
      lang: r.language,
      prob: r.probability,
      reliable: r.is_reliable,
      accept,
    };
  } finally {
    detector.dispose && detector.dispose();
  }
}

module.exports = {
  arbDir,
  ACCEPT,
  stemOf,
  acceptedCodes,
  localeFiles,
  localeValues,
  localeText,
  loadDetector,
  verifyLocale,
  SCRIPTS,
  STOP_WORDS,
  englishVocab,
  suspectStrings,
};
