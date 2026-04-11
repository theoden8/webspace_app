# User Scripts

## Status
**Implemented**

## Purpose

Allow users to inject custom JavaScript into webviews on a per-site basis, enabling personalization, automation, and enhanced browsing experiences.

## Problem Statement

Users often want to customize website behavior — hiding annoyances, injecting dark mode CSS, auto-filling forms, extracting data, or fixing broken layouts. Without user script support, these customizations require external tools or are impossible on mobile.

## Solution

Per-site user scripts stored in `WebViewModel`, injected via `flutter_inappwebview`'s `UserScript` API. Each script has a name, source code, injection timing (document start or end), and an enabled toggle. Scripts are managed through a dedicated UI accessible from per-site settings.

---

## Requirements

### Requirement: US-001 - Per-Site Script Storage

Each site SHALL support zero or more user scripts, each with a name, JavaScript source, injection time, and enabled flag.

#### Scenario: Add a user script to a site

**Given** a site with no user scripts
**When** the user adds a script with name "Dark Mode" and source `document.body.style.background = 'black';`
**Then** the script is stored in the site's `userScripts` list and persisted to SharedPreferences

#### Scenario: Scripts survive app restart

**Given** a site with user scripts configured
**When** the app is restarted
**Then** the user scripts are restored from SharedPreferences via `WebViewModel.fromJson()`

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
**Then** the JSON backup includes user scripts in each site's data

#### Scenario: Import settings with user scripts

**Given** a backup file containing user scripts
**When** settings are imported
**Then** user scripts are restored for each site

---

## Implementation Details

### Data Model

```dart
enum UserScriptInjectionTime { atDocumentStart, atDocumentEnd }

class UserScriptConfig {
  String name;
  String source;
  UserScriptInjectionTime injectionTime;
  bool enabled;
}
```

### WebViewModel Integration

- `userScripts` field: `List<UserScriptConfig>`, defaults to `[]`
- Serialized in `toJson()`, deserialized in `fromJson()` with `?? []` fallback
- Passed to `WebViewConfig` when creating the webview

### Injection Mechanism

Scripts are added to the `initialUserScripts` list in `WebViewFactory.createWebView()`:
- Group name `'user_scripts'` for identification
- Mapped to `inapp.UserScriptInjectionTime.AT_DOCUMENT_START` or `AT_DOCUMENT_END`
- Empty or disabled scripts are skipped

`initialUserScripts` only run on the first page load of the webview widget. For subsequent navigations (in-page navigation, `loadUrl` calls), scripts are re-injected:
- `atDocumentStart` scripts: re-injected in `onLoadStart`
- `atDocumentEnd` scripts: re-injected in `onLoadStop`

This matches the re-injection pattern used by content blocker CSS and ClearURLs.

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
- `callHandler` reference is captured at `DOCUMENT_START` before page code can tamper with it
- Response size limit: 5 MB
- URL must have a valid scheme and non-empty host
- Non-whitelisted URLs require explicit user approval via confirmation dialog

Scripts can also specify an optional `url` field for explicit CDN URL fetching with cached `urlSource`. At injection time, `fullSource = urlSource + source`.

### UI

- `UserScriptsScreen`: List of scripts with reorder, swipe-to-delete, enable/disable toggle. Edits sync to the model immediately.
- `UserScriptEditScreen`: Form with name, optional script URL with download button, injection time dropdown, enabled switch, monospace source editor, and play button with inline console output
- Accessed from per-site settings via "User Scripts" list tile

---

## Files

### Created
- `lib/settings/user_script.dart` — UserScriptConfig model with JSON serialization
- `lib/screens/user_scripts.dart` — Management and editor screens
- `test/user_script_test.dart` — Unit tests for model and WebViewModel integration

### Modified
- `lib/web_view_model.dart` — Added `userScripts` field, serialization, passed to WebViewConfig
- `lib/services/webview.dart` — Added `userScripts` to WebViewConfig, injection in createWebView
- `lib/screens/settings.dart` — Added "User Scripts" navigation tile

---

## Testing

### Unit Tests
```bash
fvm flutter test test/user_script_test.dart
```

### Manual Testing
1. Open a site's settings
2. Tap "User Scripts"
3. Add a script: name "Test", source `document.title = "Modified";`, injection time "At document end"
4. Save and reload the site
5. Verify the page title shows "Modified"
6. Disable the script and reload — title should revert to normal
7. Force-close and reopen the app — verify scripts persist
