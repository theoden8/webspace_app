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

#### Scenario: Show import confirmation

**Given** a valid backup file is selected
**When** the file is parsed
**Then** a dialog shows "3 sites, 2 webspaces, exported 2026-01-15"
**And** warns "This will replace all current settings"

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
- `lib/main.dart` - Menu items and handlers
- `pubspec.yaml` - Added `file_picker: ^11.0.2`
