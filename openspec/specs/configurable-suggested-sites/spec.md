# Configurable Suggested Sites Specification

## Purpose

Allow users to customize the suggested sites shown on the "Add new site" screen. The default list varies by build flavor: fdroid ships with an empty list (no third-party site suggestions), while other flavors include a curated default set.

## Status

- **Date**: 2026-03-28
- **Status**: Completed

---

## Requirements

### Requirement: SUGGEST-001 - Flavor-Dependent Defaults

The default suggested sites list SHALL depend on the build flavor.

#### Scenario: fdroid flavor has empty defaults

**Given** the app is built with the `fdroid` flavor
**When** the user opens the "Add new site" screen for the first time
**Then** no suggested sites are shown
**And** an empty state message says "No suggested sites. Tap + to add some."

#### Scenario: Other flavors have curated defaults

**Given** the app is built with the `fmain` or `fdebug` flavor
**When** the user opens the "Add new site" screen for the first time
**Then** the curated default list of suggested sites is shown (DuckDuckGo, Claude, ChatGPT, etc.)

---

### Requirement: SUGGEST-002 - Add Custom Suggested Site

Users SHALL be able to add sites to the suggestions list.

#### Scenario: Add a new suggestion

**Given** the user is on the "Add new site" screen
**When** the user taps the "+" button in the "Suggested Sites" header
**Then** a dialog appears with Name and URL fields
**And** after entering valid data and tapping "Add", the site appears in the suggestions grid

#### Scenario: URL auto-prefixing

**Given** the user enters a URL without a protocol (e.g. `example.com`)
**When** the user confirms the addition
**Then** the URL is prefixed with `https://`

#### Scenario: Invalid input rejected

**Given** the user leaves the Name or URL field empty
**When** the user taps "Add"
**Then** nothing happens (the dialog stays open)

---

### Requirement: SUGGEST-003 - Remove Suggested Site

Users SHALL be able to remove sites from the suggestions list.

#### Scenario: Remove a suggestion via long-press

**Given** the suggestions grid contains sites
**When** the user long-presses a suggestion tile
**Then** a confirmation dialog appears asking "Remove [site name]?"
**And** tapping "Remove" deletes the suggestion from the list

#### Scenario: Cancel removal

**Given** the removal confirmation dialog is shown
**When** the user taps "Cancel"
**Then** the suggestion remains in the list

---

### Requirement: SUGGEST-004 - Persistence

User customizations to the suggested sites list SHALL be persisted across app restarts.

#### Scenario: Customizations survive restart

**Given** the user has added or removed suggested sites
**When** the app is closed and reopened
**Then** the customized suggestions list is restored

#### Scenario: No customization uses flavor defaults

**Given** the user has never modified the suggestions list
**When** the app starts
**Then** the flavor-appropriate default list is shown

---

### Requirement: SUGGEST-005 - Settings Backup Integration

Suggested sites SHALL be included in settings backup/restore.

#### Scenario: Export includes suggested sites

**Given** the user has customized their suggested sites
**When** settings are exported
**Then** the backup JSON includes a `suggestedSites` array

#### Scenario: Import restores suggested sites

**Given** a backup contains a `suggestedSites` array
**When** settings are imported
**Then** the suggested sites list is restored from the backup

#### Scenario: Import without suggested sites

**Given** a backup from an older version without `suggestedSites`
**When** settings are imported
**Then** the suggested sites list is unchanged (keeps current customization or flavor defaults)

---

### Requirement: SUGGEST-006 - Suggestion Tile Interaction

Tapping a suggested site SHALL open a confirmation dialog to add the site, same as the existing behavior.

#### Scenario: Add site from suggestion

**Given** the suggestions grid shows "GitHub"
**When** the user taps the "GitHub" tile
**Then** a dialog appears pre-filled with the GitHub URL
**And** the user can toggle incognito mode
**And** tapping "Add" creates the site

---

## Data Model

### SiteSuggestion

