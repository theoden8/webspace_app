# Home Screen Shortcut Specification

## Purpose

Allow users to add a site shortcut to the Android home screen. Tapping the shortcut launches WebSpace and navigates to that site.

## Status

- **Date**: 2026-03-08
- **Status**: In Progress

---

## Problem Statement

Users who frequently access a specific site (e.g., Gmail, Slack) want quick access from their home screen without opening WebSpace and navigating to the site manually.

---

## Requirements

### Requirement: HS-001 - Pin Shortcut to Home Screen

The system SHALL allow users to add a pinned shortcut for the current site to the Android home screen.

#### Scenario: Add shortcut from menu

**Given** the user has a site loaded (e.g., "Gmail")
**When** the user opens the overflow menu and taps "Add to Home Screen"
**Then** the system shows the Android pinned shortcut confirmation dialog
**And** the shortcut appears on the home screen with the site's name and favicon

---

### Requirement: HS-002 - Launch Site via Shortcut

The system SHALL navigate to the correct site when launched via a home screen shortcut.

#### Scenario: Open app via shortcut

**Given** the user has a "Gmail" shortcut on the home screen
**When** the user taps the shortcut
**Then** WebSpace opens
**And** the Gmail site is selected and loaded

#### Scenario: App already running

**Given** WebSpace is already running in the background
**When** the user taps a home screen shortcut
**Then** the app is brought to the foreground
**And** the correct site is selected

---

### Requirement: HS-003 - Shortcut Icon

The system SHALL use the site's favicon as the shortcut icon when available, falling back to the app icon.

#### Scenario: Site has favicon

**Given** the site has a cached favicon URL (non-SVG)
**When** a shortcut is created
**Then** the shortcut icon is the site's favicon

#### Scenario: Site has no favicon or SVG favicon

**Given** the site has no cached favicon, or the favicon is SVG (not supported by Android shortcuts)
**When** a shortcut is created
**Then** the shortcut icon is the WebSpace app icon

---

### Requirement: HS-004 - Android Only

The feature SHALL only be available on Android. On iOS/macOS, the menu item is not shown.

#### Scenario: Menu item hidden on non-Android platforms

**Given** the app is running on iOS or macOS
**When** the user opens the overflow menu
**Then** the "Add to Home Screen" option is not shown

---

## Implementation

### Platform Channel

Flutter communicates with native Android code via `MethodChannel('org.codeberg.theoden8.webspace/shortcuts')`.

Methods:
- `pinShortcut({siteId, label, iconUrl})` — requests a pinned shortcut via `ShortcutManagerCompat.requestPinShortcut()`
- `getLaunchSiteId()` — returns the `siteId` from the launch intent extra (if launched via shortcut)

### Shortcut Intent

The shortcut launches `MainActivity` with:
- `action`: `ACTION_VIEW`
- `extra`: `siteId` = the site's unique ID
- `flags`: `FLAG_ACTIVITY_NEW_TASK | FLAG_ACTIVITY_CLEAR_TOP`

### Launch Handling

On app start and on `onNewIntent` (app already running), check for `siteId` in the intent:
1. Find the site index matching the `siteId`
2. Call `_setCurrentIndex(index)` to switch to that site

### Files

#### New
- `lib/services/shortcut_service.dart` — Flutter wrapper around the platform channel
- `openspec/specs/home-shortcut/spec.md` — this specification

#### Modified
- `android/app/src/main/kotlin/.../MainActivity.kt` — native shortcut creation and intent handling
- `lib/main.dart` — menu item, shortcut action, launch intent handling

---

## Testing

### Manual Test: Create Shortcut

1. Open a site in WebSpace
2. Tap overflow menu (three dots)
3. Tap "Add to Home Screen"
4. Confirm in the Android system dialog
5. Verify shortcut appears on home screen with site name and icon

### Manual Test: Launch via Shortcut

1. Create a shortcut for a site
2. Close WebSpace completely
3. Tap the shortcut on the home screen
4. Verify WebSpace opens and the correct site is loaded

### Manual Test: Launch While Running

1. Create a shortcut for Site A
2. Open WebSpace and navigate to Site B
3. Tap the home screen shortcut for Site A
4. Verify the app switches to Site A
