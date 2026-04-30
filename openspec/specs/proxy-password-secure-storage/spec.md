# Proxy Password Secure Storage Specification

## Purpose

Per-site and global outbound proxy credentials include a password that is
sensitive at rest. This spec defines the contract for where the password
lives, how it (does not) round-trip through the settings backup format,
and how legacy plaintext entries are migrated. It is the proxy-password
sibling of [`cookie-secure-storage`](../cookie-secure-storage/spec.md);
the two are independent storage paths that share the same threat model,
the same `flutter_secure_storage` backend, and the same
"never serialise to a user-controlled JSON file" rule for exports.

## Status

- **Status**: Completed
- **Platforms**: All (Keychain on iOS/macOS, EncryptedSharedPrefs on
  Android, libsecret on Linux, DPAPI on Windows — provided by the
  `flutter_secure_storage` plugin).

---

## Problem Statement

Before this change, both per-site and the app-global outbound proxy
stored credentials inline as a JSON-encoded `UserProxySettings` in
SharedPreferences:

- per-site: inside each site's blob in `prefs.getStringList('webViewModels')`
- global: under the key `globalOutboundProxy`

SharedPreferences writes to plaintext files (`*.xml` on Android,
`NSUserDefaults` on Apple, `~/.local/share/<app>/shared_preferences.json`
on Linux). Anyone with file access to the device — local user, ADB pull,
unencrypted device backup, forensic image — could extract the proxy
password verbatim. The password is also the only `UserProxySettings` field
that warrants this protection: the proxy address and username are not
secret in the same way.

The `sodium`-style mprotect angle (RAM hardening) is intentionally
**out of scope** for this spec. Every downstream consumer of the password
(`Uri.encodeComponent`, `HttpClientBasicCredentials`, the platform-channel
marshalling into native webview proxy config) takes a Dart `String`, so
the protection window for an mprotect'd buffer would be microseconds and
the protection is mostly cosmetic. If a long-lived secret (master key,
vault token) is ever introduced, that is a separate spec.

---

## Threat Model

| Threat                                  | Defended? | Mechanism                                  |
|-----------------------------------------|-----------|--------------------------------------------|
| ADB pull / unencrypted device backup    | Yes       | Password lives in EncryptedSharedPrefs / Keychain — not in `shared_prefs/*.xml` |
| Disk forensics on lost/stolen device    | Partial   | Backed by OS keystore; depends on lock posture |
| Other apps on the device                | Yes       | OS sandboxing already covers this; secure storage adds defense in depth |
| Memory inspection by attached debugger  | No        | Out of scope (Dart `String` everywhere downstream) |
| User-controlled backup file the user shared | Yes       | Passwords are stripped at export, same as `isSecure=true` cookies (PWD-005) |

---

## Requirements

### Requirement: PWD-001 - Password Lives in Secure Storage

Proxy passwords SHALL be persisted in `flutter_secure_storage` and SHALL
NOT appear in plaintext SharedPreferences entries.

#### Scenario: Per-site password is segregated

**Given** a site has a proxy with a non-empty `password`
**When** the site is persisted via `_saveWebViewModels`
**Then** `prefs.getStringList('webViewModels')` contains the site's blob
**And** that blob's `proxySettings` map does NOT contain a `password` key
**And** `flutter_secure_storage` contains an entry under the
[`ProxyPasswordSecureStorage`] map keyed by the site's `siteId`

#### Scenario: Global outbound password is segregated

**Given** the user updates `GlobalOutboundProxy.current` with a non-empty `password`
**When** the in-memory cache is flushed by `GlobalOutboundProxy.update`
**Then** `prefs.getString(kGlobalOutboundProxyKey)` decodes to a JSON
object without a `password` key
**And** `flutter_secure_storage` contains the password under
[`ProxyPasswordSecureStorage.globalProxyKey`] (`__global_outbound__`)

#### Scenario: Default `toJson` omits the password

**Given** any `UserProxySettings` instance with a non-null `password`
**When** `settings.toJson()` is called with no arguments
**Then** the resulting map does NOT contain a `password` key

This is the at-rest contract: any caller serialising into plaintext
storage gets a sanitised JSON for free.

---

### Requirement: PWD-002 - Hydration on Load

The in-memory `UserProxySettings.password` SHALL be populated from secure
storage at startup and after every backup import.

#### Scenario: Per-site hydration

**Given** secure storage holds a password for `siteId = "abc"`
**When** `_loadWebViewModels` reads `webViewModels` from prefs
**Then** the constructed `WebViewModel` for `"abc"` has its
`proxySettings.password` populated from secure storage

#### Scenario: Global hydration

**Given** secure storage holds a password under
[`ProxyPasswordSecureStorage.globalProxyKey`]
**When** `GlobalOutboundProxy.initialize` is called at app start
**Then** `GlobalOutboundProxy.current.password` equals the stored value

