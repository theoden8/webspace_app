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
  "exportedAt": "2024-01-15T10:30:00.000Z"
}
```

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
- `pubspec.yaml` - Added `file_picker: ^8.0.0`
