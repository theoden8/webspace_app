# Settings Import/Export Specification

## Purpose

This feature allows users to backup and restore their app configuration including sites, webspaces, and preferences.

## Status

- **Status**: Completed

---

## Requirements

### Requirement: BACKUP-001 - Export Settings to JSON

Users SHALL be able to export all settings to a JSON file.

#### Scenario: Export settings

**Given** the user has sites and webspaces configured
**When** the user taps "Export Settings" in the menu
**And** chooses a save location
**Then** a JSON backup file is created with all settings

---

### Requirement: BACKUP-002 - Import Settings from Backup

Users SHALL be able to import settings from a backup file.

#### Scenario: Import settings

**Given** the user has a backup JSON file
**When** the user taps "Import Settings"
**And** selects the backup file
**And** confirms the import
**Then** all settings are restored from the backup

---

### Requirement: BACKUP-003 - Cookie Security

Only non-secure cookies (`isSecure=false`) SHALL be included in backups.
Secure cookies (`isSecure=true`) SHALL NEVER be exported for security reasons.

#### Scenario: Export non-secure cookies only

**Given** a site has cookies: `[session (isSecure=true), theme (isSecure=false)]`
**When** settings are exported
**Then** the backup includes only `[theme]`
**And** the secure `session` cookie is excluded

#### Scenario: Import restores non-secure cookies

**Given** a backup contains non-secure cookies
**When** settings are imported
**Then** non-secure cookies are restored to the site

---

### Requirement: BACKUP-004 - Backup Contents

Backups SHALL include all settings, with cookies filtered by security flag.

#### Scenario: Export all settings

- **WHEN** settings are exported
- **THEN** sites, webspaces, theme, preferences, and non-secure cookies are included
- **AND** secure cookies are excluded for security

| Setting | Exported | Notes |
|---------|----------|-------|
| Sites (URLs, names) | Yes | All site configurations |
| Site proxy settings | Yes | Per-site proxy configuration |
| Site user agents | Yes | Custom user agent strings |
| Site JS enabled | Yes | JavaScript toggle state |
| Site 3rd-party cookies | Yes | Third-party cookie setting |
| Webspaces | Yes | Custom webspaces only |
| Theme mode | Yes | Light/dark/system preference |
| URL bar visibility | Yes | Show/hide URL bar setting |
| Selected webspace | Yes | Currently selected webspace ID |
| Current site index | Yes | Last viewed site |
| Non-secure cookies | Yes | Cookies with `isSecure=false` |
| **Secure cookies** | **No** | `isSecure=true` never exported |
| DNS blocklist level | Yes | Chosen severity (0-5); blob re-downloaded after import |
| Content-blocker list selection | Yes | Per-list `{id, name, url, enabled}`; rule blob re-downloaded after import |
| **DNS / filter rule blobs** | **No** | Downloaded domain lists + adblock rules are machine state |
| **DNS / filter download metadata** | **No** | Rule counts, last-updated timestamps, domain cache |
| **TLS certificate pins** | **No** | BACKUP-010: restoring one makes the app trust a certificate with no prompt |
| Global outbound proxy | Yes | Named in the import dialog before it is applied (BACKUP-006) |
| Global + per-site user scripts | Yes | Restored switched off and opted out (BACKUP-011) |
| **Proxy passwords** | **No** | Stripped on export (PWD-005) *and* on import (BACKUP-011) |

---

### Requirement: BACKUP-009 - Downloaded-Data Blocker Preferences

Backups SHALL carry the user-intent portion of the DNS blocklist and
content-blocker configuration (the chosen DNS severity level and the
content-blocker filter-list selection) while excluding the downloaded
blobs and their machine-state metadata. After import the selection is
restored, but the user re-downloads the blocklists to activate blocking.

The DNS level and content-blocker list selection ride dedicated backup
fields (`dnsBlockLevel`, `contentBlockerLists`), not the
`kExportedAppPrefs` registry, because applying them on import must run
through the owning service to keep the persisted level/selection coherent
with whatever blob the importing device already has on disk.

#### Scenario: DNS severity level restored