---

### Requirement: PWD-003 - Legacy Migration

The system SHALL transparently migrate plaintext passwords found in old
SharedPreferences entries to secure storage, exactly once per entry.

#### Scenario: Per-site legacy migration on first load

**Given** a `webViewModels` entry from a pre-migration build whose
`proxySettings` contains `"password": "legacy-secret"`
**And** secure storage has no entry for that `siteId`
**When** `_loadWebViewModels` runs
**Then** secure storage is updated with `siteId -> "legacy-secret"`
**And** the prefs entry is rewritten without the `password` key
**And** the WebViewModel's `proxySettings.password` is `"legacy-secret"`

#### Scenario: Per-site legacy migration is idempotent

**Given** the migration ran on a previous launch
**When** `_loadWebViewModels` runs again
**Then** no further mutation of secure storage or prefs occurs

#### Scenario: Global legacy migration on initialize

**Given** `prefs.getString(kGlobalOutboundProxyKey)` decodes to a JSON
object that contains `"password": "legacy-secret"`
**When** `GlobalOutboundProxy.initialize` is called
**Then** secure storage is updated with
`ProxyPasswordSecureStorage.globalProxyKey -> "legacy-secret"`
**And** the prefs entry is rewritten without the `password` key

#### Scenario: Secure-storage value wins on conflict

**Given** secure storage already holds a password for a `siteId`
**And** the prefs JSON for that site also still contains a (stale) `password`
**When** the legacy-migration pre-pass runs
**Then** secure storage is unchanged (newer value wins)
**And** the prefs entry is still cleaned of the `password` key

---

### Requirement: PWD-004 - Orphan Cleanup

The system SHALL drop secure-storage entries for sites that no longer
exist, mirroring the existing cookie-orphan sweep, while preserving the
reserved global key.

#### Scenario: Deleted site clears its proxy password

**Given** a site with `siteId = "abc"` has a stored proxy password
**And** the site is deleted from the app
**When** the post-delete cleanup pass runs
**Then** secure storage no longer contains an entry for `"abc"`

#### Scenario: Global key is never swept as an orphan

**Given** secure storage contains an entry under
[`ProxyPasswordSecureStorage.globalProxyKey`]
**When** an orphan sweep runs with an `activeKeys` set that does not
contain that key
**Then** the global entry is preserved

---

### Requirement: PWD-005 - Passwords Are Stripped From Exports

Settings backup files SHALL NOT contain proxy passwords. The export
format is a user-controlled JSON file that may be emailed, synced to
cloud storage, or shared; the same "no secret rides along" rule that
strips `isSecure=true` cookies (see `cookie-secure-storage` COOKIE-006)
applies uniformly to proxy passwords. After import the user re-enters
proxy passwords on the affected proxy settings screens.

#### Scenario: Export omits per-site password

**Given** a site has `proxySettings.password = "p1"`
**When** `SettingsBackupService.createBackup` is called and the result
is serialised via `exportToJson`
**Then** the resulting JSON does NOT contain `"p1"` anywhere
**And** the site blob's `proxySettings` map does NOT contain a
`password` key

#### Scenario: Export omits global outbound password

**Given** `GlobalOutboundProxy.current.password = "p2"`
**When** the export is built
**Then** `globalPrefs[kGlobalOutboundProxyKey]` decodes to a JSON object
that does NOT contain a `password` key

#### Scenario: Import does not write a password to secure storage

**Given** the import path runs on a backup that has no proxy passwords
**When** `_importSettings` finishes
**Then** any pre-existing proxy passwords for the imported `siteId`s
were swept by orphan cleanup (PWD-004) and no new ones are written

#### Scenario: User is told to re-enter passwords