| Field | Type | Description |
|-------|------|-------------|
| name | String | Display name for the site |
| url | String | Full URL (including protocol) |
| domain | String | Domain used for favicon display |

### SharedPreferences Key

| Key | Type | Description |
|-----|------|-------------|
| `suggested_sites` | String (JSON) | Serialized list of SiteSuggestion objects. Absent = use flavor defaults. |

### Backup JSON Format

```json
{
  "suggestedSites": [
    { "name": "DuckDuckGo", "url": "https://duckduckgo.com", "domain": "duckduckgo.com" },
    { "name": "GitHub", "url": "https://github.com", "domain": "github.com" }
  ]
}
```

---

## Flavor Detection

The build flavor is detected at runtime via:

```dart
const flavor = String.fromEnvironment('FLUTTER_APP_FLAVOR');
```

Flutter automatically sets `FLUTTER_APP_FLAVOR` when building with `--flavor`. The fdroid flavor results in an empty default list; all other flavors use the curated list defined in `kDefaultSuggestions`.

---

## Default Suggested Sites (non-fdroid)

| Name | URL | Domain |
|------|-----|--------|
| DuckDuckGo | https://duckduckgo.com | duckduckgo.com |
| Claude | https://claude.ai | claude.ai |
| ChatGPT | https://chatgpt.com | chatgpt.com |
| Perplexity | https://perplexity.ai | perplexity.ai |
| Instagram | https://instagram.com | instagram.com |
| Facebook | https://facebook.com | facebook.com |
| X (Twitter) | https://x.com | x.com |
| Google Chat | https://chat.google.com | chat.google.com |
| GitHub | https://github.com | github.com |
| GitLab | https://gitlab.com | gitlab.com |
| Gitea | https://gitea.com | gitea.com |
| Codeberg | https://codeberg.org | codeberg.org |
| Slack | https://slack.com | slack.com |
| Discord | https://discord.com/login | discord.com |
| Mattermost | https://mattermost.com | mattermost.com |
| Gmail | https://gmail.com | gmail.com |
| LinkedIn | https://linkedin.com | linkedin.com |
| Reddit | https://reddit.com | reddit.com |
| Mastodon | https://mastodon.social | mastodon.social |
| Bluesky | https://bsky.app | bsky.app |
| Hugging Face | https://huggingface.co | huggingface.co |

---

## Files

### Created
- `lib/services/suggested_sites_service.dart` - Service for loading, saving, and managing suggested sites with flavor-aware defaults

### Modified
- `lib/screens/add_site.dart` - Accept configurable suggestions, add/remove UI
- `lib/main.dart` - Load suggested sites on startup, pass to AddSiteScreen, include in backup
- `lib/services/settings_backup.dart` - Optional `suggestedSites` field in SettingsBackup

---

## Manual Test Procedure

### Test: Verify fdroid empty defaults
1. Build with `flutter build apk --flavor fdroid`
2. Fresh install (clear app data)
3. Tap "+" to add a site
4. **Expected**: Empty suggestions grid with "No suggested sites" message

### Test: Verify non-fdroid defaults
1. Build with `flutter build apk --flavor fmain` or `fdebug`
2. Fresh install
3. Tap "+" to add a site
4. **Expected**: Full curated suggestions grid (21 sites)

### Test: Add a custom suggestion
1. On "Add new site" screen, tap the "+" next to "Suggested Sites"
2. Enter Name: "Wikipedia", URL: "wikipedia.org"
3. Tap "Add"
4. **Expected**: "Wikipedia" tile appears in the grid with favicon

### Test: Remove a suggestion
1. Long-press any suggestion tile
2. Confirm removal
3. **Expected**: Tile disappears from grid

### Test: Persistence
1. Add/remove suggestions
2. Close and reopen the app
3. Open "Add new site"
4. **Expected**: Customized list is preserved

### Test: Backup/restore
1. Customize suggestions
2. Export settings
3. Clear app data, reimport
4. **Expected**: Customized suggestions are restored