**Given** a backup was taken on a device with DNS level "Pro++" (4)
**When** the user imports it on a fresh install
**Then** the App Settings DNS slider shows level 4
**And** no domain blob is loaded (`hasBlocklist` is false) until the user re-downloads

#### Scenario: Content-blocker selection restored without rule blobs

**Given** a backup contains filter lists EasyList (enabled) and a custom list (disabled)
**When** the user imports it
**Then** both lists appear in App Settings with their enabled/disabled state
**And** rule counts show as unknown until the user re-downloads

#### Scenario: Download metadata never exported

**Given** a content-blocker list has a rule count and last-updated timestamp
**When** settings are exported
**Then** the exported list entry contains only `{id, name, url, enabled}`
**And** rule counts, skipped counts, and timestamps are excluded

#### Scenario: Re-download hint after import

**Given** an imported backup had a non-zero DNS level or any enabled filter list
**When** the import completes
**Then** the snackbar advises re-downloading DNS / content blocker lists in App Settings

---

### Requirement: BACKUP-005 - "All" Webspace Handling

The special "All" webspace SHALL never be exported and always be recreated on import.

#### Scenario: Recreate All webspace on import

**Given** a backup contains custom webspaces "Work" and "Personal"
**When** settings are imported
**Then** the "All" webspace is recreated first
**And** "Work" and "Personal" are added after

---

### Requirement: BACKUP-006 - Import Confirmation

Users SHALL see a confirmation dialog before importing that shows:
- Number of sites in backup
- Number of webspaces in backup
- Export timestamp
- Note about cookies not being included
- The app-wide outbound proxy address, when the backup sets a non-DEFAULT one
- The number of user scripts the backup would install, when it carries any

A backup file is plain JSON the user was handed, so its contents are
attacker-authorable. The two additions above are the state that acts on its
own once restored and that a site list does not show: the global proxy
captures every `ProxyType.DEFAULT` site including webview traffic, and a
user script is injected at document start with full page privileges.

#### Scenario: Show import confirmation

**Given** a valid backup file is selected
**When** the file is parsed
**Then** a dialog shows "3 sites, 2 webspaces, exported 2026-01-15"
**And** warns "This will replace all current settings"

#### Scenario: Incoming global proxy is named

**Given** a backup whose `globalPrefs.globalOutboundProxy` decodes to a
non-DEFAULT proxy at `10.0.0.5:1080`
**When** the confirmation dialog is built
**Then** it names `10.0.0.5:1080` and says every site without a proxy of its
own will route through it

#### Scenario: Incoming user scripts are counted

**Given** a backup carrying two global scripts and one per-site script
**When** the confirmation dialog is built
**Then** it reports three user scripts and says they are installed switched
off

---

### Requirement: BACKUP-010 - Trust-Granting State Never Round-Trips

State that grants trust on restore SHALL NOT be registered in
`kExportedAppPrefs`. `kTrustedHostsKey` is the worked case: an entry there
makes `HttpClient.badCertificateCallback` return true and the webview's
`onReceivedServerTrustAuthRequest` return PROCEED with no prompt, so a
backup file naming the key would silently install a man-in-the-middle
certificate for a host of the file author's choosing.

`TrustedHostsService` persists and reloads the key on its own
(`_persist` / `initialize`), so pins still survive an app restart; they
just do not ride a backup. Supersedes the export half of TLS-007.

#### Scenario: Pins are absent from an export

**Given** the device has a pinned `self.local:8443`
**When** settings are exported
**Then** `globalPrefs` has no `trustedHosts` key
**And** the fingerprint does not appear anywhere in the exported JSON

#### Scenario: A hand-crafted backup cannot install a pin

**Given** a backup whose `globalPrefs` contains
`trustedHosts: ["evil.example|443|<fingerprint>"]`
**When** `writeExportedAppPrefs` applies it
**Then** the `trustedHosts` SharedPreferences value is untouched
**And** the next navigation to `evil.example` still prompts

---

### Requirement: BACKUP-011 - Imported Sites Are Sanitised Before They Go Live

`sanitizeImportedSites` SHALL run on the parsed models before they replace
live state, and SHALL:

- set every site's `proxySettings.password` to null. Exports are
  password-less by contract (PWD-005), so a password in a backup file was
  hand-written in; restoring it would route the site through an
  authenticated proxy the file's author controls.
