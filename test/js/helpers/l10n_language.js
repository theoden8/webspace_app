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
};
