# Demo Mode Persistence Specification

## Purpose

Ensure user data is preserved when running screenshot tests by isolating demo data in separate SharedPreferences keys.

## Status

- **Status**: Completed
- **Date**: 2026-01-26
- **Issue**: User data was being overwritten by screenshot test demo data

---

## Problem

When running screenshot tests via Fastlane, the following data loss occurred:

1. User sets up app with personal sites and webspaces
2. User quits app
3. Screenshot tests run and call `seedDemoData()`
4. Demo data overwrites user data in SharedPreferences
5. User opens app → blank setup screen (data lost)

---

## Requirements

### Requirement: DEMO-001 - User Data Isolation

Demo data SHALL NOT overwrite or modify user data in SharedPreferences.

#### Scenario: Seed demo data without affecting user data

- **GIVEN** user has sites saved in SharedPreferences
- **WHEN** `seedDemoData()` is called for screenshot tests
- **THEN** user data remains intact in regular keys
- **AND** demo data is written to separate `demo_*` keys

---

### Requirement: DEMO-002 - Demo Data Cleanup

Demo data SHALL be automatically cleared when app starts normally after screenshot tests.

#### Scenario: Clear demo data on normal app launch

- **GIVEN** demo data exists from previous screenshot test session
- **AND** marker flag `wasDemoMode` is set to true
- **WHEN** app starts in normal mode
- **THEN** all `demo_*` keys are removed
- **AND** marker flag is cleared
- **AND** app loads user data from regular keys

---

### Requirement: DEMO-003 - Demo Mode Isolation

Changes made during demo mode SHALL NOT persist to storage.

#### Scenario: Prevent saves during demo mode

- **GIVEN** `isDemoMode` flag is set to true
- **WHEN** app attempts to save data via `_saveWebViewModels()`, `_saveWebspaces()`, etc.
- **THEN** save operations return early without persisting
- **AND** demo data in `demo_*` keys remains unchanged
- **AND** user data in regular keys remains unchanged

---

### Requirement: DEMO-004 - Key Separation

Demo data and user data SHALL use completely separate SharedPreferences keys.

#### Scenario: Use separate key namespaces

- **GIVEN** the app uses SharedPreferences for data storage
- **THEN** user data is stored in keys: `webViewModels`, `webspaces`, `selectedWebspaceId`, `currentIndex`, `themeMode`, `showUrlBar`
- **AND** demo data is stored in keys: `demo_webViewModels`, `demo_webspaces`, `demo_selectedWebspaceId`, `demo_currentIndex`, `demo_themeMode`, `demo_showUrlBar`
- **AND** marker flag is stored in key: `wasDemoMode`

---

### Requirement: DEMO-005 - Data Loading Strategy

App SHALL detect demo mode and load from appropriate keys on startup.

#### Scenario: Load demo data during screenshot test

- **GIVEN** `wasDemoMode` marker is true
- **WHEN** app starts via `_restoreAppState()`
- **THEN** app calls `isDemoModeActive()` which returns true
- **AND** app loads data from `demo_*` keys
- **AND** app displays demo sites and webspaces

#### Scenario: Load user data during normal startup

- **GIVEN** `wasDemoMode` marker is false or absent
- **WHEN** app starts via `_restoreAppState()`
- **THEN** app calls `clearDemoDataIfNeeded()` to remove any leftover demo data
- **AND** app loads data from regular keys
- **AND** app displays user's sites and webspaces

---

## Architecture

### Data Flow - Screenshot Test Session

```
┌─────────────────────────────────────────┐
│    integration_test/screenshot_test     │
│         await seedDemoData()            │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│      lib/demo_data.dart                 │
│  1. Set wasDemoMode = true              │
│  2. Set isDemoMode = true (in memory)   │
│  3. Write to demo_* keys                │
│     - demo_webViewModels                │
│     - demo_webspaces                    │
│     - demo_selectedWebspaceId           │
│     - demo_currentIndex                 │
│     - demo_themeMode                    │
│     - demo_showUrlBar                   │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│      SharedPreferences                  │
│  User keys: webViewModels (untouched)   │
│  Demo keys: demo_webViewModels (new)    │
│  Marker: wasDemoMode = true             │
└─────────────────────────────────────────┘
```

### Data Flow - Normal App Startup After Test

