// Structural gate: archive-sensitive per-site fields must reach WebViewConfig
// through their `effective*` getter, not the raw stored field.
//
// ARCH-006 disables per-site features for archive-tier sites by overriding them
// on the model (`effectiveIncognito`, `effectiveNotificationsEnabled`, ...).
// Passing the raw field at the config boundary silently reinstates the feature
// for an archived site even though every other consumer reads the getter, and
// nothing downstream re-checks the tier.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..');
const read = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8');

// Fields whose model getter applies an archive-tier override. Keep in step with
// the `effective*` getters on WebViewModel.
const OVERRIDDEN = [
  'incognito',
  'notificationsEnabled',
  'backgroundAudioEnabled',
  'cameraMode',
  'microphoneMode',
  'protectedContentAllowed',
  'externalLinksInBrowser',
  'localCdnEnabled',
];

const capitalize = (s) => s[0].toUpperCase() + s.slice(1);

test('archive-overridden fields reach WebViewConfig via their effective getter', () => {
  const src = read('lib/web_view_model.dart');

  for (const field of OVERRIDDEN) {
    const getter = `effective${capitalize(field)}`;
    if (!src.includes(`get ${getter}`)) continue; // no override defined for this field

    // A named argument passing the bare field, e.g. `notificationsEnabled: notificationsEnabled,`.
    const raw = new RegExp(`\\b${field}:\\s*${field}\\b`, 'g');
    const hits = src.match(raw) || [];
    assert.equal(
      hits.length,
      0,
      `${field} is passed raw at a config boundary in lib/web_view_model.dart; ` +
        `use ${getter} so archive-tier sites keep the ARCH-006 override`,
    );
  }
});

test('the effective getters this gate relies on still exist', () => {
  const src = read('lib/web_view_model.dart');
  const found = OVERRIDDEN.filter((f) => src.includes(`get effective${capitalize(f)}`));
  assert.ok(
    found.length >= 5,
    `expected the archive override getters to still be defined, found only ${found.join(', ')}`,
  );
});
