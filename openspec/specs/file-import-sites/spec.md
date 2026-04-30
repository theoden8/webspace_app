# File Import Sites Specification

## Purpose

Allow users to add a site by importing a local HTML file (.html/.htm) from their device. The HTML content is loaded directly in the webview, enabling offline viewing of saved web pages.

## Status

- **Date**: 2026-04-30
- **Status**: Completed

---

## Requirements

### Requirement: IMPORT-001 - Import Button on Add Site Screen

An "Import HTML file" button SHALL be shown on the "Add new site" screen.

#### Scenario: Button visibility

**Given** the user opens the "Add new site" screen
**When** the screen is displayed
**Then** an "Import HTML file" button is visible below the "Add Site" button

---

### Requirement: IMPORT-002 - File Selection

Users SHALL be able to pick an HTML file via the system file picker.

#### Scenario: Supported file types

**Given** the user taps the "Import HTML file" button
**When** the file picker opens
**Then** it filters for `.html` and `.htm` files

#### Scenario: User cancels file picker

**Given** the file picker is open
**When** the user cancels without selecting a file
**Then** nothing happens and the "Add new site" screen remains

---

### Requirement: IMPORT-003 - Site Creation from HTML File

The imported HTML file SHALL be added as a new site.

#### Scenario: Site name derived from filename

**Given** the user selects a file named `my-page.html`
**When** the site is created
**Then** the site name is `my-page` (filename without extension)

#### Scenario: Site URL uses file:/// scheme (three slashes)

**Given** the user selects a file named `report.html`
**When** the site is created
**Then** the site's initUrl is `file:///report.html`

The three-slash form (empty authority) is required: the two-slash form
`file://report.html` parses with `report.html` as the URL host and an
empty path, which chromium rejects with `ERR_INVALID_URL` on any direct
load (incognito mode, post-upgrade cache wipe, manual reload). Sites
persisted before this fix are migrated on load via
`migrateLegacyFileImportUrl` in [lib/utils/url_utils.dart](../../../lib/utils/url_utils.dart).

#### Scenario: HTML content stored via HtmlImportStorage

**Given** the user selects an HTML file
**When** the site is created (non-incognito)
**Then** the file content is saved to `HtmlImportStorage` for the new site's siteId
**And** the webview loads the content via `initialHtml` on first display

The import store ([lib/services/html_import_storage.dart](../../../lib/services/html_import_storage.dart))
is distinct from `HtmlCacheService`. Imports are the only copy of the
user-supplied content, so the store is **not** wiped on app upgrade —
unlike the cache, which holds re-fetchable snapshots of remote pages.

#### Scenario: Imports survive app upgrade

**Given** the user previously imported an HTML file
**When** the app is upgraded to a newer version
**Then** the imported HTML is still available — `HtmlImportStorage`
persists across upgrades.

#### Scenario: Migration from legacy HtmlCacheService

**Given** an installation from before HtmlImportStorage existed where
imported HTML was held in `HtmlCacheService`
**When** the new version starts up after the upgrade
**Then** prior to the cache wipe, `_migrateFileImportsToStorage` (in
[lib/main.dart](../../../lib/main.dart)) reads each file-import
WebViewModel's siteId from SharedPreferences, decrypts its cache entry
with the still-current key, and writes it into HtmlImportStorage. The
subsequent cache wipe drops the now-redundant copy.

#### Scenario: Incognito mode

**Given** the user has incognito mode enabled
**When** an HTML file is imported
**Then** the HTML content is NOT persisted to HtmlImportStorage
**And** the webview renders the "imported file unavailable" fallback
(via `buildFileImportFallbackHtml`) instead of attempting to load the
synthetic `file:///<filename>` URL — there's no real file on disk for
the import, so a direct load would surface as `ERR_FILE_NOT_FOUND`.

#### Scenario: No page title fetch

**Given** a site is created from an HTML file
**When** the site is added
**Then** no HTTP page title fetch is attempted (unlike URL-based sites)

---

### Requirement: IMPORT-004 - Webview Rendering

The imported HTML content SHALL render correctly in the webview.

#### Scenario: HTML loaded via cached HTML mechanism

**Given** a site was created from an HTML file
**When** the webview is created
**Then** the HTML content is loaded via the existing `initialHtml`/`initialData` mechanism in `WebViewFactory.createWebView()`

#### Scenario: Links in imported HTML

**Given** an imported HTML page contains external links
**When** the user clicks a link
**Then** the link opens in a nested browser (since file:// domain won't match any web domain)

---

## Data Model

No new data models. Imported HTML sites use the existing `WebViewModel` with:
- `initUrl`: `file:///<filename>` (e.g., `file:///page.html`) — three
  slashes; see IMPORT-003 above for why
- `name`: Filename without extension
- HTML content stored in `HtmlImportStorage` keyed by `siteId`. Persistent;
  not wiped on app upgrade (the user's only copy of the file). Distinct
  from `HtmlCacheService`, which holds re-fetchable page snapshots and
  *is* wiped on upgrade.

---

## Files

### Added
- `lib/services/html_import_storage.dart` - Persistent AES-encrypted store for user-imported HTML, separate from the cache so imports survive app upgrades

### Modified
- `lib/screens/add_site.dart` - Added `_importHtmlFile()` method and "Import HTML file" button
- `lib/main.dart` - Updated `_addSite()` to handle `htmlContent` in result and save to `HtmlImportStorage`; init/preload of the import store; `_migrateFileImportsToStorage` pre-wipe hook copies legacy entries out of `HtmlCacheService`; orphan-cleanup and per-site delete touch both stores; the webview's `initialHtml` reads from `HtmlImportStorage` for `file://` sites and the snapshot save path skips them
- `lib/services/html_cache_service.dart` - `initialize()` accepts a `beforeUpgradeWipe` callback that runs after key load but before the wipe, used to migrate file imports out
- `lib/utils/url_utils.dart` - Added `migrateLegacyFileImportUrl` for legacy two-slash imports
- `lib/web_view_model.dart` - Applies migration in `WebViewModel.fromJson` for `initUrl`/`currentUrl`
- `lib/services/webview.dart` - Renders `buildFileImportFallbackHtml` when no import is on disk for a file-import site

---

## Manual Test Procedure

### Test: Import an HTML file
1. Save a simple HTML file on the device (e.g., `test-page.html`)
2. Open the app, tap "+" to add a site
3. Tap "Import HTML file"
4. Select the HTML file
5. **Expected**: Site is added with name "test-page", content renders in webview

### Test: Import HTML file with incognito
1. Enable incognito mode on the Add Site screen
2. Import an HTML file
3. **Expected**: Site is added, content renders, but HTML is not persisted

### Test: Cancel file picker
1. Tap "Import HTML file"
2. Cancel the file picker
3. **Expected**: Nothing happens, Add Site screen remains

### Test: Links in imported HTML open in nested browser
1. Import an HTML file containing `<a href="https://example.com">link</a>`
2. Tap the link
3. **Expected**: Link opens in nested browser (not in the same webview)