- clear every site's `enabledGlobalScriptIds`. A global script injects on
  per-site opt-in regardless of its own `enabled` flag —
  `combineUserScripts` forces that true — so the opt-in set is the only
  effective gate.
- set `enabled = false` on every per-site script, and on every restored
  global script.
- reset every grant that hands the page a real device or capability to the
  state that asks again: `cameraMode` and `microphoneMode` `real` to `ask`,
  `protectedContentAllowed` `true` to null (ask), and, for the capabilities
  with no first-use prompt, `locationMode` `live` to `off`,
  `notificationsEnabled` and `backgroundAudioEnabled` to false. A grant is
  consent the user gave on the exporting device; the backup's author, not
  the user, chose it. Simulated (`virtual`, `spoof`) and blocked states
  grant nothing and are kept.
- give every site after the first that repeats a `siteId` a fresh one. Two
  sites sharing an id would share one container, so one cookie jar and one
  storage partition.

The user re-enables scripts from the per-site user-scripts screen, which is
where they can read the source first, and re-grants a permission from the
site's settings or at the page's next request.

#### Scenario: Hand-written proxy password is dropped

**Given** a backup whose site carries
`proxySettings: {type: 3, address: "attacker.example:1080", password: "…"}`
**When** the import restores it
**Then** the live model's `proxySettings.password` is null
**And** its `address` is preserved (the address alone is not a credential)

#### Scenario: Restored scripts do not run before review

**Given** a backup whose site has an enabled user script and an
`enabledGlobalScriptIds` entry
**When** the import restores it
**Then** the site's script has `enabled == false`
**And** `enabledGlobalScriptIds` is empty
**And** `combineUserScripts` injects neither

#### Scenario: Restored permission grants ask again

**Given** a backup whose site has `cameraMode: real`, `microphoneMode: real`,
`locationMode: live`, `notificationsEnabled: true`,
`backgroundAudioEnabled: true` and `protectedContentAllowed: true`
**When** the import restores it
**Then** the site has `cameraMode == ask`, `microphoneMode == ask`,
`locationMode == off`, notifications and background audio off, and
`protectedContentAllowed == null`
**And** no drawer permission badge is drawn for it (PERMBADGE-001)

#### Scenario: A repeated siteId does not merge two sites

**Given** a backup with two sites that both carry `siteId: "dup"`
**When** the import restores them
**Then** the first keeps `"dup"` and the second has a fresh id
**And** webspace membership naming `"dup"` stays with the first

---

### Requirement: BACKUP-012 - Every Released Backup Format Imports

A backup written by any release SHALL import without throwing and without
losing a setting: every key the release wrote SHALL still be read, and its
value SHALL come back. A key the release did not write SHALL import as a
freshly added site's default. The same holds for the other formats a
release hands out: a site-settings QR link (`webspace://qr/site/v1/`,
SITEQR) SHALL still decode, and every `webspace://open?url=` link a release
accepted SHALL unwrap to the same URL.

Renaming a persisted key SHALL keep reading the old name and carry its
value over (declared in the test's `_renamedKeys`); dropping one SHALL be
declared with its reason (`_retiredKeys`). The security rules of an import
(BACKUP-011, BACKUP-010, PWD-005) hold for any input whoever wrote it and
are tested against hostile input, not per release.

`version` has been 1 in every release, so a legacy shape is recognised
from the data:

| Shape | Written by | Read as |
|---|---|---|
| `themeMode` as `ThemeMode.index` | v0.0.4, v0.0.5 | `themeMode * 10` (blue accent). Told apart from the current `mode * 10 + accent` by no site carrying `language`, which every export since v0.1.0 writes |
| flat `showUrlBar` beside the sites | v0.0.4 to v0.2.1 | `globalPrefs.showUrlBar` |
| webspace `siteIndices` | v0.0.4 to v0.2.3 | `siteIds` resolved against the backup's site order |
| no `siteId` | v0.0.4 | a fresh id |
| user scripts without `id` | v0.1.6 to v0.2.0 | a fresh id |
| `file://name.html` (imported HTML) | v0.2.1, v0.2.2 | `file:///name.html` |
| plaintext proxy passwords | v0.0.4 to v0.2.2 (per site), v0.2.2 (app-wide) | dropped |
| `trustedHosts` in `globalPrefs` | v0.2.4 to v0.3.1 | ignored (BACKUP-010) |

Every key that `fromJson` still reads but the current `toJson` no longer
writes is a migration and SHALL be carried by at least one fixture.

The corpus lives in `test/fixtures/backup_compat/<tag>/`: what each release
exported for the inputs in `tool/backup_compat/superset.json`, produced by
running that release's own serializers (`tool/backup_compat/generate.sh`,
which checks out each tag and swaps in a shim for any API the release
predates). The version in `pubspec.yaml` SHALL have fixtures, so a release
cannot ship without its format joining the corpus.

