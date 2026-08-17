// Design gallery registry drift gate. The card list lives in Dart
// (lib/design_gallery/main.dart) and the viewport list lives in the screenshot
// driver (tool/design_gallery/shoot.js), because a viewport is a screenshot
// concern and not a widget concern. Nothing links them at runtime: a card added
// to one side and not the other either never gets screenshotted or gets shot
// against a card id that no longer exists, and both fail quietly.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const read = (rel) => fs.readFileSync(path.join(repoRoot, rel), 'utf8');

const dartIds = [...read('lib/design_gallery/main.dart').matchAll(/GalleryCard\(id:\s*'([^']+)'/g)].map((m) => m[1]);
const shootIds = [...read('tool/design_gallery/shoot.js').matchAll(/\{\s*id:\s*'([^']+)'/g)].map((m) => m[1]);

test('every gallery card has a viewport in shoot.js', () => {
  assert.deepEqual(dartIds.filter((id) => !shootIds.includes(id)), []);
});

test('every shoot.js viewport names a real gallery card', () => {
  assert.deepEqual(shootIds.filter((id) => !dartIds.includes(id)), []);
});

test('the accent sweep names a real gallery card', () => {
  const sweep = read('tool/design_gallery/shoot.js').match(/ACCENT_SWEEP\s*=\s*\{\s*card:\s*'([^']+)'/);
  assert.ok(sweep, 'ACCENT_SWEEP not found in shoot.js');
  assert.ok(dartIds.includes(sweep[1]), `ACCENT_SWEEP card '${sweep[1]}' is not a gallery card`);
});

test('card ids are unique on both sides', () => {
  assert.equal(new Set(dartIds).size, dartIds.length);
  assert.equal(new Set(shootIds).size, shootIds.length);
  assert.ok(dartIds.length > 0);
});
