# User Scripts

## Status
**Implemented**

## Purpose

Allow users to inject custom JavaScript into webviews on a per-site basis, enabling personalization, automation, and enhanced browsing experiences. Scripts can be defined once at the **global** level (shared source code + URL) and then **opted in per site**, so users don't have to copy the same source to every site where they want it to run. Supports loading external libraries from CDN URLs with CORS-bypassing fetch.

## Problem Statement

Users often want to customize website behavior — hiding annoyances, injecting dark mode CSS, auto-filling forms, extracting data, or fixing broken layouts. Without user script support, these customizations require external tools or are impossible on mobile.

Users also routinely want the SAME script on many sites (e.g. a pop-up remover, a reader-mode helper). Copy-pasting the source into every site's settings is error-prone and painful to maintain. Sharing the definition globally while still giving each site control over whether the script runs solves this.

## Solution

Scripts are stored in two places:

- **Per-site** in `WebViewModel.userScripts` — a list of site-specific scripts with their own `enabled` toggle.
- **Globally** in app state (`_globalUserScripts`) — a shared library of script definitions (name, source, optional CDN URL, injection time).

Global scripts are **not implicitly active** anywhere. They run on a site only when that site opts in by adding the script's stable `id` to its `WebViewModel.enabledGlobalScriptIds` set. This set is edited from the per-site User Scripts screen via a per-site toggle. Global scripts have NO master "enabled" switch — per-site opt-in is the only enable control.

Each script has a stable `id` (auto-generated at creation time, preserved across JSON roundtrips and edits) that the opt-in set references. Injection is performed via `flutter_inappwebview`'s `UserScript` API.

---

## Requirements

### Requirement: US-001 - Per-Site Script Storage

Each site SHALL support zero or more user scripts, each with a stable id, a name, JavaScript source, optional URL, injection time, and enabled flag.

#### Scenario: Add a user script to a site

**Given** a site with no user scripts
**When** the user adds a script with name "Dark Mode" and source `document.body.style.background = 'black';`
**Then** the script is stored in the site's `userScripts` list and persisted to SharedPreferences

#### Scenario: Scripts survive app restart

**Given** a site with user scripts configured
**When** the app is restarted
**Then** the user scripts are restored from SharedPreferences via `WebViewModel.fromJson()`

### Requirement: US-001b - Global Script Library

The app SHALL support a shared library of global user scripts. Each script has a stable `id`. Global scripts are NOT active on any site by default — they run only on sites that explicitly opt them in.

#### Scenario: Add a global user script

**Given** no global scripts configured
**When** the user adds a global script via App Settings > Global User Scripts
**Then** the script is stored in app-level state with a generated stable `id` and persisted to SharedPreferences under `'globalUserScripts'`

#### Scenario: Global scripts do NOT run automatically

**Given** a global script is defined in the global library
**And** no site has opted it in
**When** any site's webview loads a page
**Then** the global script is NOT injected

#### Scenario: Global scripts run only on opted-in sites

**Given** a global script with id `us-abc-123`
**And** site A has `us-abc-123` in its `enabledGlobalScriptIds`
**And** site B does NOT
**When** both sites load a page
**Then** the script is injected on site A and NOT on site B

#### Scenario: No master enable toggle for global scripts

**Given** a global script
**When** the user views the Global User Scripts screen in App Settings
**Then** the tile shows no enable switch. Per-site opt-in is the only enable control.

#### Scenario: Global scripts survive app restart

**Given** global user scripts configured
**When** the app is restarted
**Then** the global scripts (including their ids) are restored from SharedPreferences

### Requirement: US-001c - Per-Site Global Opt-In

Each `WebViewModel` SHALL store a `Set<String> enabledGlobalScriptIds` indicating which global scripts run on it. The set is independent of other sites.

#### Scenario: Opt a site into a global script

