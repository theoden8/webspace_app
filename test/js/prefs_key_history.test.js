// BACKUP-014: what an upgrade finds on the device stays readable. Every
// SharedPreferences key a release wrote (test/fixtures/backup_compat/<tag>/
// prefs_writes.json) is still read by lib/ with the type the release wrote
// it as. A key that stopped being read is a setting the upgrade silently
// dropped; a key read with another type loses its value, and through a typed
// getter (`getBool` on a stored String) throws during startup before the
// sites load.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { scan } = require('../../tool/backup_compat/prefs_keys.js');

const root = path.join(__dirname, '..', '..');
const fixtures = path.join(root, 'test', 'fixtures', 'backup_compat');

// A key a release wrote that lib/ no longer reads, and why losing it is
// intended. Removing a setting means adding it here, not deleting the read.
const RETIRED = {
  currentIndex:
    'written on every switch, never read since #134 made every launch open on the home screen',
};

const head = scan(path.join(root, 'lib'));
const releases = fs.readdirSync(fixtures)
  .filter((d) => /^v\d+\.\d+\.\d+$/.test(d))
  .filter((d) => fs.existsSync(path.join(fixtures, d, 'prefs_writes.json')));

test('every release has a prefs manifest', () => {
  const all = fs.readdirSync(fixtures).filter((d) => /^v\d+\.\d+\.\d+$/.test(d));
  assert.deepEqual(releases.sort(), all.sort());
  assert.ok(releases.includes('v0.0.4'));
});

test('the scan still sees the registry and the site list', () => {
  // A regex that silently matches nothing would pass every check below.
  assert.ok(Object.keys(head.registry).length >= 10, 'kExportedAppPrefs not parsed');
  assert.deepEqual([...head.reads.webViewModels], ['StringList']);
});

for (const tag of releases) {
  test(`${tag}: every key it wrote is still read, with the same type`, () => {
    const written = JSON.parse(
      fs.readFileSync(path.join(fixtures, tag, 'prefs_writes.json'), 'utf8'));
    const problems = [];
    for (const [key, types] of Object.entries(written)) {
      if (key in RETIRED) continue;
      const read = head.reads[key];
      if (!read) {
        problems.push(`"${key}" is no longer read: an upgrade from ${tag} loses it. `
          + 'Read the old key (and migrate it), or list it in RETIRED with the reason.');
        continue;
      }
      for (const type of types) {
        if (!read.has(type)) {
          problems.push(`"${key}" was written as ${type} but is read as `
            + `${[...read].join('/')}: the value is lost, and a typed getter throws at startup.`);
        }
      }
    }
    assert.deepEqual(problems, []);
  });
}

test('a retired key is not quietly read again', () => {
  for (const key of Object.keys(RETIRED)) {
    assert.equal(head.reads[key], undefined,
      `"${key}" is read again; take it out of RETIRED`);
  }
});

test('exported prefs are never read through a typed getter', () => {
  // v0.2.2 to v0.3.1 imports stored globalPrefs values under the file's
  // JSON type, so any of these keys can hold the wrong type on a device.
  // `readPrefAs` and `readExportedAppPrefs` return the default instead of
  // throwing.
  const offenders = head.typedReads
    .filter((r) => r.key in head.registry)
    .map((r) => `${r.at}: get${r.type}('${r.key}')`);
  assert.deepEqual(offenders, [], 'read these with readPrefAs<T>()');
});

test('lib/ reads every key it writes with the type it writes', () => {
  const problems = [];
  for (const [key, types] of Object.entries(head.writes)) {
    const read = head.reads[key];
    if (!read) continue;
    for (const type of types) {
      if (!read.has(type)) problems.push(`${key}: written ${type}, read ${[...read]}`);
    }
  }
  assert.deepEqual(problems, []);
});
