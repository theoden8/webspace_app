# Configurable Suggested Sites Specification

## Purpose

Allow users to customize the suggested sites shown on the "Add new site" screen. Every build ships an empty list: the app suggests no third-party site of its own, and no flavor changes the compiled Dart, so the F-Droid and store builds can be reproduced from one source.

Once the user downloads the popular sites list, the address field on the same screen completes what is typed from it, on the device.

## Status

- **Date**: 2026-03-28
- **Status**: Completed

---

## Requirements

### Requirement: SUGGEST-001 - Empty Default

The default suggested sites list SHALL be empty in every build, whatever its flavor.

#### Scenario: Fresh install shows no suggestions

**Given** the user has never saved a suggestions list
**When** the user opens the "Add new site" screen
**Then** no suggested sites are shown
**And** an empty state message says "No suggested sites"
**And** the "+" button to add one is shown

#### Scenario: Upgrade from a build that shipped defaults

**Given** a build before this one showed a curated default list the user never edited
**When** the user upgrades and opens the "Add new site" screen
**Then** no suggested sites are shown, since that list was never saved

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

#### Scenario: No customization shows none

**Given** the user has never modified the suggestions list
**When** the app starts
**Then** the suggestions list is empty

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
**Then** the suggested sites list is unchanged

---

### Requirement: SUGGEST-006 - Suggestion Tile Interaction

Tapping a suggested site SHALL open a confirmation dialog to add the site, same as the existing behavior.

#### Scenario: Add site from suggestion

**Given** the suggestions grid shows "GitHub"
**When** the user taps the "GitHub" tile
**Then** a dialog appears pre-filled with the GitHub URL
**And** the user can toggle incognito mode
**And** tapping "Add" creates the site

### Requirement: SUGGEST-007 - Popular Sites While Typing

While a popular sites list is downloaded, the address field of the "Add new site" screen SHALL offer the sites whose address begins with what is typed, best ranked first, matched on the device.

#### Scenario: Typing offers matching sites

**Given** the popular sites list is downloaded
**When** the user types `red` in the address field
**Then** up to six sites beginning with `red` are offered, `reddit.com` first
**And** picking one fills the address field with it

#### Scenario: What counts as a typed address

**Given** the popular sites list is downloaded
**When** the user types fewer than two characters, a path, a port or a space
**Then** nothing is offered
**And** a scheme or a leading `www.` is ignored

#### Scenario: One entry per site

**Given** the list names `www.youtube.com` and `m.youtube.com`
**Then** `youtube.com` is offered once
**And** only https origins on the default port are offered

#### Scenario: Ranking within a group

**Given** CrUX ranks origins only in groups (1000, 5000, 10000, ...)
**Then** within a group, a site the list names under more hostnames comes first, then the shorter host

#### Scenario: Nothing typed leaves the device

**When** the user types in the address field
**Then** the matching reads only the downloaded list, and no option's icon is fetched

---

### Requirement: SUGGEST-008 - Popular Sites List Download

The popular sites list SHALL be fetched only when the user taps Download, on its App Settings row (Behaviour, "Adding sites") or on the add-site screen's offer (SUGGEST-012), through the app-wide proxy, and only its top rows, and SHALL be kept on the device until cleared.

#### Scenario: Nothing until the user downloads

**Given** the user never tapped Download on the Popular sites row
**Then** nothing is fetched and the address field offers nothing

#### Scenario: Only the top of the list is fetched

**When** the user taps Download
**Then** the app asks the Chrome UX Report top list (github.com/zakird/crux-top-lists, data CC BY 4.0) for its first 256 KB through the app-wide proxy
**And** keeps the rows down to rank group 10000, about ten thousand origins
**And** a row cut off at the end of the range is dropped

#### Scenario: Kept until cleared

**Given** the list was downloaded
**When** the app restarts
**Then** the stored list is read where it is used (the add-site screen and its settings row), never at launch
**And** clearing it from the row removes the file and every match

#### Scenario: A failed download keeps the list

**Given** a list is stored
**When** a download fails, or brings back no usable row
**Then** the stored list stays as it was

---

### Requirement: SUGGEST-009 - Popular Sites Filter

The popular sites list SHALL filter out hosts under the top-level domains `.cn`, `.ru`, `.by`, `.kp`, `.рф`, `.бел`, `.中国`, `.中國`, `.xxx`, `.sex`, `.porn`, `.adult` and `.sexy`, and hosts carrying one of the filtered words in `kTopSitesFilteredWords`, on every read of the list; and SHALL drop, as it downloads, the rows under a domain one of its filter lists names, each fetched with the list (`TopSitesFilter`): HaGeZi's NSFW, gambling and pop-up ads lists (`wildcard/nsfw-onlydomains.txt`, `wildcard/gambling.mini-onlydomains.txt`, `wildcard/popupads-onlydomains.txt`) and its most abused top-level domains (`wildcard/spam-tlds-onlydomains.txt`) less the sites its allow list names (`wildcard/spam-tlds-allow-onlydomains.txt`), all under the DNS blocklist's mirrors, and StevenBlack's porn hosts (`alternates/porn-only/hosts`, from GitHub or jsDelivr). A filter's allow list exempts rows from that filter's own list only.

#### Scenario: A filtered domain is never offered

**Given** the downloaded list names `https://yandex.ru`
**When** the user types `ya`
**Then** `yandex.ru` is not offered

#### Scenario: Gambling sites are dropped as the list downloads

**Given** HaGeZi's gambling list names `bet365.com`
**When** the user downloads the popular sites list
**Then** `bet365.com` is neither stored nor offered

#### Scenario: An abused top-level domain is dropped unless its allow list names the site

