// Every secret store keeps its secret out of a backup (PWD-005).
//
// A secret lives in a SecureJsonStore and never in a site's JSON; a backup is
// emailed and synced, so one secret in it is a leak. No type says a store's
// field is absent from SettingsBackupService's output, so this gate makes each
// store answer one of two ways: a test that plants a secret through it and
// asserts the export lacks it, or no reach into the backup code at all. A new
// store fails here until it says which.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, files } = require('./helpers/source');

// The store's file, and the test that plants a secret and reads the export.
const EXPORT_TESTS = {
  'lib/services/cookie_secure_storage.dart':
    ['test/settings_backup_test.dart', 'secure cookies never appear in export'],
  'lib/services/proxy_password_secure_storage.dart':
    ['test/settings_backup_test.dart', 'proxy passwords never appear in exports (PWD-005)'],
  'lib/services/http_auth_secure_storage.dart':
    ['test/http_auth_secure_storage_test.dart', 'HTTPAUTH-006: saved sign-ins never appear in exports'],
};

// Stores the backup code never names: app-level secrets no backup carries.
const OUTSIDE_BACKUPS = [
  'lib/services/tor_bridge_secure_storage.dart',
  'lib/services/external_tor_control_password_storage.dart',
];

const BACKUP_CODE = [
  'lib/services/settings_backup.dart',
  'lib/settings_import_engine.dart',
  'lib/controllers/backup_controller.dart',
];

const stores = files('lib', /\.dart$/)
  .filter((f) => f !== 'lib/services/keystore.dart')
  .filter((f) => /\bSecureJsonStore</.test(read(f)));

test('PWD-005: every secret store says how its secret stays out of a backup', () => {
  assert.deepEqual(
    stores.filter((f) => !(f in EXPORT_TESTS) && !OUTSIDE_BACKUPS.includes(f)),
    [],
    'a new SecureJsonStore: add a test that plants its secret and asserts '
      + 'exportToJson lacks it, and name it in EXPORT_TESTS',
  );
  for (const f of [...Object.keys(EXPORT_TESTS), ...OUTSIDE_BACKUPS]) {
    assert.ok(stores.includes(f), `${f} no longer holds a SecureJsonStore: drop it here`);
  }
});

test('PWD-005: each named export test exists', () => {
  for (const [store, [file, name]] of Object.entries(EXPORT_TESTS)) {
    assert.ok(read(file).includes(name), `${store}: '${name}' is not in ${file}`);
  }
});

test('PWD-005: a store outside backups is named by no backup code', () => {
  for (const store of OUTSIDE_BACKUPS) {
    const cls = read(store).match(/^(?:final |abstract |base )*class (\w+)/m)[1];
    for (const f of BACKUP_CODE) {
      assert.doesNotMatch(read(f), new RegExp(`\\b${cls}\\b`), `${f} names ${cls}`);
    }
  }
});
