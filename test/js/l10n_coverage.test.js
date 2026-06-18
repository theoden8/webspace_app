// Localization coverage guard (LOC-003), ported from the former Dart
// test/l10n_coverage_test.dart so it runs in the lightweight checks job
// (Node) instead of behind a platform build. The English ARB is the source
// of truth; every other locale must define the same keys with the same
// placeholders and no empty values.
//
// The runtime locale-resolution test (resolveSupportedLocale) stays in Dart
// (test/app_locale_test.dart) - it exercises Dart code, not data.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { arbDir } = require('./helpers/l10n_language');

const templateName = 'app_en.arb';

// Keys whose value is legitimately identical in every locale (brand/product
// names, acronyms, example hosts, universal tokens), exempt from the "never
// translated across every locale" guard.
const IDENTICAL_EVERYWHERE_ALLOWLIST = new Set([
  'appTitle', // WebSpace (product name)
  'appSettingsLocalCdn', // LocalCDN (product name)
  'siteSettingsLocalCdn', // LocalCDN
  'siteSettingsClearUrls', // ClearURLs (product name)
  'devToolsTabAbp', // ABP (acronym)
  'devToolsTabDns', // DNS (acronym)
  'siteSettingsLocationProviderGps', // GPS (acronym)
  'siteSettingsLocationProviderGsm', // GSM (acronym)
  'siteSettingsUserAgent', // User-Agent (HTTP header name)
  'trustedCertFingerprintLabel', // SHA-256 (acronym)
  'untrustedCertSha256', // SHA-256
  'linkHandlingHostnameHint', // example.com (example host)
  'linkHandlingTestUrlHint', // https://example.org/foo (example URL)
  'siteSettingsLetterboxAutoHint', // "auto" (universal token)
]);

const loadArb = (name) => JSON.parse(fs.readFileSync(path.join(arbDir, name), 'utf8'));
const messageKeys = (arb) => new Set(Object.keys(arb).filter((k) => !k.startsWith('@')));

// Variable names referenced by an ICU message: the identifier of every
// {name} interpolation and the control variable of {count, plural, ...} /
// {sel, select, ...}. The trailing [,}] skips literal text inside
// plural/select branches so differently-worded translations don't register
// as placeholder drift.
const placeholderTokens = (value) =>
  new Set([...value.matchAll(/\{(\w+)\s*[,}]/g)].map((m) => m[1]));

const setDiff = (a, b) => [...a].filter((x) => !b.has(x));

const template = loadArb(templateName);
const templateKeys = messageKeys(template);
const templatePlaceholders = new Map(
  [...templateKeys].map((k) => [k, placeholderTokens(template[k])]),
);
const localeNames = fs
  .readdirSync(arbDir)
  .filter((f) => f.endsWith('.arb') && f !== templateName)
  .sort();

test('template ARB is well-formed and fully documented', () => {
  assert.ok(templateKeys.size > 0);
  for (const k of templateKeys) {
    assert.ok(template[k].trim().length > 0, `Template key "${k}" has an empty value.`);
    const meta = template[`@${k}`];
    assert.ok(meta && typeof meta === 'object', `Template key "${k}" is missing its "@${k}" metadata block.`);
    assert.equal(typeof meta.description, 'string', `Template key "${k}" is missing a description.`);
  }
});

for (const name of localeNames) {
  test(`${name} has full key + placeholder parity with the template`, () => {
    const arb = loadArb(name);
    const keys = messageKeys(arb);
    assert.deepEqual(setDiff(keys, templateKeys), [], `${name} defines keys absent from the template.`);
    assert.deepEqual(setDiff(templateKeys, keys), [], `${name} is missing keys. Translate them from app_en.arb and add them.`);
    for (const k of keys) {
      assert.ok(arb[k].trim().length > 0, `${name} key "${k}" is empty.`);
      assert.deepEqual(
        [...placeholderTokens(arb[k])].sort(),
        [...templatePlaceholders.get(k)].sort(),
        `${name} key "${k}" has placeholders that differ from the template; interpolation would break.`,
      );
    }
  });
}

test('no key is left as the English source across every locale', () => {
  const locales = localeNames.map(loadArb);
  const offenders = [];
  for (const k of templateKeys) {
    if (IDENTICAL_EVERYWHERE_ALLOWLIST.has(k)) continue;
    if (locales.every((arb) => arb[k] === template[k])) offenders.push(k);
  }
  assert.deepEqual(
    offenders,
    [],
    `These keys are the English source in every locale (never translated): ${offenders.join(', ')}. `
      + 'Translate them in each app_<x>.arb, or if a value is genuinely universal add its key to the allowlist.',
  );
});

test('every allowlisted key is actually identical across all locales', () => {
  const locales = localeNames.map(loadArb);
  const stale = [];
  for (const k of IDENTICAL_EVERYWHERE_ALLOWLIST) {
    if (!templateKeys.has(k)) {
      stale.push(`${k} (absent from template)`);
      continue;
    }
    if (!locales.every((arb) => arb[k] === template[k])) stale.push(k);
  }
  assert.deepEqual(stale, [], `Allowlisted keys no longer English-in-every-locale (remove them): ${stale.join(', ')}`);
});