**Given** HaGeZi's most abused TLDs name `icu`, and its allow list names `kept.icu`
**When** the user downloads the popular sites list
**Then** `cheap.icu` is dropped and `kept.icu` is kept
**And** a site another filter names is dropped even where the TLD allow list names it

#### Scenario: Adult sites are dropped as the list downloads

**Given** HaGeZi's NSFW list names `noodlemagazine.com`
**When** the user downloads the popular sites list
**Then** `hot.noodlemagazine.com` is neither stored nor offered

#### Scenario: No filter list, no download

**Given** no source serves one of the filter lists
**When** the user taps Download
**Then** the download fails, the CrUX list is not fetched, and the stored list stays as it was

#### Scenario: The filter holds on stored lists

**Given** a list stored by an earlier build
**When** it is read
**Then** the filter of the running build applies to it

---

### Requirement: SUGGEST-010 - Pinned Addresses and Sites Already Added

The address field SHALL offer each address in `kTopSitesPinned` first among its matches whenever the popular sites list is downloaded and what is typed begins that address or one of its words, and SHALL NOT offer any address, pinned or ranked, at which the user already has a site.

#### Scenario: A pinned address comes first

**Given** the popular sites list is downloaded
**When** the user types the start of a pinned address or of one of its words
**Then** that address is the first option

#### Scenario: Not offered once added

**Given** the user has a site at a pinned address
**When** the user types the start of it
**Then** that address is not offered

#### Scenario: Sites already added are not offered

**Given** the user has a site at `https://www.github.com`
**When** the user types `gi`
**Then** `github.com` is not offered

### Requirement: SUGGEST-011 - Keep Filter Lists

The Popular sites row SHALL offer a "Keep filter lists" switch, off by default, that trades storage for bandwidth: while it is on, a download keeps the filter lists it fetched in app cache storage, compressed, and a download within 30 days (`kTopSitesFiltersKept`) filters through the kept lists instead of fetching them again. While it is off, nothing but the filtered rows is kept, and turning it off removes the kept lists.

#### Scenario: Off, every download fetches every list

**Given** the switch is off
**When** the user downloads the popular sites list twice
**Then** each download fetches every filter list, and only the rows are stored

#### Scenario: On, a refresh within a month fetches only the rows

**Given** the switch is on and the user downloaded the list today
**When** the user downloads it again
**Then** only the CrUX rows are fetched, and the kept lists filter them

#### Scenario: Kept lists expire

**Given** the switch is on and the lists were kept more than 30 days ago
**When** the user downloads the list
**Then** every filter list is fetched again and kept

#### Scenario: Turning it off frees the storage

**Given** the switch is on and the lists are kept
**When** the user turns it off
**Then** the kept lists are removed

### Requirement: SUGGEST-012 - Offer the List Where It Is Used

While the popular sites list is not downloaded, the add-site screen SHALL offer it under the address field ("Suggest popular sites as you type", with the Popular sites row's explanation behind a hint button and a Download button), until it is downloaded or the user dismisses the offer. Dismissing it SHALL hide it for good (`AppPref.topSitesOffer`) and say where the list can still be downloaded.

#### Scenario: A new user is offered the list

**Given** the popular sites list was never downloaded
**When** the user opens the add-site screen
**Then** the offer shows under the address field

#### Scenario: Download from the offer

**Given** the offer shows
**When** the user taps Download
**Then** the list downloads as from its settings row, the offer goes, and typing suggests sites

#### Scenario: Dismissed for good

**Given** the offer shows
**When** the user taps its close button
**Then** the offer goes and a message names App Settings > Behaviour
**And** the add-site screen does not offer it again

#### Scenario: No offer once there is a list

**Given** the popular sites list is downloaded
**When** the user opens the add-site screen
**Then** no offer shows

---

## Data Model

### SiteSuggestion

| Field | Type | Description |
|-------|------|-------------|
| name | String | Display name for the site |
| url | String | Full URL (including protocol) |
| domain | String | Domain used for favicon display |

### SharedPreferences Keys

| Key | Type | Description |
|-----|------|-------------|
| `suggested_sites` | String (JSON) | Serialized list of SiteSuggestion objects. Absent = empty. |
| `top_sites_last_updated` | String (ISO 8601) | When the popular sites list was downloaded. |
| `top_sites_filters_kept` | String (ISO 8601) | When the kept filter lists were fetched (SUGGEST-011). |
| `topSitesKeepFilters` | bool | The Keep filter lists switch, an `AppPref` that rides backups. |
| `topSitesOffer` | bool | Whether the add-site screen still offers the list (SUGGEST-012), an `AppPref`. |

The popular sites rows are `rows.csv` in the app cache's `top_sites` directory, as CrUX wrote them less the filtered rows; kept filter lists sit beside them as `<filter>.gz`.

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

## Files

### Created
- `lib/services/suggested_sites_service.dart` - Service for loading and saving the suggested sites

- `lib/services/top_sites_engine.dart` - Popular sites: which rows count, the filter, the pinned address, what a typed address matches
- `lib/services/top_sites_service.dart` - Popular sites download, storage and load

### Modified
- `lib/screens/add_site.dart` - Accept configurable suggestions, add/remove UI; the address field completes from the popular sites
- `lib/main.dart` - Load suggested sites on startup, pass to AddSiteScreen, include in backup
- `lib/services/settings_backup.dart` - Optional `suggestedSites` field in SettingsBackup

---

## Manual Test Procedure

### Test: Verify empty defaults
1. Build any flavor
2. Fresh install (clear app data)
3. Tap "+" to add a site
4. **Expected**: Empty suggestions grid with "No suggested sites" message

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