**Given** a site with an empty `enabledGlobalScriptIds` and a global script `us-abc-123`
**When** the user toggles the global script's switch ON in the site's User Scripts screen
**Then** `us-abc-123` is added to the site's `enabledGlobalScriptIds` and persisted; the script runs on the next page load

#### Scenario: Opt out of a global script on one site only

**Given** sites A and B both opted into global script `us-abc-123`
**When** the user toggles the global script OFF from site A's User Scripts screen
**Then** `us-abc-123` is removed from site A's `enabledGlobalScriptIds` only; site B is unaffected

#### Scenario: Deleting a global script cleans up opt-ins for the current site

**Given** the current site has opted into global script `us-abc-123`
**When** the user deletes that global script from the per-site User Scripts screen (long-press → Delete)
**Then** the script is removed from the global library AND from the current site's `enabledGlobalScriptIds`. Other sites may retain the stale id; stale ids do not match any global and are simply ignored during injection.

#### Scenario: Editing a global script preserves its id

**Given** a global script with id `us-abc-123`
**When** the user edits its name, source, URL, or injection time
**Then** the id is preserved so existing per-site opt-ins continue to reference the correct script

### Requirement: US-001d - Migration from Pre-Opt-In Data

Data saved before the opt-in model (where global scripts ran on every site) SHALL not silently lose script functionality. On first launch after upgrade, sites with empty `enabledGlobalScriptIds` SHALL be opted into every currently-defined global script. A migration marker in SharedPreferences SHALL prevent the one-time fill from re-running after the user starts curating per-site opt-ins.

#### Scenario: First launch after upgrade

**Given** a SharedPreferences state from the pre-opt-in model with N global scripts and M sites, no `globalUserScriptsOptInMigrated` marker
**When** the app starts
**Then** every site's `enabledGlobalScriptIds` is populated with all N global script ids (for sites whose set was empty), the `globalUserScriptsOptInMigrated` marker is set, and the opt-ins are persisted

#### Scenario: Subsequent launches do not re-migrate

**Given** the `globalUserScriptsOptInMigrated` marker is set
**When** the app starts
**Then** `enabledGlobalScriptIds` is NOT modified, even if the user has since opted sites out of scripts

### Requirement: US-002 - Script Injection

Enabled user scripts SHALL be injected into the webview at the configured injection time.

#### Scenario: Inject at document start

**Given** a site with an enabled script set to inject at document start
**When** the webview loads a page
**Then** the script runs before the page's own scripts execute

#### Scenario: Inject at document end

**Given** a site with an enabled script set to inject at document end
**When** the webview finishes loading a page
**Then** the script runs after the DOM is fully loaded

#### Scenario: Disabled scripts are not injected

**Given** a site with a disabled user script
**When** the webview loads a page
**Then** the script is NOT injected

### Requirement: US-002b - Script Injection Lifecycle

Scripts SHALL be injected at the correct time through multiple mechanisms to handle all navigation types.

#### Injection mechanisms

1. **`initialUserScripts` (native WKUserScript / Android UserScript)**: Set at WebView creation time. Persists across navigations. The primary injection mechanism — handles full page loads automatically.

2. **`reinjectOnLoadStart` / `reinjectOnLoadStop`**: Re-injects simple scripts (without `urlSource`) via `evaluateJavascript` as a safety net. Scripts with `urlSource` are **skipped** to avoid racing with the native WKUserScript mechanism, which would cause ReferenceErrors.

3. **`reinjectOnSpaNavigation`**: On SPA navigations (URL changes without full page load, detected via `onUpdateVisitedHistory`), re-runs only the user's `source` code (not the library from `urlSource`). The JS context persists on SPA navigations, so the library is still loaded — only the user's initialization code (e.g. `MyLib.init()`) needs to re-run.

#### Execution order within a single injection

