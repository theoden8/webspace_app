# Demo Mode Persistence Fix

## Problem Statement

When running screenshot tests with `fastlane`, the app was losing user data:

1. User runs app, sets things up → data saved to SharedPreferences
2. User quits app
3. Fastlane runs iOS screenshot tests → calls `seedDemoData()`
4. User runs app again → **blank setup screen** (user data lost)

The root cause was that `seedDemoData()` was directly overwriting user data in SharedPreferences with demo data for the screenshot tests.

## Solution Overview

Use **separate SharedPreferences keys** for demo data vs. user data:

- User data: stored in regular keys (`webViewModels`, `webspaces`, etc.)
- Demo data: stored in demo keys (`demo_webViewModels`, `demo_webspaces`, etc.)
- Marker flag: `wasDemoMode` indicates if previous session was a screenshot test

This ensures user data is **never overwritten** by demo data.

## How It Works

### 1. Screenshot Test Flow

```dart
// integration_test/screenshot_test.dart calls:
await seedDemoData();
```

**What happens:**
1. Sets `wasDemoMode = true` marker in SharedPreferences
2. Sets `isDemoMode = true` in memory (prevents saves during test)
3. Writes demo data to `demo_*` keys:
   - `demo_webViewModels`
   - `demo_webspaces`
   - `demo_selectedWebspaceId`
   - `demo_currentIndex`
   - `demo_themeMode`
   - `demo_showUrlBar`
4. **User data in regular keys remains untouched**

### 2. App Starts During Screenshot Test

```dart
// main.dart _restoreAppState() checks:
final bool demoModeActive = await isDemoModeActive();

if (demoModeActive) {
  // Load from demo_* keys
  webViewModelsKey = demoWebViewModelsKey;
  webspacesKey = demoWebspacesKey;
  // ...
}
```

**Result:** App loads demo data for screenshots, user data preserved.

### 3. User Opens App Normally (After Tests)

```dart
if (!demoModeActive) {
  // Clear demo data and marker
  await clearDemoDataIfNeeded();
  // Load from regular keys
  webViewModelsKey = 'webViewModels';
  webspacesKey = 'webspaces';
  // ...
}
```

**What happens:**
1. `clearDemoDataIfNeeded()` detects `wasDemoMode = true`
2. Removes all `demo_*` keys and the marker
3. Loads from regular keys
4. **User's original data is restored**

## Key Changes

### lib/demo_data.dart

**Added:**
- Demo key constants (`demoWebViewModelsKey`, etc.)
- `isDemoModeActive()` - checks if marker is set
- `clearDemoDataIfNeeded()` - clears demo keys when app starts normally

**Modified:**
- `seedDemoData()` - now writes to `demo_*` keys instead of regular keys
- Sets marker flag at the start (before clearing/writing)

### lib/main.dart

**Modified:**
- `_restoreAppState()` - checks `isDemoModeActive()` and loads from appropriate keys
- `_loadWebspaces()` - accepts optional key parameters
- `_loadWebViewModels()` - accepts optional key parameter

**Import:**
- Added exports: `isDemoModeActive`, `demoWebViewModelsKey`, etc.

## Tests

Added comprehensive tests in `test/demo_mode_test.dart`:

### 1. User Data Isolation Test
```dart
test('seeding demo data does not affect user data keys')
```
- Sets up user data in regular keys
- Calls `seedDemoData()`
- Verifies user data remains intact
- Confirms demo data is in separate `demo_*` keys

### 2. Demo Data Cleanup Test
```dart
test('starting normal session wipes demo preferences')
```
- Simulates state after screenshot test (both user and demo data present)
- Calls `clearDemoDataIfNeeded()`
- Verifies all `demo_*` keys are removed
- Confirms user data is preserved

### 3. Key Isolation Test
```dart
test('changes in demo mode only affect demo keyed preferences')
```
- Sets up user data
- Enables demo mode via `seedDemoData()`
- Modifies demo keys
- Verifies user data remains unchanged

## Benefits

1. **User data safety**: User data is never overwritten or lost
2. **Clean separation**: Demo and user data are completely isolated
3. **Automatic cleanup**: Demo data is automatically cleared on next normal app launch
4. **No manual intervention**: Users don't need to do anything special
5. **Backward compatible**: Existing user data continues to work

## Technical Details

### SharedPreferences Keys

| Purpose | Key Name | Description |
|---------|----------|-------------|
| **User Data** | | |
| | `webViewModels` | User's saved sites |
| | `webspaces` | User's workspaces |
| | `selectedWebspaceId` | Currently selected workspace |
| | `currentIndex` | Currently selected site index |
| | `themeMode` | User's theme preference |
| | `showUrlBar` | URL bar visibility setting |
| **Demo Data** | | |
| | `demo_webViewModels` | Demo sites for screenshots |
| | `demo_webspaces` | Demo workspaces |
| | `demo_selectedWebspaceId` | Demo workspace selection |
| | `demo_currentIndex` | Demo site index |
| | `demo_themeMode` | Demo theme |
| | `demo_showUrlBar` | Demo URL bar setting |
| **Control** | | |
| | `wasDemoMode` | Marker flag indicating previous session was demo mode |

### isDemoMode Flag

The in-memory `isDemoMode` flag (set to `true` by `seedDemoData()`) prevents the app from saving changes during the screenshot test session:

```dart
Future<void> _saveWebViewModels() async {
  if (isDemoMode) return; // Don't persist in demo mode
  // ... save logic
}
```

This ensures that any interactions during the screenshot test don't persist to storage.

## Migration Path

No migration needed - this change is transparent:
- Existing user data continues to work (still uses regular keys)
- First screenshot test after this change creates `demo_*` keys
- First normal launch after screenshot test clears `demo_*` keys

## Example Flow

```
User App Session 1:
  - User creates sites A, B, C
  - Saves to 'webViewModels'
  - Quit app

Screenshot Test:
  - seedDemoData() called
  - Creates 'wasDemoMode' = true
  - Writes demo sites to 'demo_webViewModels'
  - User data in 'webViewModels' untouched
  - App loads from 'demo_webViewModels'
  - Screenshots taken
  - Test completes

User App Session 2:
  - _restoreAppState() checks 'wasDemoMode' → true
  - clearDemoDataIfNeeded() removes 'demo_webViewModels', 'wasDemoMode'
  - Loads from regular 'webViewModels'
  - User sees sites A, B, C (their original data)
```

## Verification

To verify the fix works:

1. Run the test suite:
   ```bash
   flutter test test/demo_mode_test.dart
   ```

2. Manual verification:
   - Set up some sites in the app
   - Run `fastlane screenshots` (or integration test)
   - Open app normally
   - Verify your original sites are still present

## Files Changed

- `lib/demo_data.dart` - Core demo mode logic
- `lib/main.dart` - App startup and data loading
- `test/demo_mode_test.dart` - Comprehensive test coverage

## Commits

1. `c925435` - Initial simpler approach (insufficient)
2. `d96587b` - Use separate keys for demo data to preserve user data
3. `6f3a90b` - Add tests for separate demo data keys approach
