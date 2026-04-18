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

The system SHALL use a high-resolution bitmap of the site's favicon as the shortcut icon when available, falling back to the app icon.

#### Scenario: Site exposes a high-resolution icon

**Given** the site's HTML exposes an `apple-touch-icon`, a sized `link rel="icon"`, or a web app manifest with `icons`
**When** a shortcut is created
**Then** the shortcut icon is the largest bitmap found among those sources

#### Scenario: Site has only a low-resolution favicon

**Given** the site has only a small favicon (e.g. 16x16 `favicon.ico`)
**When** a shortcut is created
**Then** the system falls back to Google's 256px favicon service (HTTPS hosts)
**And** otherwise uses the small favicon, scaled up for launcher display

#### Scenario: Site has no favicon or SVG favicon

**Given** the favicon discovery yields no bitmap (only SVG or nothing)
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

### High-Resolution Favicon Discovery

When the user taps "Add to Home Screen" the app calls `getHighResFaviconUrl(siteUrl)`
in `lib/services/icon_service.dart` before pinning. It scrapes the site's HTML for:
1. `link[rel="apple-touch-icon"]` / `apple-touch-icon-precomposed` (default score 180, or the parsed `sizes`)
2. `link[rel="icon"]` with a parsed `sizes` attribute (e.g. `96x96`)
3. The web app manifest (`link[rel="manifest"]`) and its `icons[].sizes`

SVG icons are excluded because `ShortcutInfoCompat` requires a bitmap. If the best
candidate is still smaller than 96 px (or absent), the service falls back to
`https://www.google.com/s2/favicons?domain=<host>&sz=256` for HTTPS hosts.

On the native side, `MainActivity.downloadBitmap` fetches the chosen URL with a
browser User-Agent, follows up to 3 redirects, and `upscaleIfTiny` scales small
bitmaps up to ~192 px with bilinear filtering before the launcher shows them.

### Files

#### New
- `lib/services/shortcut_service.dart` — Flutter wrapper around the platform channel
- `openspec/specs/home-shortcut/spec.md` — this specification

#### Modified
- `android/app/src/main/kotlin/.../MainActivity.kt` — native shortcut creation, intent handling, HD bitmap download/scale
- `lib/main.dart` — menu item, shortcut action, launch intent handling, HD favicon resolution
- `lib/services/icon_service.dart` — `getHighResFaviconUrl` for apple-touch-icon / manifest discovery

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