```
┌─────────────────────────────────────────┐
│         lib/main.dart                   │
│     _restoreAppState()                  │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│      await isDemoModeActive()           │
│      Returns: true                      │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│   await clearDemoDataIfNeeded()         │
│   1. Checks wasDemoMode → true          │
│   2. Removes all demo_* keys            │
│   3. Removes wasDemoMode marker         │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│      Load from regular keys             │
│      - webViewModels                    │
│      - webspaces                        │
│      - selectedWebspaceId               │
│      User data restored ✓               │
└─────────────────────────────────────────┘
```

---

## Data Models

### SharedPreferences Keys

| Key Type | Key Name | Description |
|----------|----------|-------------|
| **User Data** | | |
| | `webViewModels` | User's saved sites (JSON list) |
| | `webspaces` | User's workspaces (JSON list) |
| | `selectedWebspaceId` | Currently selected workspace ID |
| | `currentIndex` | Currently selected site index |
| | `themeMode` | User's theme preference (int) |
| | `showUrlBar` | URL bar visibility (bool) |
| **Demo Data** | | |
| | `demo_webViewModels` | Demo sites for screenshots |
| | `demo_webspaces` | Demo workspaces |
| | `demo_selectedWebspaceId` | Demo workspace selection |
| | `demo_currentIndex` | Demo site index |
| | `demo_themeMode` | Demo theme preference |
| | `demo_showUrlBar` | Demo URL bar setting |
| **Control** | | |
| | `wasDemoMode` | Boolean flag indicating previous session was demo mode |

### Global State

```dart
/// In-memory flag set during demo mode session
bool isDemoMode = false;
```

This flag prevents save operations during the demo session:

```dart
Future<void> _saveWebViewModels() async {
  if (isDemoMode) return; // Don't persist in demo mode
  // ... save logic
}
```

---

## Implementation

### Key Functions

#### `seedDemoData()` - Initialize Demo Mode

Located in: `lib/demo_data.dart`

1. Sets `wasDemoMode = true` marker in SharedPreferences
2. Sets `isDemoMode = true` in memory
3. Creates demo sites and workspaces
4. Writes demo data to `demo_*` keys
5. Does NOT modify user data keys

#### `isDemoModeActive()` - Check Demo Status

Located in: `lib/demo_data.dart`

```dart
Future<bool> isDemoModeActive() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_demoModeMarkerKey) ?? false;
}
```

Returns true if app is in or was in demo mode.

#### `clearDemoDataIfNeeded()` - Clean Demo Data

Located in: `lib/demo_data.dart`

```dart
Future<void> clearDemoDataIfNeeded() async {
  final prefs = await SharedPreferences.getInstance();
  final wasDemoMode = prefs.getBool(_demoModeMarkerKey) ?? false;

  if (wasDemoMode) {
    // Remove all demo_* keys
    await prefs.remove(demoWebViewModelsKey);
    await prefs.remove(demoWebspacesKey);
    // ... remove all demo keys
    await prefs.remove(_demoModeMarkerKey);
  }
}
```

#### `_restoreAppState()` - App Startup Logic

Located in: `lib/main.dart`

```dart
Future<void> _restoreAppState() async {
  final bool demoModeActive = await isDemoModeActive();

  String webViewModelsKey;
  String webspacesKey;
  // ... declare other keys

  if (demoModeActive) {
    // Load from demo_* keys
    webViewModelsKey = demoWebViewModelsKey;
    webspacesKey = demoWebspacesKey;
    // ...
  } else {
    // Clear demo data and load from regular keys
    await clearDemoDataIfNeeded();
    webViewModelsKey = 'webViewModels';
    webspacesKey = 'webspaces';
    // ...
  }

  await _loadWebspaces(webspacesKey, selectedWebspaceIdKey);
  await _loadWebViewModels(webViewModelsKey);
  // ...
}
```

---

## Testing

### Test Coverage

All tests located in: `test/demo_mode_test.dart`

#### Test 1: User Data Isolation

```dart
test('seeding demo data does not affect user data keys', () async {
  // Setup user data in regular keys
  SharedPreferences.setMockInitialValues({
    'webViewModels': ['{"initUrl":"https://example.com","name":"User Site"}'],
    'selectedWebspaceId': 'all',
    'themeMode': 1,
  });

  // Seed demo data
  await seedDemoData();

  // Verify user data unchanged
  expect(prefs.getStringList('webViewModels')!.length, equals(1));
  expect(prefs.getString('selectedWebspaceId'), equals('all'));

  // Verify demo data in separate keys
  expect(prefs.getStringList(demoWebViewModelsKey)!.length, equals(8));
  expect(await isDemoModeActive(), isTrue);
});
```