When a script has both `urlSource` (cached library) and `source` (user code):
```
[shim: __wsFetch, appendChild/insertBefore intercept, fetch CORS fallback]
[urlSource: library code]       ← defines library API (e.g. window.MyLib)
[source: user initialization]   ← calls library API (e.g. MyLib.init())
;null;                          ← prevents WebKit "unsupported type" error
```

The `;null;` suffix is appended to all injected scripts because WebKit (macOS/iOS) errors when `evaluateJavascript` returns `undefined`. Returning `null` (a serializable value) prevents this. All `evaluateJavascript` calls are also wrapped in try-catch at the Dart level via `_safeEval`.

### Requirement: US-003 - Script Management UI

The User Scripts screen SHALL operate in two distinct modes:

- **Per-site mode** — reached from a site's Settings. Lists the site's own scripts (with an `enabled` toggle, reorder, swipe-to-delete, Make Global) AND the global library (each global shown with a per-site opt-in toggle that edits this site's `enabledGlobalScriptIds`).
- **Global library mode** — reached from App Settings > Global User Scripts. Lists the global scripts themselves. Each tile shows a "Global" badge and has NO enable switch (globals have no master toggle). Add / edit / delete / reorder / swipe-to-delete operate on the global library.

#### Scenario: Add a new script

**Given** the user opens User Scripts from site settings
**When** they tap the + button
**Then** a script editor is shown with name, source, injection time, and enabled fields

#### Scenario: Edit an existing script

**Given** a site with user scripts
**When** the user taps a script in the list
**Then** the script editor opens pre-filled with the script's current values

#### Scenario: Delete a site script via swipe

**Given** a site with user scripts
**When** the user swipes a script to dismiss
**Then** a confirmation dialog appears asking "Delete \"<name>\"?" with Cancel/Delete actions. On confirm, the script is removed from the list; on cancel, the script remains.

#### Scenario: Delete a site script via long-press

**Given** a site with user scripts
**When** the user long-presses a site script
**Then** a bottom sheet appears with "Delete" and (when global scripts are supported) "Make Global" actions. Tapping "Delete" shows a confirmation dialog; on confirm, the script is removed.

#### Scenario: Delete a global script from the per-site screen

**Given** global scripts are configured and the user has opened User Scripts from site settings
**When** the user long-presses a global script tile
**Then** a bottom sheet appears with a "Delete" action. Tapping "Delete" shows a confirmation dialog warning "It will stop running on all sites."; on confirm, the global script is removed from the global list and stops running on all sites.

#### Scenario: Cancel delete confirmation

**Given** the delete confirmation dialog is shown
**When** the user taps Cancel or dismisses the dialog
**Then** the script is NOT deleted and remains in its list

#### Scenario: Toggle a script

**Given** a site with user scripts
**When** the user toggles the switch on a script
**Then** the script's enabled state changes without opening the editor

#### Scenario: Reorder scripts

**Given** a site with multiple user scripts
**When** the user drags a script via the drag handle (leading icon)
**Then** the script order changes. Drag handles are explicit (`buildDefaultDragHandles: false`) to avoid collision with the trailing toggle switch.

#### Scenario: View global scripts in per-site screen

**Given** global scripts are configured
**When** the user opens User Scripts from any site's settings
**Then** global scripts appear at the top with a "Global" badge and globe icon, followed by site-specific scripts below a divider. The trailing switch on each global tile toggles this site's opt-in (not a master flag). Tap-to-edit opens the global script editor; changes save to the global list and preserve the script's `id`.

#### Scenario: Opt-in toggle on a global tile

**Given** a site in per-site mode
**When** the user flips the Switch on a global script tile from off to on
**Then** the script's `id` is added to this site's `enabledGlobalScriptIds`. Flipping it back off removes the `id`. No other site is affected.

#### Scenario: Global library tile has no enable switch

**Given** the user is on App Settings > Global User Scripts
**When** the list renders
**Then** each tile shows a "Global" badge and a drag handle, but NO trailing Switch. The tile is tap-to-edit and long-press-to-delete. Reorder and swipe-to-delete are available.

#### Scenario: Promote site script to global

**Given** the user opens User Scripts from site settings
**When** they long-press a site-specific script and select "Make Global" from the bottom sheet
**Then** a confirmation dialog offers to move it to global scripts. On confirmation, the script is moved from the site list to the global list, and the current site is automatically opted into the promoted script so it keeps running here.

### Requirement: US-004 - Backward Compatibility

Legacy data without `userScripts`, `enabledGlobalScriptIds`, or script `id` fields SHALL be handled gracefully.

#### Scenario: Load legacy data without userScripts

**Given** a `WebViewModel` JSON without the `userScripts` field
**When** `fromJson()` is called
**Then** `userScripts` defaults to an empty list

#### Scenario: Load legacy data without enabledGlobalScriptIds

**Given** a `WebViewModel` JSON without the `enabledGlobalScriptIds` field
**When** `fromJson()` is called
**Then** `enabledGlobalScriptIds` defaults to an empty set

#### Scenario: Load legacy script without id

**Given** a `UserScriptConfig` JSON without the `id` field
**When** `fromJson()` is called
**Then** a fresh unique id is generated so future opt-in references remain stable

### Requirement: US-005 - Settings Backup Integration

User scripts SHALL be included in settings export/import.

#### Scenario: Export settings with user scripts

**Given** sites with user scripts configured
**When** settings are exported
**Then** the JSON backup includes user scripts in each site's data and global scripts at the top level

#### Scenario: Import settings with user scripts

**Given** a backup file containing user scripts
**When** settings are imported
**Then** user scripts are restored for each site, per-site `enabledGlobalScriptIds` sets are restored, and global scripts (with their `id`s) are restored to app state

---

## Implementation Details

### Data Model

```dart
enum UserScriptInjectionTime { atDocumentStart, atDocumentEnd }

class UserScriptConfig {
  /// Stable unique identifier. Auto-generated at creation time, preserved
  /// across JSON roundtrips and edits. Referenced by per-site opt-in sets.
  final String id;
  String name;
  String source;
  /// Optional URL to fetch script source from (e.g., CDN-hosted library).
  /// Fetched at the Dart level, bypassing page CSP restrictions.
  String? url;
  /// Cached content downloaded from [url].
  String? urlSource;
  UserScriptInjectionTime injectionTime;
  /// For SITE-SPECIFIC scripts, controls whether the script is injected.
  /// For GLOBAL scripts this field is ignored — per-site opt-in via
  /// [WebViewModel.enabledGlobalScriptIds] is the only enable control.
  bool enabled;

  /// The full script to inject: urlSource (if any) followed by source.
  String get fullSource { ... }
}
```

### WebViewModel Integration

- `userScripts` field: `List<UserScriptConfig>`, defaults to `[]`
- `enabledGlobalScriptIds` field: `Set<String>`, defaults to `{}`. Stores ids of global scripts that should run on this site.
- Serialized in `toJson()`; deserialized in `fromJson()` with `?? []` / `?? {}` fallbacks
- Passed to `WebViewConfig` when creating the webview
- Injection merge at webview creation time:
  ```dart
  userScripts: [
    ...globalUserScripts.where((g) => enabledGlobalScriptIds.contains(g.id)),
    ...userScripts,
  ]
  ```
  Global scripts the site opted into run first, then site-specific scripts.

### Global Scripts Integration

- Stored in `_WebSpacePageState._globalUserScripts`
- Persisted to SharedPreferences under `'globalUserScripts'` key
- Loaded during `_restoreAppState()` via `_loadGlobalUserScripts()`
- After sites load, `_migrateGlobalScriptOptIn()` one-time-fills empty per-site opt-in sets with all current global ids (gated by the `globalUserScriptsOptInMigrated` SharedPreferences marker)
- Passed through `getWebView()` and `getController()` to the merge site-filter
- Included in `SettingsBackup` model for export/import. Per-site `enabledGlobalScriptIds` are exported as part of each site's JSON.

### Injection Mechanism

Scripts are added to the `initialUserScripts` list in `WebViewFactory.createWebView()`:
- Group name `'user_scripts'` for identification
- Mapped to `inapp.UserScriptInjectionTime.AT_DOCUMENT_START` or `AT_DOCUMENT_END`
- Empty or disabled scripts are skipped

`initialUserScripts` (WKUserScript on macOS/iOS, native injection on Android) persist across navigations and handle re-injection automatically. Additionally:

- **Full page loads**: Scripts with `urlSource` rely on `initialUserScripts`. Simple scripts (no `urlSource`) are also re-injected via `evaluateJavascript` in `onLoadStart`/`onLoadStop` as a safety net.
- **SPA navigations**: Only the user's `source` code is re-run (library already loaded in JS context). Detected via `onUpdateVisitedHistory` when the URL changes without a corresponding `onLoadStart`.

### JavaScript Shim

A shim is injected at `AT_DOCUMENT_START` before user scripts. It provides:

1. **`appendChild`/`insertBefore` interception**: Catches `<script src="...">` DOM insertions for whitelisted CDN URLs and fetches them at the Dart level (bypassing CSP).
2. **`window.__wsFetch(url)`**: CORS-bypassing fetch that returns a standard `Response` object. User scripts can use this for libraries that need custom fetch methods (e.g. `MyLib.setFetchMethod(window.__wsFetch)`).
3. **`window.fetch` CORS fallback**: Patches `window.fetch` to fall back to `__wsFetch` on TypeError (CORS/network failures).
4. **Deduplication**: Tracks loaded URLs to avoid double-loading when both `initialUserScripts` and re-injection run.

Handler names are randomized per webview instance for security.

### External Dependency Resolution

User scripts that load external libraries via `document.createElement('script')` with a `src` attribute would normally be blocked by the page's Content Security Policy (CSP). A JavaScript shim intercepts these DOM insertions and resolves them at the Dart level:

1. Shim is injected at `AT_DOCUMENT_START` before user scripts, patching `appendChild` and `insertBefore`
2. When a `<script src="...">` element is appended, the shim sends the URL to a Dart handler
3. Dart classifies the URL via `classifyScriptFetchUrl()`
4. If whitelisted: Dart fetches the URL via HTTP (bypassing CSP) and injects the content natively
5. If not whitelisted: Dart shows a confirmation dialog; user must approve before fetching
6. If blocked scheme: request is rejected immediately
7. The script element's `onload` / `onerror` callback is fired based on the result

#### URL Classification (`classifyScriptFetchUrl`)

| Status | Condition | Behavior |
|--------|-----------|----------|
| `whitelisted` | URL host matches a trusted CDN domain (exact or subdomain) | Fetched without user confirmation |
| `requiresConfirmation` | Valid `http://` or `https://` URL not on the whitelist | User sees a confirmation dialog before fetching |
| `blocked` | Non-http(s) scheme, empty host, or invalid URL | Rejected immediately, `onerror` fires |

#### Trusted CDN Whitelist

The following domains (and their subdomains) are fetched without confirmation:

| Domain | Purpose |
|--------|---------|
| `cdn.jsdelivr.net` | jsDelivr CDN (npm, GitHub) |
| `unpkg.com` | unpkg CDN (npm) |
| `cdnjs.cloudflare.com` | Cloudflare CDNJS |
| `cdn.cloudflare.com` | Cloudflare CDN |
| `raw.githubusercontent.com` | GitHub raw file content |
| `gist.githubusercontent.com` | GitHub Gist raw content |
| `gitlab.com` | GitLab raw content |
| `ajax.googleapis.com` | Google Hosted Libraries |
| `ajax.aspnetcdn.com` | Microsoft Ajax CDN |
| `code.jquery.com` | jQuery CDN |
| `cdn.skypack.dev` | Skypack CDN |
| `esm.sh` | ESM CDN |
| `ga.jspm.io` | jspm CDN |

Subdomain matching: `sub.cdn.jsdelivr.net` matches `cdn.jsdelivr.net`. Partial matches are rejected: `evil-unpkg.com` does NOT match `unpkg.com`.

#### Blocked URL Schemes

`javascript:`, `data:`, `blob:`, `file://`, `ftp://`, and any non-http(s) scheme.

#### Security Measures

- Only `http://` and `https://` URLs are intercepted by the JS shim; other schemes fall through to normal (CSP-governed) DOM behavior
- Handler name is randomized per webview instance (page code cannot guess it)
- `callHandler` reference is captured lazily on first use before page code can tamper with it
- Response size limit: 5 MB
- URL must have a valid scheme and non-empty host
- Non-whitelisted URLs require explicit user approval via confirmation dialog

### URL Source (CDN Library Loading)

Scripts can specify an optional `url` field pointing to a CDN-hosted library. The library content is:
- **Downloaded automatically on save** — when the user saves a script with a URL, the content is fetched via HTTP and cached in `urlSource`
- **Re-downloaded on URL change** — if the URL is modified, the library is re-fetched on next save
- **Cleared when URL is removed** — removing the URL field clears `urlSource`
- **Persisted** — `url` and `urlSource` are included in JSON serialization and the deep copy in `UserScriptsScreen`

At injection time: `fullSource = urlSource + '\n' + source`

### UI

- `UserScriptsScreen` operates in two modes selected by the `isGlobalLibrary` flag and the presence of `enabledGlobalScriptIds`:
  - **Per-site mode** (`enabledGlobalScriptIds` non-null, `isGlobalLibrary` false): the screen shows globals at the top (each with a "Global" badge and a per-site opt-in Switch that edits `enabledGlobalScriptIds`), then a divider, then the site's own scripts with drag handles, an enabled Switch, swipe-to-delete, and a long-press action sheet (Delete / Make Global).
  - **Global library mode** (`isGlobalLibrary` true): the screen shows the global scripts themselves, each with a "Global" badge and a drag handle but NO enabled Switch. Tap-to-edit, long-press for Delete (no Make Global), swipe-to-delete, and reorder are supported. The FAB adds a new global script.
- `UserScriptEditScreen`: Form with name, optional script URL (auto-downloads on save), injection time dropdown, enabled switch (meaningful for site scripts only), monospace source editor, and play button with inline console output. When editing an existing script, the script's `id` is preserved so per-site opt-in references remain valid.
- Per-site settings: "User Scripts" tile — subtitle shows the count of active site scripts and globals opted in for this site.
- App settings: "Global User Scripts" tile — subtitle shows the total count of global scripts defined with the note "opt in per site".

---

## Files

### Created
- `lib/settings/user_script.dart` — UserScriptConfig model with JSON serialization, URL classification
- `lib/screens/user_scripts.dart` — Management and editor screens
- `lib/services/user_script_service.dart` — Injection service: shim, handlers, re-injection lifecycle
- `test/user_script_test.dart` — Unit tests for model and WebViewModel integration

### Modified
- `lib/settings/user_script.dart` — Added stable `id` field (auto-generated, preserved in JSON roundtrips)
- `lib/web_view_model.dart` — Added `userScripts` and `enabledGlobalScriptIds` fields, serialization, and the per-site global filter in `getWebView`/`getController`
- `lib/services/webview.dart` — Added `userScripts` to WebViewConfig, injection in createWebView, SPA detection
- `lib/screens/user_scripts.dart` — Per-site opt-in Switch for globals, `isGlobalLibrary` mode for App Settings, id-preserving edits
- `lib/screens/settings.dart` — "User Scripts" tile passes `enabledGlobalScriptIds` and its onChanged callback
- `lib/screens/app_settings.dart` — "Global User Scripts" section, `isGlobalLibrary: true`
- `lib/main.dart` — Global user scripts state, persistence, `_migrateGlobalScriptOptIn`, backup/restore integration
- `lib/services/settings_backup.dart` — Added `globalUserScripts` to SettingsBackup model (per-site opt-ins ride along in each site's JSON)

---

## Testing

### Unit Tests
```bash
fvm flutter test test/user_script_test.dart
```

### Manual Testing

#### Basic script injection
1. Open a site's settings
2. Tap "User Scripts"
3. Add a script: name "Test", source `document.title = "Modified";`, injection time "At document end"
4. Save and hit "Save Settings" to reload the site
5. Verify the page title shows "Modified"
6. Disable the script and reload — title should revert to normal
7. Force-close and reopen the app — verify scripts persist

#### CDN library loading
1. Open a site's settings > User Scripts (or App Settings > User Scripts for global)
2. Add a script: name "Lodash"
3. Set URL to `https://cdn.jsdelivr.net/npm/lodash@4/lodash.min.js`
4. Set injection time to "At document start"
5. Set source to:
   ```js
   document.title = 'lodash ' + _.VERSION;
   ```
6. Save — URL should auto-download (check "Cached: XXXXX bytes" indicator)
7. Hit "Save Settings" — site should reload with the page title set to `lodash <version>`
8. Navigate within the SPA — the library should remain loaded on URL changes

#### Global scripts (library + per-site opt-in)
1. Open App Settings (gear icon) > "Global User Scripts"
2. Add a global script (e.g. `document.title = '[global] ' + document.title;`). Note: tiles have NO enable switch here.
3. Navigate back. Reload a site — the global script must NOT yet run (no site has opted in).
4. Open that site's Settings > "User Scripts". The global tile appears at the top with a per-site Switch. Toggle it ON.
5. Tap "Save Settings" (or navigate back to reload) — the script now runs on THIS site.
6. Switch to a different site — the global script must NOT run there (it hasn't opted in).
7. Opt the second site in from its User Scripts screen — the script now runs on both.
8. Toggle OFF on the first site — it stops running there only; the second site is unaffected.
9. Force-close and reopen — global scripts and per-site opt-ins should persist.

#### Migration from pre-opt-in data
1. On a build that still has the pre-opt-in layout (sites without `enabledGlobalScriptIds`), add a global script that previously ran everywhere.
2. Upgrade / reinstall with this build.
3. On first launch: every existing site should be auto-opted into all existing globals (one-time fill).
4. Subsequent launches: opting a site out should stick; the migration must not re-fill.

#### Promote site script to global
1. Open a site's settings > "User Scripts"
2. Long-press on a site script
3. Tap "Make Global" in the bottom sheet
4. Confirm the "Make Global" dialog
5. The script moves to global scripts and is removed from the site list; the current site is automatically opted in so the script keeps running on it.
6. Open App Settings > "Global User Scripts" to verify it's there.
7. Visit a different site's User Scripts screen — the promoted script appears as a global with the per-site Switch OFF (not opted in).

#### Delete scripts with confirmation
1. Open a site's settings > "User Scripts"
2. Long-press a site script — a bottom sheet shows "Delete" and "Make Global"
3. Tap "Delete" — a confirmation dialog appears. Tap Cancel; verify the script remains.
4. Repeat and confirm Delete; verify the script is removed.
5. Swipe a site script from right to left — the same confirmation dialog appears. Cancel and verify the script remains; swipe again and confirm, verify it's removed.
6. With global scripts configured, long-press a global script (globe icon) in the per-site screen — a bottom sheet shows "Delete". Confirm delete and verify the global script is removed (stops running on all sites).
7. In App Settings > "User Scripts", swipe a global script and confirm deletion; verify it's removed.
