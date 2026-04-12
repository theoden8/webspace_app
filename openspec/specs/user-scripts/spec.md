# User Scripts

## Status
**Implemented**

## Purpose

Allow users to inject custom JavaScript into webviews on a per-site or global basis, enabling personalization, automation, and enhanced browsing experiences. Supports loading external libraries from CDN URLs with CORS-bypassing fetch.

## Problem Statement

Users often want to customize website behavior — hiding annoyances, injecting dark mode CSS, auto-filling forms, extracting data, or fixing broken layouts. Without user script support, these customizations require external tools or are impossible on mobile.

## Solution

User scripts stored either per-site in `WebViewModel` or globally in app state, injected via `flutter_inappwebview`'s `UserScript` API. Each script has a name, source code, optional CDN URL, injection timing (document start or end), and an enabled toggle. Scripts are managed through a dedicated UI accessible from per-site settings. Global scripts run on all sites; per-site scripts run only on their configured site.

---

## Requirements

### Requirement: US-001 - Per-Site Script Storage

Each site SHALL support zero or more user scripts, each with a name, JavaScript source, optional URL, injection time, and enabled flag.

#### Scenario: Add a user script to a site

**Given** a site with no user scripts
**When** the user adds a script with name "Dark Mode" and source `document.body.style.background = 'black';`
**Then** the script is stored in the site's `userScripts` list and persisted to SharedPreferences

#### Scenario: Scripts survive app restart

**Given** a site with user scripts configured
**When** the app is restarted
**Then** the user scripts are restored from SharedPreferences via `WebViewModel.fromJson()`

### Requirement: US-001b - Global Script Storage

The app SHALL support global user scripts that run on all sites.

#### Scenario: Add a global user script

**Given** no global scripts configured
**When** the user adds a global script via Settings > Global Scripts
**Then** the script is stored in app-level state and persisted to SharedPreferences under `'globalUserScripts'`

#### Scenario: Global scripts run on all sites

**Given** a global script configured and enabled
**When** any site's webview loads a page
**Then** the global script is injected (global scripts run before per-site scripts)

#### Scenario: Global scripts survive app restart

**Given** global user scripts configured
**When** the app is restarted
**Then** the global scripts are restored from SharedPreferences

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

3. **`reinjectOnSpaNavigation`**: On SPA navigations (URL changes without full page load, detected via `onUpdateVisitedHistory`), re-runs only the user's `source` code (not the library from `urlSource`). The JS context persists on SPA navigations, so the library is still loaded — only the user's initialization code (e.g. `DarkReader.enable()`) needs to re-run.

#### Execution order within a single injection

When a script has both `urlSource` (cached library) and `source` (user code):
```
[shim: __wsFetch, appendChild/insertBefore intercept, fetch CORS fallback]
[urlSource: library code]       ← defines library API (e.g. window.DarkReader)
[source: user initialization]   ← calls library API (e.g. DarkReader.enable())
;null;                          ← prevents WebKit "unsupported type" error
```

The `;null;` suffix is appended to all injected scripts because WebKit (macOS/iOS) errors when `evaluateJavascript` returns `undefined`. Returning `null` (a serializable value) prevents this. All `evaluateJavascript` calls are also wrapped in try-catch at the Dart level via `_safeEval`.

### Requirement: US-003 - Script Management UI

Users SHALL be able to add, edit, delete, reorder, and toggle scripts from per-site settings.

#### Scenario: Add a new script

**Given** the user opens User Scripts from site settings
**When** they tap the + button
**Then** a script editor is shown with name, source, injection time, and enabled fields

#### Scenario: Edit an existing script

**Given** a site with user scripts
**When** the user taps a script in the list
**Then** the script editor opens pre-filled with the script's current values

#### Scenario: Delete a script

**Given** a site with user scripts
**When** the user swipes a script to dismiss
**Then** the script is removed from the list

#### Scenario: Toggle a script

**Given** a site with user scripts
**When** the user toggles the switch on a script
**Then** the script's enabled state changes without opening the editor

#### Scenario: Reorder scripts

**Given** a site with multiple user scripts
**When** the user drags a script via the drag handle (leading icon)
**Then** the script order changes. Drag handles are explicit (`buildDefaultDragHandles: false`) to avoid collision with the trailing toggle switch.

### Requirement: US-004 - Backward Compatibility

Legacy data without `userScripts` field SHALL be handled gracefully.

#### Scenario: Load legacy data

**Given** a `WebViewModel` JSON without the `userScripts` field
**When** `fromJson()` is called
**Then** `userScripts` defaults to an empty list

### Requirement: US-005 - Settings Backup Integration

User scripts SHALL be included in settings export/import.