#### Scenario: A v0.0.5 backup keeps its dark theme

**Given** the v0.0.5 fixture, which wrote `themeMode: 2` for dark
**When** it is imported
**Then** the theme is dark with the blue accent, not system with purple

#### Scenario: A rename that forgets the old key fails the build

**Given** `kioskMode` is renamed in `toJson` and `fromJson` without reading
the old name
**When** `test/settings_backup_compat_test.dart` runs
**Then** every release from v0.2.7 fails "every key it wrote is still read"

#### Scenario: A release's link still opens

**Given** `links.json` of any release from v0.2.3
**When** each link is parsed at HEAD
**Then** it unwraps to the URL that release unwrapped, or is rejected as
that release rejected it
**And** no link makes the parser throw

#### Scenario: A release without fixtures fails the build

**Given** `pubspec.yaml` names a version with no
`test/fixtures/backup_compat/v<version>/`
**When** `test/settings_backup_compat_test.dart` runs
**Then** it fails, naming `tool/backup_compat/generate.sh HEAD`

---

### Requirement: BACKUP-014 - Stored Settings Are Read Field By Field

What an upgrade or an import reads SHALL survive any single odd value.

- `WebViewModel.fromJson` SHALL require only `initUrl`. Every other field of
  the wrong type reads as absent, and a malformed entry of a list (a cookie,
  a user script, a blocked cookie, a domain claim) is dropped while the
  rest are kept. The startup loader skips a site whose JSON throws and the
  next save deletes it, so a strict field turned one odd value into a lost
  site. `UserScriptConfig`, `UserProxySettings` and `Webspace` read the same
  way.
- A `kExportedAppPrefs` key SHALL be read through `readPrefAs`
  (`lib/settings/pref_read.dart`) or `readExportedAppPrefs`, never a typed
  `SharedPreferences` getter. Those throw on a stored value of another type,
  and v0.2.2 through v0.3.1 imports stored `globalPrefs` values under the
  file's JSON type; thrown inside `_restoreAppState`, it stopped the sites
  from loading.
- Every SharedPreferences key a release wrote (recorded per release in
  `prefs_writes.json`) SHALL still be read with the type it was written as,
  or be listed as retired with the reason
  (`test/js/prefs_key_history.test.js`).

#### Scenario: A mistyped field keeps its site

**Given** a site JSON (stored, or in a backup) whose `javascriptEnabled` is
`"yes"` and whose `cookies` list holds one string among valid cookies
**When** `WebViewModel.fromJson` reads it
**Then** the site loads with `javascriptEnabled` at its default and the
valid cookies, and every other field as written

#### Scenario: A QR link naming only a URL creates a site

**Given** a `webspace://qr/site/v1/` payload whose JSON is only
`{"initUrl": "https://qr.example/"}`
**When** the user accepts it in the review
**Then** a site for that URL is created with default settings, instead of
`fromJson` throwing on the absent `proxySettings`

#### Scenario: A mistyped stored pref does not stop startup

**Given** `showUrlBar` is stored as the String `"true"`
**When** the app starts
**Then** `showUrlBar` reads as its default and the sites load

---

### Requirement: BACKUP-013 - An Import Is Decided Before It Is Applied

`planSettingsImport` ([lib/services/settings_import_engine.dart](../../../lib/services/settings_import_engine.dart))
SHALL parse and check the whole backup before `_importSettings` touches
live state, and `_importSettings` SHALL read only the resulting plan after
it clears the site list. A backup that cannot be applied whole is refused
whole, with the user's sites untouched.

