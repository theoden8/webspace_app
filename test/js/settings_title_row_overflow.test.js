// A title row of `Row([Text, HintButton])` overflows on the right as soon as
// the label needs more room than the row has. `HintedTitle`
// (lib/widgets/setting_tile.dart) builds that row with the label flexed, so
// the gate only has to hold every title row to it: a HintButton is built there
// and nowhere else, apart from the placements below, none of which shares a
// row with a label.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const scanRoots = ['lib/main.dart', 'lib/screens', 'lib/widgets'];

const ALLOWED = {
  'lib/widgets/hint_button.dart': 'the widget',
  'lib/widgets/setting_tile.dart': 'HintedTitle itself',
  'lib/screens/saved_proxies.dart': 'an AppBar action',
  'lib/screens/tor_bridge_settings.dart': 'an AppBar action',
  'lib/widgets/proxy_test_tile.dart': 'beside the Test button, in a Wrap',
};

function dartFiles(rel) {
  const abs = path.join(repoRoot, rel);
  if (!fs.existsSync(abs)) return [];
  if (!fs.statSync(abs).isDirectory()) return [rel];
  return fs.readdirSync(abs, { withFileTypes: true }).flatMap((e) =>
    e.isDirectory() ? dartFiles(`${rel}/${e.name}`)
      : e.name.endsWith('.dart') ? [`${rel}/${e.name}`] : []);
}

test('a title row gets its hint button through HintedTitle', () => {
  const offenders = scanRoots.flatMap(dartFiles).filter((rel) =>
    !(rel in ALLOWED)
    && /\bHintButton\(/.test(fs.readFileSync(path.join(repoRoot, rel), 'utf8')));
  assert.deepEqual(offenders, [],
    'Build the title as HintedTitle(title, hint: ...) or a SettingTile, which '
      + 'flex the label so it wraps instead of overflowing the row.');
});

test('every allowed placement still builds a HintButton', () => {
  const stale = Object.keys(ALLOWED).filter((rel) =>
    !/\bHintButton\(/.test(fs.readFileSync(path.join(repoRoot, rel), 'utf8')));
  assert.deepEqual(stale, [], 'drop these from ALLOWED');
});
