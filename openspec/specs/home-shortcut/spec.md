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

### Requirement: HS-005 - Hide When Already Pinned

Sites in WebSpace are stable, so a home shortcut is a one-time setup per site. The "Home Shortcut" menu item SHALL be hidden when the current site already has a pinned shortcut, and SHALL reappear if the user removes the shortcut from the launcher.

#### Scenario: Site already has a pinned shortcut

**Given** the user previously pinned a shortcut for the current site
**When** the user opens the overflow menu
**Then** the "Home Shortcut" option is not shown for that site

#### Scenario: Shortcut removed from launcher

**Given** the user removed a previously pinned shortcut from their home screen
**When** the user backgrounds and re-foregrounds the app, then opens the overflow menu for that site
**Then** the "Home Shortcut" option is shown again

The pinned-shortcut set is queried via `ShortcutManagerCompat.getShortcuts(FLAG_MATCH_PINNED)` exposed through the platform channel as `getPinnedSiteIds`. The cached set is refreshed on `initState` and on `AppLifecycleState.resumed`, which covers both the in-app pin flow (the launcher's pin dialog backgrounds the app) and out-of-app removal.

---

### Requirement: HS-006 - Shortcut Launch Resets To Home URL

A pinned shortcut SHALL launch the targeted site at its `initUrl`, not at the last persisted `currentUrl`. The shortcut represents the user's stated entry point for that site (the URL they pinned), not the URL the previous session happened to drift to. Without this, location/tracking/state parameters that accumulate during a session resurface every time the shortcut is tapped — particularly visible on map and search sites that encode coordinates or query state in the URL (issue #298).

This requirement applies only to **process-startup** launches (cold or post-kill). When the app is already running and the user taps a shortcut, the live in-memory session is preserved — the shortcut just brings the app to the foreground and switches to the site, matching HS-002's "App already running" scenario.

#### Scenario: Cold-launch via shortcut resets to initUrl

**Given** site A's `initUrl` is `https://www.google.com/maps`
**And** the previous session ended with `currentUrl` = `https://www.google.com/maps/@40.7,-74.0,15z`
**And** the user has force-killed the app
**When** the user taps A's home shortcut
**Then** the app starts up
**And** A's webview is created with `initialUrl` = `https://www.google.com/maps`
**And** the URL bar shows `https://www.google.com/maps`

#### Scenario: Warm tap leaves running session intact

**Given** the app is already running
**And** site A's webview has navigated to `https://www.google.com/maps/@40.7,-74.0,15z`
**When** the user taps A's home shortcut from the launcher
**Then** the app comes to the foreground
**And** A is selected
**And** A's webview is at `https://www.google.com/maps/@40.7,-74.0,15z` (no reset)

#### Scenario: Non-shortcut cold launch is unchanged

**Given** the previous session ended with site A active at a deep `currentUrl`
**When** the user opens WebSpace from its app icon (no shortcut intent)
**Then** the app starts on the home screen with no site activated
**And** if A is later opened, A's webview loads its persisted `currentUrl`

---

## Implementation

### Platform Channel

Flutter communicates with native Android code via `MethodChannel('org.codeberg.theoden8.webspace/shortcuts')`.

Methods:
- `pinShortcut({siteId, label, iconUrl})` — requests a pinned shortcut via `ShortcutManagerCompat.requestPinShortcut()`
- `removeShortcut(siteId)` — disables and removes the dynamic+pinned shortcut for a deleted site
- `getLaunchSiteId()` — returns the `siteId` from the launch intent extra (if launched via shortcut)
- `getPinnedSiteIds()` — returns the set of `siteId`s currently pinned, derived from `ShortcutManagerCompat.getShortcuts(FLAG_MATCH_PINNED)` by stripping the `site_` prefix

### Shortcut Intent

The shortcut launches `MainActivity` with:
- `action`: `ACTION_VIEW`
- `extra`: `siteId` = the site's unique ID
- `flags`: `FLAG_ACTIVITY_NEW_TASK | FLAG_ACTIVITY_CLEAR_TOP`

### Launch Handling

On app start and on `onNewIntent` (app already running), check for `siteId` in the intent:
1. Call [`StartupRestoreEngine.resolveLaunchTarget`](../../../lib/services/startup_restore_engine.dart)
   with the shortcut siteId and the current models list — it returns
   the matching index (or `null` when there is no intent, or the
   siteId no longer maps to any site because the user deleted it after
   pinning)
2. Call `_setCurrentIndex(index)` to switch to that site

The resolution rule is exercised headlessly in
[test/startup_restore_engine_test.dart](../../../test/startup_restore_engine_test.dart);
no widget tree required.

### Files

#### New
- `lib/services/shortcut_service.dart` — Flutter wrapper around the platform channel
- `lib/services/startup_restore_engine.dart` — `resolveLaunchTarget` shortcut→index resolution
- `test/startup_restore_engine_test.dart` — unit tests for the resolution rule
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