- `sites` and `webspaces` are the backup. A site without a string
  `initUrl`, or an entry of either list that is not an object, rejects the
  file.
- Every other field is optional. A value of the wrong type reads as absent;
  an entry of an optional list (`suggestedSites`, `globalUserScripts`,
  `contentBlockerLists`, `extraSections`) that does not parse is dropped.
- A `globalPrefs` value is applied under the registry's type, never the
  file's: a String stored under a key read with `getBool` would throw on
  every later read. An integral double is accepted for an int. Otherwise
  the default applies.
- The in-memory value and the persisted value of a pref come from the same
  resolved map, so a pref the backup does not name reads the same before
  and after a restart.
- A leading UTF-8 byte-order mark is ignored.

#### Scenario: A bad optional entry no longer half-applies an import

**Given** a backup whose sites are valid and whose `globalUserScripts`
has an entry with a numeric `id`
**When** the import runs
**Then** the sites, webspaces and prefs are applied
**And** the malformed script is dropped while the valid ones are restored
switched off

#### Scenario: A mistyped pref takes its default

**Given** a backup with `globalPrefs.showUrlBar: "true"` and
`globalPrefs.tabMaxWidth: 180.0`
**When** the import runs
**Then** `showUrlBar` is written as the bool default and `tabMaxWidth` as
the int 180

---

### Requirement: BACKUP-007 - Version Tagged Backups

Backups SHALL include a version tag for future compatibility.

#### Scenario: Include version in backup

**Given** settings are exported
**Then** the JSON includes `"version": 1`

---

### Requirement: BACKUP-008 - Menu Visibility

Import/Export options SHALL only appear when on the webspaces list screen.

#### Scenario: Hide menu when viewing site

**Given** the user is viewing a site webview
**When** the menu is opened
**Then** Import/Export options are not visible

---

## Backup File Format

```json
{
  "version": 1,
  "sites": [
    {
      "initUrl": "https://example.com",
      "currentUrl": "https://example.com/page",
      "name": "Example Site",
      "pageTitle": "Example - Homepage",
      "cookies": [
        {"name": "theme", "value": "dark", "domain": "example.com", "isSecure": false}
      ],
      "proxySettings": { "type": 0, "address": null },
      "javascriptEnabled": true,
      "userAgent": "",
      "thirdPartyCookiesEnabled": false
    }
  ],
  "webspaces": [
    {
      "id": "abc123-uuid",
      "name": "Work",
      "siteIndices": [0, 1, 2]
    }
  ],
  "themeMode": 2,
  "showUrlBar": false,
  "selectedWebspaceId": "__all_webspace__",
  "currentIndex": null,
  "exportedAt": "2024-01-15T10:30:00.000Z",
  "dnsBlockLevel": 3,
  "contentBlockerLists": [
    {
      "id": "easylist",
      "name": "EasyList",
      "url": "https://easylist.to/easylist/easylist.txt",
      "enabled": true
    }
  ]
}
```

`dnsBlockLevel` and `contentBlockerLists` are omitted entirely when the
source device had no such configuration; importers treat their absence as
"no change" (older backups simply lack the keys).

---

## Platform Support

| Platform | Export | Import |
|----------|--------|--------|
| Android  | Yes | Yes |
| iOS      | Yes | Yes |
| macOS    | Yes | Yes |
| Linux    | Yes | Yes |
| Windows  | Yes | Yes |
| Web      | Yes | Yes |

---

## Files

### Created
- `lib/services/settings_backup.dart` - Core backup service
- `test/settings_backup_test.dart` - Unit tests

### Modified
- `lib/main.dart` - Menu items and handlers; `_backupGlobalProxyAddress` /
  `_backupUserScriptCount` feed the confirmation dialog (BACKUP-006), and
  `sanitizeImportedSites` runs before live state is replaced (BACKUP-011)
- `lib/settings/app_prefs.dart` - `kTrustedHostsKey` deliberately absent from
  the registry (BACKUP-010)
- `pubspec.yaml` - Added `file_picker: ^11.0.2`
