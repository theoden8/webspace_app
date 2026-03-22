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

### UI

- `UserScriptsScreen`: List of scripts with reorder, swipe-to-delete, enable/disable toggle
- `UserScriptEditScreen`: Form with name, injection time dropdown, enabled switch, monospace source editor
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
