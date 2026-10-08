// Structural gate: per-site fields with an override (the archive tier,
// ARCH-006, or Tracking Protection) reach a webview through their `effective*`
// getter, never the raw stored field.
//
// Every webview surface is built from the SitePosture that
// `WebViewModel.sitePosture` resolves, so that resolver is the boundary: a raw
// field read there silently reinstates the feature for an archived site (or
// under the umbrella) on every surface at once, and nothing downstream
// re-checks. The model's other config boundary (setController, the root
// webview's slot-owned settings) passes named arguments, checked the same way.

const test = require('node:test');
const assert = require('node:assert');
const { read, blockAfter } = require('./helpers/source');

const MODEL = 'lib/web_view_model.dart';

// Fields whose model getter applies an override. Keep in step with the
// `effective*` getters on WebViewModel.
const OVERRIDDEN = [
  'incognito',
  'notificationsEnabled',
  'backgroundAudioEnabled',
  'captures',
  'protectedContentAllowed',
  'externalLinkMode',
  'dnsBlockLevel',
  'localCdnEnabled',
  'thirdPartyCookiesEnabled',
  'httpsUpgradeEnabled',
  'webRtcPolicy',
];

const capitalize = (s) => s[0].toUpperCase() + s.slice(1);

test('the effective getters this gate relies on still exist', () => {
  const src = read(MODEL);
  const missing = OVERRIDDEN.filter((f) => !src.includes(`get effective${capitalize(f)}`));
  assert.deepEqual(missing, [], 'OVERRIDDEN names a field with no effective getter');
});

test('sitePosture reads every overridden field through its getter', () => {
  const resolver = blockAfter(read(MODEL), 'SitePosture sitePosture({', '}) {', MODEL);
  for (const field of OVERRIDDEN) {
    // The bare identifier as a value; a record label of the same name is not a read.
    const raw = new RegExp(`(?<![\\w.])${field}\\b(?!\\s*:)`);
    assert.doesNotMatch(
      resolver,
      raw,
      `sitePosture reads ${field} raw; use effective${capitalize(field)} so the `
        + 'override reaches every webview surface',
    );
  }
});

test('no named argument in the model passes an overridden field raw', () => {
  const src = read(MODEL);
  for (const field of OVERRIDDEN) {
    const raw = new RegExp(`\\b${field}:\\s*(?:id\\.)?${field}\\b`, 'g');
    assert.deepEqual(
      src.match(raw) || [],
      [],
      `${field} is passed raw at a config boundary in ${MODEL}; `
        + `use effective${capitalize(field)}`,
    );
  }
});
