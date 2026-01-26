# Demo Mode Specification

## Purpose

Provide a demo mode system that seeds realistic test data for screenshot generation while preserving user data through separate key storage.

## Status

- **Status**: Completed
- **Date**: 2026-01-26
- **Use Cases**: Screenshot tests, app demonstrations, development testing

---

## Overview

Demo mode is a testing feature that:
1. **Seeds realistic demo data** (sites, webspaces) for screenshots
2. **Prevents saves** during demo sessions via `isDemoMode` flag
3. **Preserves user data** by using separate `demo_*` SharedPreferences keys
4. **Auto-cleans** demo data on next normal app startup

This enables screenshot tests to run with consistent demo data without affecting users' actual app data.

---

## Requirements

### Requirement: DEMO-001 - Demo Data Seeding

The system SHALL provide a function to seed realistic demo data for testing.

#### Scenario: Seed demo data

- **WHEN** `seedDemoData()` is called
- **THEN** 8 demo sites are created:
  - DuckDuckGo (https://duckduckgo.com)
  - Piped (https://piped.video)
  - Nitter (https://nitter.net)
  - Reddit (https://www.reddit.com)
  - GitHub (https://github.com)
  - Hacker News (https://news.ycombinator.com)
  - Weights & Biases (https://wandb.ai)
  - Wikipedia (https://www.wikipedia.org)
- **AND** 4 demo webspaces are created:
  - **All** - Shows all sites
  - **Work** - GitHub, Hacker News, W&B (indices 4, 5, 6)
  - **Privacy** - DuckDuckGo, Piped, Nitter (indices 0, 1, 2)
  - **Social** - Nitter, Reddit, Wikipedia (indices 2, 3, 7)
- **AND** demo mode is enabled (`isDemoMode = true`)
- **AND** marker flag `wasDemoMode` is set in SharedPreferences

---

### Requirement: DEMO-002 - Save Prevention

The system SHALL prevent all data persistence operations when demo mode is active.

#### Scenario: Block saves during demo mode

- **GIVEN** `isDemoMode` is true
- **WHEN** app attempts to save via:
  - `_saveWebViewModels()`
  - `_saveWebspaces()`
  - `_saveCurrentIndex()`
  - `_saveThemeMode()`
  - `_saveShowUrlBar()`
  - `_saveSelectedWebspaceId()`
  - `CookieSecureStorage.saveCookies()`
  - `CookieSecureStorage.saveCookiesForUrl()`
  - `CookieSecureStorage.clearCookies()`
  - `CookieSecureStorage.removeOrphanedCookies()`
- **THEN** the save operation returns early without persisting
- **AND** no data is written to SharedPreferences or secure storage

---

### Requirement: DEMO-003 - User Data Isolation

Demo data SHALL NOT overwrite or modify user data in SharedPreferences.

#### Scenario: Isolate demo data from user data

- **GIVEN** user has sites saved in SharedPreferences key `webViewModels`
- **WHEN** `seedDemoData()` is called
- **THEN** demo sites are written to `demo_webViewModels` key
- **AND** user data in `webViewModels` key remains unchanged
- **AND** same isolation applies to all keys:

| User Key | Demo Key | Purpose |
|----------|----------|---------|
| `webViewModels` | `demo_webViewModels` | Sites list |
| `webspaces` | `demo_webspaces` | Workspaces list |
| `selectedWebspaceId` | `demo_selectedWebspaceId` | Active workspace |
| `currentIndex` | `demo_currentIndex` | Selected site index |
| `themeMode` | `demo_themeMode` | Theme setting |
| `showUrlBar` | `demo_showUrlBar` | URL bar visibility |

---

### Requirement: DEMO-004 - Demo Mode Detection

The system SHALL provide a way to detect if app is running in or was in demo mode.

#### Scenario: Check demo mode status

- **WHEN** `isDemoModeActive()` is called
- **THEN** it returns true if `wasDemoMode` marker is set in SharedPreferences
- **AND** it returns false otherwise

---

### Requirement: DEMO-005 - Demo Data Cleanup

Demo data SHALL be automatically removed when app starts normally after demo session.

#### Scenario: Clear demo data on normal startup

- **GIVEN** `wasDemoMode` marker is true in SharedPreferences
- **AND** app starts in normal mode (not screenshot test)
- **WHEN** `clearDemoDataIfNeeded()` is called
- **THEN** all `demo_*` keys are removed from SharedPreferences
- **AND** `wasDemoMode` marker is removed
- **AND** user data in regular keys remains intact

---

### Requirement: DEMO-006 - Conditional Data Loading

The system SHALL load from demo or user keys based on demo mode status.

#### Scenario: Load demo data during screenshot test

- **GIVEN** `isDemoModeActive()` returns true
- **WHEN** `_restoreAppState()` runs during app startup
- **THEN** app loads data from `demo_*` keys
- **AND** app displays demo sites and webspaces

#### Scenario: Load user data during normal startup

- **GIVEN** `isDemoModeActive()` returns false
- **WHEN** `_restoreAppState()` runs during app startup
- **THEN** `clearDemoDataIfNeeded()` is called first
- **AND** app loads data from regular keys
- **AND** app displays user's actual sites and webspaces

---

## Architecture

### System Components

```
┌─────────────────────────────────────────────────────────┐
│                    Integration Test                     │
│              integration_test/screenshot_test.dart      │
│                                                          │
│              await seedDemoData()                        │
└───────────────────────┬─────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────┐
│                  lib/demo_data.dart                     │
│                                                          │
│  Global State:                                           │
│    bool isDemoMode = false                              │
│                                                          │
│  Functions:                                              │
│    ┌─────────────────────────────────────────┐         │
│    │ seedDemoData()                          │         │
│    │  1. Set wasDemoMode = true in SP        │         │
│    │  2. Set isDemoMode = true in memory     │         │
│    │  3. Create 8 demo sites                 │         │
│    │  4. Create 4 demo workspaces            │         │
│    │  5. Write to demo_* keys                │         │
│    └─────────────────────────────────────────┘         │
│                                                          │
│    ┌─────────────────────────────────────────┐         │
│    │ isDemoModeActive()                      │         │
│    │  → Check wasDemoMode flag in SP         │         │
│    └─────────────────────────────────────────┘         │
│                                                          │
│    ┌─────────────────────────────────────────┐         │
│    │ clearDemoDataIfNeeded()                 │         │
│    │  1. Check wasDemoMode flag              │         │
│    │  2. Remove all demo_* keys              │         │
│    │  3. Remove wasDemoMode marker           │         │
│    └─────────────────────────────────────────┘         │
└───────────────────────┬─────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────┐
│               SharedPreferences Storage                  │
│                                                          │
│  User Data (always preserved):                           │
│    webViewModels: [...]                                 │
│    webspaces: [...]                                     │
│    selectedWebspaceId: "..."                            │
│                                                          │
│  Demo Data (created/removed dynamically):                │
│    demo_webViewModels: [...]  ← Created by seedDemoData │
│    demo_webspaces: [...]      ← Removed by clearDemo... │
│    demo_selectedWebspaceId: "..."                       │
│                                                          │
│  Control:                                                │
│    wasDemoMode: true/false                              │
└─────────────────────────────────────────────────────────┘
```

### Data Flow - Screenshot Test Session

```
1. Screenshot Test Starts
   └─> seedDemoData() called
       ├─> Set wasDemoMode = true (in SharedPreferences)
       ├─> Set isDemoMode = true (in memory)
       ├─> Write demo data to demo_* keys
       └─> User data in regular keys UNTOUCHED

2. App Launches During Test
   └─> _restoreAppState() called
       ├─> isDemoModeActive() returns true
       ├─> Load from demo_* keys
       └─> Display demo sites/workspaces

3. User Interacts During Test
   └─> User taps/navigates/changes settings
       ├─> App tries to save changes
       ├─> isDemoMode check returns true
       └─> Save operations blocked (return early)

4. Test Completes
   └─> Screenshots captured
       └─> App closes
```

### Data Flow - Normal App Startup After Test

```
1. User Opens App
   └─> _restoreAppState() called
       ├─> isDemoModeActive() returns true
       └─> clearDemoDataIfNeeded() called
           ├─> Remove demo_webViewModels
           ├─> Remove demo_webspaces
           ├─> Remove demo_* keys
           └─> Remove wasDemoMode marker

2. Load User Data
   └─> Load from regular keys
       ├─> webViewModels
       ├─> webspaces
       └─> User's original data restored ✓

3. Normal Operation
   └─> isDemoMode = false
       └─> Saves work normally
```

---

## Data Models

### Demo Sites

```dart
final sites = <WebViewModel>[
  WebViewModel(
    initUrl: 'https://duckduckgo.com',
    name: 'DuckDuckGo',
  ),
  WebViewModel(
    initUrl: 'https://piped.video',
    name: 'Piped',
  ),
  WebViewModel(
    initUrl: 'https://nitter.net',
    name: 'Nitter',
  ),
  WebViewModel(
    initUrl: 'https://www.reddit.com',
    name: 'Reddit',
  ),
  WebViewModel(
    initUrl: 'https://github.com',
    name: 'GitHub',
  ),
  WebViewModel(
    initUrl: 'https://news.ycombinator.com',
    name: 'Hacker News',
  ),
  WebViewModel(
    initUrl: 'https://wandb.ai',
    name: 'Weights & Biases',
  ),
  WebViewModel(
    initUrl: 'https://www.wikipedia.org',
    name: 'Wikipedia',
  ),
];
```

### Demo Webspaces

```dart
final webspaces = <Webspace>[
  Webspace.all(), // The "All" webspace

  Webspace(
    id: 'webspace_work',
    name: 'Work',
    siteIndices: [4, 5, 6], // GitHub, Hacker News, W&B
  ),

  Webspace(
    id: 'webspace_privacy',
    name: 'Privacy',
    siteIndices: [0, 1, 2], // DuckDuckGo, Piped, Nitter
  ),

  Webspace(
    id: 'webspace_social',
    name: 'Social',
    siteIndices: [2, 3, 7], // Nitter, Reddit, Wikipedia
  ),
];
```

### SharedPreferences Keys

| Key Name | Type | Demo Variant | Description |
|----------|------|--------------|-------------|
| `webViewModels` | List<String> | `demo_webViewModels` | JSON-serialized list of sites |
| `webspaces` | List<String> | `demo_webspaces` | JSON-serialized list of workspaces |
| `selectedWebspaceId` | String | `demo_selectedWebspaceId` | ID of active workspace |
| `currentIndex` | int | `demo_currentIndex` | Index of selected site (10000 = none) |
| `themeMode` | int | `demo_themeMode` | Theme mode enum value (0=light, 1=dark, 2=system) |
| `showUrlBar` | bool | `demo_showUrlBar` | URL bar visibility setting |
| `wasDemoMode` | bool | N/A | Marker flag for demo mode detection |

### Global State

```dart
/// In-memory flag indicating demo mode is active
/// When true, all save operations are blocked
bool isDemoMode = false;
```

---

## Implementation

### Core Functions

#### `seedDemoData()` - Initialize Demo Mode

**Location**: `lib/demo_data.dart`

**Purpose**: Seed demo data for screenshot tests

**Behavior**:
1. Set `wasDemoMode = true` in SharedPreferences (marker)
2. Set `isDemoMode = true` in memory (blocks saves)
3. Create 8 demo sites
4. Create 4 demo webspaces (All, Work, Privacy, Social)
5. Serialize to JSON
6. Write to `demo_*` keys in SharedPreferences
7. Verify data was written correctly
8. Print confirmation messages

**Called by**: `integration_test/screenshot_test.dart` before app launch

**Example**:
```dart
Future<void> seedDemoData() async {
  final prefs = await SharedPreferences.getInstance();

  // Set marker and flag
  await prefs.setBool(_demoModeMarkerKey, true);
  isDemoMode = true;

  // Create demo data
  final sites = <WebViewModel>[...];
  final webspaces = <Webspace>[...];

  // Serialize and save to demo keys
  final sitesJson = sites.map((s) => jsonEncode(s.toJson())).toList();
  final webspacesJson = webspaces.map((w) => jsonEncode(w.toJson())).toList();

  await prefs.setStringList(demoWebViewModelsKey, sitesJson);
  await prefs.setStringList(demoWebspacesKey, webspacesJson);
  await prefs.setString(demoSelectedWebspaceIdKey, kAllWebspaceId);
  await prefs.setInt(demoCurrentIndexKey, 10000);
  await prefs.setInt(demoThemeModeKey, 0);
  await prefs.setBool(demoShowUrlBarKey, false);
}
```

---

#### `isDemoModeActive()` - Check Demo Status

**Location**: `lib/demo_data.dart`

**Purpose**: Determine if app is running in or was in demo mode

**Returns**: `Future<bool>` - true if `wasDemoMode` marker is set

**Called by**: `lib/main.dart` in `_restoreAppState()`

**Example**:
```dart
Future<bool> isDemoModeActive() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_demoModeMarkerKey) ?? false;
}
```

---

#### `clearDemoDataIfNeeded()` - Clean Demo Data

**Location**: `lib/demo_data.dart`

**Purpose**: Remove demo data when app starts normally after screenshot test

**Behavior**:
1. Check if `wasDemoMode` marker is set
2. If set:
   - Remove all `demo_*` keys from SharedPreferences
   - Remove `wasDemoMode` marker
   - Print cleanup confirmation
3. If not set: do nothing

**Called by**: `lib/main.dart` in `_restoreAppState()` when not in demo mode

**Example**:
```dart
Future<void> clearDemoDataIfNeeded() async {
  final prefs = await SharedPreferences.getInstance();
  final wasDemoMode = prefs.getBool(_demoModeMarkerKey) ?? false;

  if (wasDemoMode) {
    await prefs.remove(demoWebViewModelsKey);
    await prefs.remove(demoWebspacesKey);
    await prefs.remove(demoSelectedWebspaceIdKey);
    await prefs.remove(demoCurrentIndexKey);
    await prefs.remove(demoThemeModeKey);
    await prefs.remove(demoShowUrlBarKey);
    await prefs.remove(_demoModeMarkerKey);
  }
}
```

---

#### `_restoreAppState()` - Conditional Data Loading

**Location**: `lib/main.dart`

**Purpose**: Load appropriate data (demo or user) based on mode

**Behavior**:
1. Call `isDemoModeActive()` to check status
2. If demo mode active:
   - Set key variables to `demo_*` variants
   - Load from demo keys
3. If demo mode not active:
   - Call `clearDemoDataIfNeeded()` to clean up
   - Set key variables to regular variants
   - Load from regular keys
4. Load webspaces and webviews with appropriate keys
5. Restore theme, URL bar, and other settings

**Example**:
```dart
Future<void> _restoreAppState() async {
  final bool demoModeActive = await isDemoModeActive();

  String webViewModelsKey;
  String webspacesKey;
  String selectedWebspaceIdKey;
  String currentIndexKey;
  String themeModeKey;
  String showUrlBarKey;

  if (demoModeActive) {
    // Demo mode: load from demo_* keys
    webViewModelsKey = demoWebViewModelsKey;
    webspacesKey = demoWebspacesKey;
    selectedWebspaceIdKey = demoSelectedWebspaceIdKey;
    currentIndexKey = demoCurrentIndexKey;
    themeModeKey = demoThemeModeKey;
    showUrlBarKey = demoShowUrlBarKey;
  } else {
    // Normal mode: clear demo data and load from regular keys
    await clearDemoDataIfNeeded();
    webViewModelsKey = 'webViewModels';
    webspacesKey = 'webspaces';
    selectedWebspaceIdKey = 'selectedWebspaceId';
    currentIndexKey = 'currentIndex';
    themeModeKey = 'themeMode';
    showUrlBarKey = 'showUrlBar';
  }

  // Load data using determined keys
  await _loadWebspaces(webspacesKey, selectedWebspaceIdKey);
  await _loadWebViewModels(webViewModelsKey);
  // ... load other settings
}
```

---

### Save Blocking Mechanism

All save methods check `isDemoMode` flag and return early if true.

**Location**: `lib/main.dart`, `lib/services/cookie_secure_storage.dart`

**Example**:
```dart
Future<void> _saveWebViewModels() async {
  if (isDemoMode) return; // Don't persist in demo mode
  SharedPreferences prefs = await SharedPreferences.getInstance();
  // ... save logic
}

Future<void> _saveWebspaces() async {
  if (isDemoMode) return; // Don't persist in demo mode
  SharedPreferences prefs = await SharedPreferences.getInstance();
  // ... save logic
}

// CookieSecureStorage methods
Future<void> saveCookies(Map<String, List<UnifiedCookie>> cookiesByUrl) async {
  if (isDemoMode) return; // Don't persist in demo mode
  // ... save logic
}
```

**Blocked Operations**:
- `_saveWebViewModels()`
- `_saveWebspaces()`
- `_saveCurrentIndex()`
- `_saveThemeMode()`
- `_saveShowUrlBar()`
- `_saveSelectedWebspaceId()`
- `CookieSecureStorage.saveCookies()`
- `CookieSecureStorage.saveCookiesForUrl()`
- `CookieSecureStorage.clearCookies()`
- `CookieSecureStorage.removeOrphanedCookies()`
- `CookieSecureStorage.clearSharedPreferencesCookies()`

---

## Testing

### Test Coverage

All tests located in: `test/demo_mode_test.dart`

#### Test 1: Demo Flag Behavior

```dart
test('isDemoMode is false by default', () {
  isDemoMode = false;
  expect(isDemoMode, isFalse);
});

test('seedDemoData sets isDemoMode to true', () async {
  SharedPreferences.setMockInitialValues({});
  await seedDemoData();
  expect(isDemoMode, isTrue);
});
```

#### Test 2: Demo Data Creation

```dart
test('seedDemoData creates demo data in SharedPreferences', () async {
  SharedPreferences.setMockInitialValues({});
  await seedDemoData();

  final prefs = await SharedPreferences.getInstance();
  final sites = prefs.getStringList(demoWebViewModelsKey);
  final webspaces = prefs.getStringList(demoWebspacesKey);

  expect(sites, isNotNull);
  expect(sites!.length, equals(8)); // 8 demo sites
  expect(webspaces, isNotNull);
  expect(webspaces!.length, equals(4)); // 4 demo webspaces
});
```

#### Test 3: User Data Isolation

```dart
test('seeding demo data does not affect user data keys', () async {
  SharedPreferences.setMockInitialValues({
    'webViewModels': ['{"initUrl":"https://example.com","name":"User Site"}'],
    'webspaces': ['{"id":"all","name":"All","siteIndices":[]}'],
    'selectedWebspaceId': 'all',
    'themeMode': 1,
  });

  final prefs = await SharedPreferences.getInstance();

  // Seed demo data
  await seedDemoData();

  // Verify user data unchanged
  expect(prefs.getStringList('webViewModels')!.length, equals(1));
  expect(prefs.getString('selectedWebspaceId'), equals('all'));
  expect(prefs.getInt('themeMode'), equals(1));

  // Verify demo data in separate keys
  expect(prefs.getStringList(demoWebViewModelsKey)!.length, equals(8));
  expect(await isDemoModeActive(), isTrue);
});
```

#### Test 4: Demo Data Cleanup

```dart
test('starting normal session wipes demo preferences', () async {
  SharedPreferences.setMockInitialValues({
    'webViewModels': ['{"initUrl":"https://example.com","name":"User Site"}'],
    demoWebViewModelsKey: ['{"initUrl":"https://demo.com","name":"Demo Site"}'],
    demoWebspacesKey: ['{"id":"all","name":"All","siteIndices":[]}'],
    'wasDemoMode': true,
  });

  final prefs = await SharedPreferences.getInstance();

  // Clear demo data
  await clearDemoDataIfNeeded();

  // Verify demo data cleared
  expect(prefs.getStringList(demoWebViewModelsKey), isNull);
  expect(prefs.getStringList(demoWebspacesKey), isNull);
  expect(prefs.getBool('wasDemoMode'), isNull);

  // Verify user data intact
  expect(prefs.getStringList('webViewModels')!.length, equals(1));
});
```

#### Test 5: Save Blocking

```dart
test('saveCookies does nothing when isDemoMode is true', () async {
  isDemoMode = true;

  final mockStorage = MockFlutterSecureStorage();
  final cookieStorage = CookieSecureStorage(secureStorage: mockStorage);

  final cookies = {
    'example.com': [
      UnifiedCookie(name: 'session', value: 'abc123', domain: 'example.com'),
    ],
  };

  await cookieStorage.saveCookies(cookies);

  // Storage should be empty because demo mode blocked the save
  expect(mockStorage.storage, isEmpty);
});
```

---

## Integration with Screenshot Tests

### Usage in integration_test/screenshot_test.dart

```dart
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Screenshot generation with demo data', (WidgetTester tester) async {
    // Seed demo data BEFORE launching app
    await seedDemoData();

    // Launch app
    await app.main();
    await tester.pumpAndSettle();

    // App now shows demo data
    // Take screenshots...
    await binding.takeScreenshot('01-all-sites');
    // ...
  });
}
```

### Fastlane Integration

Demo mode is automatically triggered when screenshot tests run:

```bash
# Android
cd android && fastlane screenshots

# iOS
cd ios && fastlane screenshots
```

These commands execute the integration test which calls `seedDemoData()`.

---

## Example Scenarios

### Scenario 1: Developer Running Screenshot Tests

```
Day 1 - 9:00 AM: User uses app normally
├─ Creates sites: Gmail, Calendar, Drive
├─ Data saved to: webViewModels, webspaces
└─ Quits app

Day 1 - 10:00 AM: Developer runs screenshot tests
├─ Test calls seedDemoData()
│  ├─ Sets wasDemoMode = true
│  ├─ Sets isDemoMode = true
│  ├─ Writes demo data to demo_webViewModels, demo_webspaces
│  └─ User data in webViewModels, webspaces UNCHANGED
├─ App launches with demo data
├─ Screenshots captured
└─ Test completes

Day 1 - 2:00 PM: User opens app again
├─ _restoreAppState() calls isDemoModeActive() → true
├─ clearDemoDataIfNeeded() called
│  ├─ Removes demo_webViewModels
│  ├─ Removes demo_webspaces
│  └─ Removes wasDemoMode marker
├─ Loads from webViewModels, webspaces
└─ User sees: Gmail, Calendar, Drive ✓
```

### Scenario 2: Fresh Install with Screenshot Test

```
Install app → No user data exists
├─ Run screenshot test
│  ├─ seedDemoData() creates demo data
│  └─ Screenshots captured
└─ User opens app
    ├─ clearDemoDataIfNeeded() removes demo data
    ├─ No user data to load
    └─ App shows setup screen ✓
```

---

## Files

### Created

- `lib/demo_data.dart` - Complete demo mode system
- `test/demo_mode_test.dart` - Comprehensive test suite
- `openspec/specs/demo-mode/spec.md` - This specification

### Modified

- `lib/main.dart` - Conditional data loading, save blocking
  - Import demo mode functions and constants
  - Modified `_restoreAppState()` to check demo mode
  - Modified `_loadWebspaces()` to accept key parameters
  - Modified `_loadWebViewModels()` to accept key parameter
  - Added `isDemoMode` checks to all save methods

- `lib/services/cookie_secure_storage.dart` - Cookie save blocking
  - Import `isDemoMode` flag
  - Added checks to `saveCookies()`, `saveCookiesForUrl()`, `clearCookies()`, etc.

---

## Related Specifications

- [Screenshot Generation](../screenshots/spec.md) - Uses demo mode for screenshot tests
- Requirement SCREENSHOT-002 in screenshots spec documents the demo data seeding requirement

---

## Backwards Compatibility

No migration required:
- Existing user data continues to work (uses regular keys)
- Demo mode is only activated during screenshot tests
- First screenshot test after this implementation creates `demo_*` keys
- First normal launch after screenshot test clears `demo_*` keys
- User data is never modified or migrated

---

## References

- Issue: Demo mode persistence fix
- Branch: `claude/fix-demo-mode-persistence-zCGJS`
- Original implementation: PR #56 (Add demo mode no-save feature)
- Persistence fix: PR (TBD) - Separate keys approach
