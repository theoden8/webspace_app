// LICENSE-002 gate for tor's GeoIP table (TOR-014).
//
// An exit-country pin needs GeoIP, and the obvious fix is the one this
// forbids: Tor.framework's `Tor/GeoIP` subspec bundles the IPFire Location
// Database, CC BY-SA 4.0, into the app. Copyleft data is fetched on the
// device instead (lib/services/tor_geoip.dart), so this fails CI if a Podfile
// asks for the bundle, the plugin reads it, the Linux build installs tor's
// own tables from its source (TOR-027), or a table gets committed.

const test = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { REPO, read, exists } = require('./helpers/source');

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
    if (!exists(rel)) continue;
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

// The Linux build installs what linux/tor_build.sh lays out, and the script
// takes only tor's program and licence from the source tree, which carries
// tables under src/config. scripts/verify_tor_shipped.sh looks for one in the
// built bundle on CI.
test("the Linux build takes nothing of tor's source tree but the program and its licence", () => {
  const rel = 'linux/tor_build.sh';
  const takes = read(rel)
    .split('\n')
    .filter((l) => /^\s*(install|cp)\s/.test(l));
  assert.deepEqual(takes.filter((l) => /\bsrc\/|LICENSE/.test(l)).map((l) => l.trim()), [
    'install -m 755 src/app/tor "$out/tor"',
    'install -m 644 LICENSE "$out/docs/tor.txt"',
  ], `${rel} takes something else from tor's source tree`);
  for (const line of takes) {
    assert.doesNotMatch(line, /geoip|src\/config/i, `${rel} installs GeoIP data: ${line}`);
  }
});

test('no GeoIP table is committed', () => {
  const files = execFileSync('git', ['ls-files'], { cwd: REPO, encoding: 'utf8' })
    .split('\n')
    .filter(Boolean);
  const tables = files.filter((f) => /(^|\/)geoip6?$/.test(f));
  assert.deepEqual(tables, [], 'GeoIP data is downloaded on the device, not committed');
});

test('the data is attributed on the licences page', () => {
  const notice = 'assets/licenses/ipfire_location.txt';
  assert.match(read(notice), /CC BY-SA 4\.0/);
  assert.ok(read('lib/services/licenses.dart').includes(`'${notice}'`),
    `${notice} must be registered in the custom-licence list in lib/services/licenses.dart`);
});
