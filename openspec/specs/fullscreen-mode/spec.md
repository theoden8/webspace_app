# Full Screen Mode Specification

## Purpose

Allow users to view sites in full screen mode, hiding the app bar, tab strip, URL bar, and system UI for an immersive experience. Supports both on-demand toggling and a per-site auto-fullscreen setting.

## Status

- **Date**: 2026-04-12
- **Status**: Implemented

---

## Problem Statement

Users who use WebSpace as a web-app launcher want a full app experience without browser chrome. The app bar, tab strip, and system status/navigation bars consume screen space that could be used by the web content. A full screen mode gives users an immersive, app-like experience.

---

## Requirements

### Requirement: FS-001 - Toggle Full Screen

The system SHALL allow users to enter full screen mode from the overflow menu or by double-tapping the app bar title.

#### Scenario: Enter full screen from menu

**Given** the user has a site loaded
**When** the user opens the overflow menu (app bar or tab strip) and taps "Full Screen"
**Then** the app bar, tab strip, URL bar, find toolbar, and system UI are hidden
**And** the webview fills the entire screen

#### Scenario: Toggle full screen by double-tapping title

**Given** the user has a site loaded
**When** the user double-taps the site name in the app bar
**Then** the app enters full screen mode
**When** the user exits full screen and double-taps the title again
**Then** the app enters full screen mode again

---

### Requirement: FS-002 - Exit Full Screen

The system SHALL provide multiple ways to exit full screen mode.

#### Scenario: Exit via back gesture

**Given** the user is in full screen mode
**When** the user performs a back gesture (swipe or button)
**Then** full screen mode is exited
**And** the app bar, tab strip, and system UI are restored

#### Scenario: Exit via top edge tap

**Given** the user is in full screen mode
**When** the user taps the top edge of the screen (44px on iOS, 24px on other platforms)
**Then** full screen mode is exited

#### Scenario: iOS fullscreen hint

**Given** the user enters full screen mode on iOS
**Then** a brief SnackBar is shown: "Tap the top of the screen to exit full screen"
**And** a visible translucent handle is displayed at the top center of the screen

**Rationale:** On iOS, the back gesture (swipe from left edge) does not work on the root route, so the top edge tap is the only exit path. The larger 44px zone (Apple HIG minimum touch target), visible handle, and SnackBar hint ensure discoverability.

---

### Requirement: FS-003 - Per-Site Auto Full Screen

The system SHALL support a per-site setting to automatically enter full screen when the site is selected.

#### Scenario: Site with auto-fullscreen enabled

**Given** site "MyApp" has "Full screen mode" enabled in its settings
**When** the user switches to "MyApp"
**Then** the app automatically enters full screen mode

#### Scenario: Site without auto-fullscreen

**Given** site "Gmail" does NOT have "Full screen mode" enabled
**When** the user switches to "Gmail"
**Then** full screen mode is exited (if it was active)

#### Scenario: Configure auto-fullscreen

**Given** the user is on the Settings screen for a site
**When** the user enables the "Full screen mode" toggle
**And** saves settings
**Then** the `fullscreenMode` field is persisted for that site
**And** full screen mode is entered immediately

#### Scenario: Pressing Home on auto-fullscreen site

**Given** site "MyApp" has "Full screen mode" enabled
**And** the user is viewing "MyApp"
**When** the user presses the Home button (which disposes and recreates the webview)
**Then** full screen mode remains active

---

### Requirement: FS-004 - Full Screen Persistence Across Lifecycle

The system SHALL maintain the correct full screen state across app lifecycle transitions.

#### Scenario: App resumed while in full screen

**Given** the user is in full screen mode
**When** the app is backgrounded and then resumed
**Then** the immersive system UI mode is re-applied

---

### Requirement: FS-005 - Full Screen with Navigation Away

The system SHALL exit full screen when navigating to the webspaces list.

#### Scenario: Navigate to webspaces list

**Given** the user is in full screen mode
**When** the user navigates back to the webspaces list (index = null)
**Then** full screen mode is exited and system UI is restored

---

## Implementation Details

### Data Model

**WebViewModel** (`lib/web_view_model.dart`):
- `bool fullscreenMode = false` - Per-site setting for auto-fullscreen
- Serialized in `toJson()` / `fromJson()` with default `false`

### Runtime State

**_WebSpacePageState** (`lib/main.dart`):
- `bool _isFullscreen = false` - Current fullscreen state (not persisted; runtime only)

### UI Changes

- **App bar**: Hidden when `_isFullscreen` is true (`appBar: _isFullscreen ? null : _buildAppBar()`)
- **Tab strip**: `_buildTabStrip()` returns null when `_isFullscreen`
- **Input bar**: `_buildInputBar()` returns null when `_isFullscreen`
- **Exit zone**: GestureDetector at top edge when fullscreen (44px on iOS with visible handle, 24px on other platforms)
- **iOS hint**: SnackBar shown on entering fullscreen on iOS to explain exit method
- **Menu items**: "Full Screen" added to both app bar and tab strip popup menus

### System UI

- Enter: `SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky)`
- Exit: `SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)`
- Re-applied on app resume via `_resumeAfterLifecyclePause()`

### Site Switching

In `_setCurrentIndex()`:
- If target site has `fullscreenMode = true`, calls `_enterFullscreen()`
- Otherwise, calls `_exitFullscreen()`
- Navigating to null index (webspaces list) always exits fullscreen

### Back Gesture

In `onPopInvokedWithResult`:
- If `_isFullscreen`, exits fullscreen and returns (no further back handling)

### Settings Backup

- `fullscreenMode` is included in site JSON via `toJson()`/`fromJson()`
- No changes needed to `SettingsBackup` class (it serializes full site JSON)

---

## Files Modified

| File | Changes |
|------|---------|
| `lib/web_view_model.dart` | Added `fullscreenMode` field, constructor param, toJson/fromJson |
| `lib/screens/settings.dart` | Added fullscreen mode toggle switch |
| `lib/main.dart` | Added `_isFullscreen` state, enter/exit/toggle methods, menu items, scaffold/body changes, back handler, lifecycle handling |

---

## Manual Test Procedure

1. Open the app and navigate to a site
2. Open the overflow menu and tap "Full Screen"
3. Verify: app bar, tab strip, URL bar, and system bars are hidden
4. Tap the top edge of the screen to exit full screen
5. Verify: all UI elements are restored
6. Enter full screen again, then perform a back gesture
7. Verify: full screen is exited
8. Go to site Settings, enable "Full screen mode", save
9. Switch to another site, then switch back
10. Verify: full screen is automatically entered
11. Switch to a site without full screen mode enabled
12. Verify: full screen is exited
13. In full screen, background the app and resume
14. Verify: immersive mode is re-applied