**Given** the imported backup contains a per-site or global proxy with a
non-empty `username` (a strong proxy for "had a password configured on
the source device")
**When** the import success snackbar is shown
**Then** the snackbar mentions that proxy passwords aren't included in
backups and need to be re-entered

This avoids silently confusing the user when the proxy stops working
post-restore.

---

### Requirement: PWD-006 - Graceful Degradation

The system SHALL continue to function when `flutter_secure_storage` is unavailable, and SHALL NOT silently fall back to writing the password into SharedPreferences.

#### Scenario: Secure storage unavailable on save

**Given** a `flutter_secure_storage` `write` call throws
**When** `ProxyPasswordSecureStorage.saveAll` catches it
**Then** the failure is logged via `LogService` at `error` level
**And** the in-memory `UserProxySettings.password` still works for the
session
**And** prefs are NOT mutated to carry the password as a fallback

The non-fallback choice is deliberate: the user's original intent was a
secure-at-rest password; silently demoting to plaintext SharedPreferences
would invalidate that intent without telling them. The session continues
because the in-memory copy is enough to make outbound calls until the app
is restarted.

---

## Storage Flow

### Loading (App Start)

1. `_loadWebViewModels` reads `webViewModels` from SharedPreferences
2. **Pre-pass:** scan each blob's `proxySettings` for a legacy plaintext
   `password`; for each one found, write to secure storage (unless an
   entry already exists for that `siteId`) and rewrite the blob without
   the `password` key
3. Construct `WebViewModel` instances from the cleaned blobs
4. Hydrate each model's `proxySettings.password` from secure storage
5. Re-save to settle the new shape on disk
6. `GlobalOutboundProxy.initialize` does the same (migrate + hydrate) for
   the global key

### Saving (On Change)

1. Mirror per-site `model.proxySettings.password` values into secure
   storage via `ProxyPasswordSecureStorage.saveAll`
2. `_saveWebViewModels` calls `model.toJson()` (default — password
   omitted) and writes to prefs
3. `GlobalOutboundProxy.update` writes JSON-without-password to prefs and
   the password to secure storage

### Backup Round-Trip

| Step          | Per-site path                                | Global path                                                |
|---------------|----------------------------------------------|------------------------------------------------------------|
| Export build  | `model.toJson()` (always password-less)      | `readExportedAppPrefs(prefs)` (already password-less since prefs are sanitised) |
| Export to disk| Backup carries `address` / `username` only   | Backup carries `address` / `username` only                 |
| Import parse  | `WebViewModel.fromJson` — `password` field is null | `readGlobalOutboundProxy` — `password` field is null  |
| Import apply  | `_saveWebViewModels` writes prefs, no password to migrate | `GlobalOutboundProxy.update` with the password-less settings |
| Post-import   | UI snackbar tells the user to re-enter passwords if a `username` was present in the backup |

---

## Files

### Created
- `lib/services/proxy_password_secure_storage.dart` - Core service
- `test/proxy_password_secure_storage_test.dart` - Unit tests
- `test/helpers/mock_secure_storage.dart` - Shared in-memory mock
  (extracted from `cookie_secure_storage_test.dart`)

### Modified
- `lib/settings/proxy.dart` - `toJson` always omits the password
- `lib/settings/global_outbound_proxy.dart` - migrate + hydrate on
  `initialize`; route password to secure storage on `update`
- `lib/web_view_model.dart` - `toJson` always omits the password
- `lib/main.dart` - `_loadWebViewModels` / `_saveWebViewModels` /
  `_exportSettings` / `_importSettings` / orphan cleanup paths;
  post-import snackbar surfaces the strip contract when a `username` was
  present in the imported backup
- `lib/services/settings_backup.dart` - documents the strip-from-export
  contract; doesn't need to opt in to anything (default is safe)
- `test/proxy_test.dart`, `test/outbound_http_test.dart`,
  `test/cookie_secure_storage_test.dart` - updated to the new contract

---

## Maintenance

When adding a new field that holds a credential, token, or other
sensitive secret:

1. **Decide the storage**: it does not belong in SharedPreferences. Use
   `flutter_secure_storage` with the same options as
   `ProxyPasswordSecureStorage` (`encryptedSharedPreferences` on Android,
   `first_unlock` keychain accessibility on Apple).
2. **Never write it to JSON**. The `toJson` for the containing object
   simply omits the field. There is intentionally no opt-in flag —
   passwords are stripped uniformly across persistence and the backup
   format, matching the rule for `isSecure=true` cookies.
3. **Hydrate on load** at the same point we hydrate proxy passwords —
   `_loadWebViewModels` for per-site, `GlobalOutboundProxy.initialize`
   (or its analogue) for global.
4. **Migrate legacy plaintext** with the same idempotent pre-pass: read
   prefs, move secret to secure storage, rewrite prefs without it. Use
   `ProxyPasswordSecureStorage.migrateLegacyPassword` as the template.
5. **Wire orphan cleanup** alongside the existing
   `_cookieSecureStorage.removeOrphanedCookies` and
   `_proxyPasswordStorage.removeOrphaned` calls in main.dart (three
   sites: startup GC, post-import GC, post-delete GC).
6. **Surface the strip-from-export contract in the import UI** so the
   user knows to re-enter the secret after restoring from a backup. The
   per-site / global proxy snackbar in `_importSettings` is the model.
7. **Add a regression test** asserting the secret never appears as a
   substring of `exportToJson(backup)` after a save. The
   "no proxy password substring in exported JSON" test in
   `settings_backup_test.dart` is the template, and the
   "password is stored in secure storage, not SharedPreferences" test in
   `outbound_http_test.dart` covers the at-rest side.
8. **Update this spec** to add the new credential to the threat model
   and requirements, or split it into a sibling spec if the threat model
   diverges.