#### Test 2: Demo Data Cleanup

```dart
test('starting normal session wipes demo preferences', () async {
  // Setup both user and demo data (post-screenshot test state)
  SharedPreferences.setMockInitialValues({
    'webViewModels': ['{"initUrl":"https://example.com","name":"User Site"}'],
    demoWebViewModelsKey: ['{"initUrl":"https://demo.com","name":"Demo Site"}'],
    'wasDemoMode': true,
  });

  // Clear demo data
  await clearDemoDataIfNeeded();

  // Verify demo data cleared
  expect(prefs.getStringList(demoWebViewModelsKey), isNull);
  expect(prefs.getBool('wasDemoMode'), isNull);

  // Verify user data intact
  expect(prefs.getStringList('webViewModels')!.length, equals(1));
});
```

#### Test 3: Key Isolation

```dart
test('changes in demo mode only affect demo keyed preferences', () async {
  // Setup user data
  SharedPreferences.setMockInitialValues({
    'webViewModels': ['{"initUrl":"https://example.com","name":"User Site"}'],
    'themeMode': 1,
  });

  final originalSites = prefs.getStringList('webViewModels');

  // Enable demo mode
  await seedDemoData();

  // Modify demo keys
  await prefs.setStringList(demoWebViewModelsKey, ['{"initUrl":"https://changed.com"}']);

  // Verify user data unchanged
  expect(prefs.getStringList('webViewModels'), equals(originalSites));
});
```

---

## Files

### Modified

- `lib/demo_data.dart` - Added key separation and cleanup logic
  - Added constants: `demoWebViewModelsKey`, `demoWebspacesKey`, etc.
  - Added function: `isDemoModeActive()`
  - Added function: `clearDemoDataIfNeeded()`
  - Modified: `seedDemoData()` to write to `demo_*` keys

- `lib/main.dart` - Updated data loading to check demo mode
  - Modified: `_restoreAppState()` to detect and handle demo mode
  - Modified: `_loadWebspaces()` to accept key parameters
  - Modified: `_loadWebViewModels()` to accept key parameters

- `test/demo_mode_test.dart` - Added comprehensive tests
  - Test: User data isolation
  - Test: Demo data cleanup
  - Test: Key isolation

### Created

- `openspec/specs/demo-mode-persistence/spec.md` - This specification

---

## Backwards Compatibility

No migration required. The change is transparent to existing users:

- Existing user data continues to work (uses regular keys)
- First screenshot test after this change creates `demo_*` keys
- First normal launch after screenshot test clears `demo_*` keys
- User data is never modified or migrated

---

## Example Scenario

### Complete User Flow

```
Day 1: User sets up app
├─ Creates sites: GitHub, Gmail, Calendar
├─ Creates workspace: "Work"
└─ Data saved to: webViewModels, webspaces

Day 2: Developer runs screenshot tests
├─ Test calls seedDemoData()
├─ Sets wasDemoMode = true
├─ Writes demo data to demo_webViewModels, demo_webspaces
├─ User data in webViewModels, webspaces UNCHANGED
├─ Screenshots captured with demo data
└─ Test completes

Day 3: User opens app
├─ _restoreAppState() calls isDemoModeActive() → true
├─ Calls clearDemoDataIfNeeded()
│  ├─ Removes demo_webViewModels
│  ├─ Removes demo_webspaces
│  └─ Removes wasDemoMode marker
├─ Loads from webViewModels, webspaces
└─ User sees: GitHub, Gmail, Calendar (original data restored ✓)
```

---

## Related Specifications

- [Screenshot Generation](../screenshots/spec.md) - Automated screenshot testing that triggers demo mode

---

## References

- Issue: Demo mode persistence fix
- Branch: `claude/fix-demo-mode-persistence-zCGJS`
- Commits:
  - `c925435` - Initial simpler approach (insufficient)
  - `d96587b` - Use separate keys for demo data to preserve user data
  - `6f3a90b` - Add tests for separate demo data keys approach
  - `2b2cac1` - Add comprehensive documentation for demo mode persistence fix
