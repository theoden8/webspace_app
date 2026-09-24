// LICENSE-002 gate for tor's GeoIP table (TOR-014).
//
// An exit-country pin needs GeoIP, and the obvious fix is the one this
// forbids: Tor.framework's `Tor/GeoIP` subspec bundles the IPFire Location
// Database, CC BY-SA 4.0, into the app. Copyleft data is fetched on the
// device instead (lib/services/tor_geoip.dart), so this fails CI if a Podfile
// asks for the bundle, the plugin reads it, or a table gets committed.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const repoRoot = path.resolve(__dirname, '..', '..');
const read = (rel) => fs.readFileSync(path.join(repoRoot, rel), 'utf8');

test('no Podfile asks for a GeoIP subspec', () => {
  for (const rel of ['ios/Podfile', 'macos/Podfile']) {
    const live = read(rel)
      .split('\n')
      .filter((l) => !l.trim().startsWith('#'))
      .join('\n');
    assert.ok(!/['"]Tor\/GeoIP/.test(live),
      `${rel} names a Tor/GeoIP subspec, which bundles CC BY-SA data into the app`);
  }
  for (const rel of ['ios/Podfile.lock', 'macos/Podfile.lock']) {
    if (!fs.existsSync(path.join(repoRoot, rel))) continue;
    assert.ok(!/Tor\/GeoIP/.test(read(rel)),
      `${rel} resolves a Tor/GeoIP subspec`);
  }
});

test('the plugin never reads a bundled table', () => {
  const rel = 'ios/Runner/TorControllerPlugin.swift';
  const src = read(rel);
  for (const bad of [/\bgeoIpBundle\b/, /Bundle\.geoIp\b/, /\.geoipFile\s*=/, /\.geoip6File\s*=/]) {
    assert.ok(!bad.test(src),
      `${rel} matches ${bad}: the table comes from Dart's download, never the bundle`);
  }
});

test('no GeoIP table is committed', () => {
  const files = execFileSync('git', ['ls-files'], { cwd: repoRoot, encoding: 'utf8' })
    .split('\n')
    .filter(Boolean);
  const tables = files.filter((f) => /(^|\/)geoip6?$/.test(f));
  assert.deepEqual(tables, [], 'GeoIP data is downloaded on the device, not committed');
});

test('the data is attributed on the licences page', () => {
  const notice = 'assets/licenses/ipfire_location.txt';
  assert.match(read(notice), /CC BY-SA 4\.0/);
  assert.ok(read('lib/main.dart').includes(`'${notice}'`),
    `${notice} must be registered in the custom-licence list in lib/main.dart`);
});