#### Scenario: Export settings with user scripts

**Given** sites with user scripts configured
**When** settings are exported
**Then** the JSON backup includes user scripts in each site's data and global scripts at the top level

#### Scenario: Import settings with user scripts

**Given** a backup file containing user scripts
**When** settings are imported
**Then** user scripts are restored for each site and global scripts are restored to app state

---

## Implementation Details

### Data Model

```dart
enum UserScriptInjectionTime { atDocumentStart, atDocumentEnd }

class UserScriptConfig {
  String name;
  String source;
  /// Optional URL to fetch script source from (e.g., CDN-hosted library).
  /// Fetched at the Dart level, bypassing page CSP restrictions.
  String? url;
  /// Cached content downloaded from [url].
  String? urlSource;
  UserScriptInjectionTime injectionTime;
  bool enabled;

  /// The full script to inject: urlSource (if any) followed by source.
  String get fullSource { ... }
}
```

### WebViewModel Integration

- `userScripts` field: `List<UserScriptConfig>`, defaults to `[]`
- Serialized in `toJson()`, deserialized in `fromJson()` with `?? []` fallback
- Passed to `WebViewConfig` when creating the webview
- Global scripts are prepended: `[...globalUserScripts, ...userScripts]`

### Global Scripts Integration

- Stored in `_WebSpacePageState._globalUserScripts`
- Persisted to SharedPreferences under `'globalUserScripts'` key
- Loaded during `_restoreAppState()` via `_loadGlobalUserScripts()`
- Passed through `getWebView()` and `getController()` to merge with per-site scripts
- Included in `SettingsBackup` model for export/import

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
2. **`window.__wsFetch(url)`**: CORS-bypassing fetch that returns a standard `Response` object. User scripts can use this for libraries that need custom fetch methods (e.g. `DarkReader.setFetchMethod(window.__wsFetch)`).
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

- `UserScriptsScreen`: List of scripts with explicit drag handles (leading), swipe-to-delete, enable/disable toggle (trailing). Edits sync to the model immediately. Accepts a custom `title` parameter for distinguishing "Site Scripts" vs "Global Scripts".
- `UserScriptEditScreen`: Form with name, optional script URL (auto-downloads on save), injection time dropdown, enabled switch, monospace source editor, and play button with inline console output
- Settings screen shows two tiles: "Site Scripts" (per-site) and "Global Scripts" (shared across all sites)

---

## Files

### Created
- `lib/settings/user_script.dart` — UserScriptConfig model with JSON serialization, URL classification
- `lib/screens/user_scripts.dart` — Management and editor screens
- `lib/services/user_script_service.dart` — Injection service: shim, handlers, re-injection lifecycle
- `test/user_script_test.dart` — Unit tests for model and WebViewModel integration

### Modified
- `lib/web_view_model.dart` — Added `userScripts` field, serialization, global scripts merge in `getWebView`/`getController`
- `lib/services/webview.dart` — Added `userScripts` to WebViewConfig, injection in createWebView, SPA detection
- `lib/screens/settings.dart` — Added "Site Scripts" and "Global Scripts" navigation tiles
- `lib/main.dart` — Global user scripts state, persistence, backup/restore integration
- `lib/services/settings_backup.dart` — Added `globalUserScripts` to SettingsBackup model

---

## Testing

### Unit Tests
```bash
fvm flutter test test/user_script_test.dart
```

### Manual Testing

#### Basic script injection
1. Open a site's settings
2. Tap "Site Scripts"
3. Add a script: name "Test", source `document.title = "Modified";`, injection time "At document end"
4. Save and hit "Save Settings" to reload the site
5. Verify the page title shows "Modified"
6. Disable the script and reload — title should revert to normal
7. Force-close and reopen the app — verify scripts persist

#### CDN library loading (Dark Reader example)
1. Open a site's settings > Site Scripts (or Global Scripts)
2. Add a script: name "Dark Reader"
3. Set URL to `https://cdn.jsdelivr.net/npm/darkreader@4/darkreader.min.js`
4. Set injection time to "At document start"
5. Set source to:
   ```js
   DarkReader.setFetchMethod(window.__wsFetch);
   DarkReader.enable({ brightness: 100, contrast: 90 });
   ```
6. Save — URL should auto-download (check "Cached: XXXXX bytes" indicator)
7. Hit "Save Settings" — site should reload with dark mode
8. Navigate within the SPA — dark mode should re-apply on URL changes

#### Global scripts
1. Open any site's settings > "Global Scripts"
2. Add a script (e.g. Dark Reader as above)
3. Save and hit "Save Settings"
4. Switch to a different site — the global script should also run there
5. Force-close and reopen — global scripts should persist
