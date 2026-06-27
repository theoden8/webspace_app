# Kiosk Mode

## Purpose

A per-site `kioskMode` toggle that turns a configured site into a
locked-down "app". When the site is launched from a home-screen
shortcut, the WebSpace shell hides every piece of *app UI* around the
site — drawer, tab strip, app-bar actions, context menus — and enters
fullscreen. The **webview itself is the one thing that stays**: the
user sees the full-bleed website and nothing else, and cannot reach any
configuration, switch to another site, edit, or delete it. Opening
WebSpace the normal way (launcher icon, no shortcut) restores full
access, so the owner can still change settings.

There is **no passphrase or PIN**. The launch source is the only gate:
a shortcut tap of a kiosk site locks the shell; a plain app launch does
not. This lets a user hand a configured site to someone (a child, a
shared device, a single-purpose terminal) via its shortcut without
exposing WebSpace's configuration surface, while keeping the ability to
re-edit the site from the main app.

`kioskMode` is pure UI state. It never affects the webview engine,
privacy posture, cookies, or nested-browser behavior, so it is NOT
threaded through `WebViewConfig` or the nested `InAppWebViewScreen`
(unlike the privacy fields governed by the nested-webview rule).

Builds on [home-shortcut](../home-shortcut/spec.md): kiosk mode reuses
the existing shortcut-launch resolution path; it does not add any new
shortcut creation/pinning.

## Status

- **Date**: 2026-06-27
- **Status**: Implemented

---

## Requirements

### Requirement: KIOSK-001 - Lock Derives From Launch Source

The system SHALL enter the locked shell state when, and only when, the
current session was entered via a home-screen shortcut whose target
site has `kioskMode = true`. The lock state SHALL be re-derived on
every shortcut launch from the resolved target's `kioskMode` value, on
both the cold-launch path (`_restoreAppState`) and the warm-tap path
(`_openShortcutIndex`). A launch that is not via a shortcut SHALL leave
the lock cleared.

#### Scenario: Cold launch via kiosk shortcut locks

**Given** a site with `kioskMode = true`
**When** the app is cold-launched by tapping that site's home-screen shortcut
**Then** the shell is locked (KIOSK-002)
**And** the kiosk site is the active site

#### Scenario: Plain app launch does not lock

**Given** a site with `kioskMode = true` exists
**When** the user opens WebSpace from the launcher icon (no shortcut payload)
**Then** the shell is NOT locked
**And** the drawer, tab strip, and settings are reachable as usual

#### Scenario: Warm shortcut tap to a non-kiosk site clears a prior lock

**Given** the session is currently locked from a kiosk shortcut launch
**When** the user warm-taps the home-screen shortcut of a different site whose `kioskMode = false`
**Then** the shell unlocks
**And** that non-kiosk site becomes active

#### Scenario: Cold launch via non-kiosk shortcut stays unlocked

**Given** a site with `kioskMode = false`
**When** the app is cold-launched by tapping that site's shortcut
**Then** the shell is NOT locked

---

### Requirement: KIOSK-002 - Locked Shell Hides Navigation And Configuration

While the lock is active the system SHALL suppress every affordance
that navigates between sites or reaches configuration, while keeping the
site's own webview fully presented. Specifically the shell SHALL NOT
present: the navigation drawer (and its edge-swipe and auto app-bar
hamburger), the bottom tab strip, the app-bar actions (download, theme
toggle, settings), or the per-site context menu (edit, delete, move,
archive). The webview and in-page back navigation remain available.

#### Scenario: Locked shell renders only the site

**Given** the session is locked (KIOSK-001)
**When** the home page renders
**Then** the active site's webview fills the screen
**And** no navigation drawer is attached to the scaffold
**And** no bottom tab strip is shown
**And** no app-bar action buttons or leading menu button are shown

#### Scenario: Settings unreachable while locked

**Given** the session is locked
**When** the user looks for a way to open per-site or app settings
**Then** there is no on-screen control that opens any settings or edit screen

---

### Requirement: KIOSK-003 - Locked Session Enforces Fullscreen

A locked session SHALL enter fullscreen on launch, overriding the
per-site `fullscreenMode` and the global `fullscreenOnShortcut`
preference, and SHALL NOT offer any exit-fullscreen affordance: the
top-edge exit handle, the in-fullscreen tab-bar button, and the
`_exitFullscreen` action are all suppressed while locked. The tab strip
SHALL stay hidden even when `tabStripInFullscreen` is on. The only way
out of fullscreen is to relaunch the app normally, which clears the lock
(KIOSK-001).

#### Scenario: Kiosk launch forces fullscreen regardless of prefs

**Given** a kiosk site whose `fullscreenMode` is off and global `fullscreenOnShortcut` is off
**When** the app is launched via that site's shortcut
**Then** the session is fullscreen

#### Scenario: Exit-fullscreen affordances are gone while locked

**Given** a locked fullscreen session
**When** the user taps the top-edge exit zone
**Then** the app stays fullscreen
**And** no tab-bar reveal button is shown even if `tabBarButtonInFullscreen` is on
**And** the tab strip stays hidden even if `tabStripInFullscreen` is on

---

### Requirement: KIOSK-004 - Toggle Persists Per Site

The system SHALL persist `kioskMode` as a per-site field via
`WebViewModel.toJson` / `fromJson`, defaulting to `false` for sites
and for legacy JSON that predates the field. Because it is per-site, it
rides the model serialization and SHALL NOT be added to the app-global
export registry (`kExportedAppPrefs`).

#### Scenario: Round-trips through JSON

**Given** a `WebViewModel` with `kioskMode = true`
**When** `toJson()` then `fromJson(...)` is applied
**Then** the rehydrated model has `kioskMode == true`

#### Scenario: Legacy JSON defaults off

**Given** a JSON map with no `kioskMode` key
**When** `WebViewModel.fromJson(json, ...)` is called
**Then** the resulting model's `kioskMode` is `false`

---

### Requirement: KIOSK-005 - Archive Neutrality

`kioskMode` is pure in-memory UI state derived at launch; it touches no
disk outside the per-site JSON (which for archive-tier sites already
rides the archive master-key keyspace), schedules no background work,
and creates no OS-level UI or per-`siteId` entries. Per the ARCH-006
audit it therefore needs NO archive override and does not vary
active-state byte-identity (ARCH-001).

#### Scenario: No archive-tier special handling required

**Given** the per-site feature audit is re-run for `kioskMode`
**When** each ARCH-006 trigger (disk, background scheduling, OS UI, out-of-keyspace siteId entries) is checked
**Then** none apply
**And** no override is added to the `WebViewModel` archive matrix

---

## Implementation

### Files

#### Modified

- `lib/web_view_model.dart` — `kioskMode` field, ctor param, `toJson`
  key, `fromJson` default-off read.
- `lib/screens/settings.dart` — per-site `SwitchListTile` plus the
  `_kioskMode` local-state read/write-back.
- `lib/main.dart` — `_kioskLocked` session flag, set from the target's
  `kioskMode` on cold launch (`_restoreAppState`) and warm tap
  (`_openShortcutIndex`); shell gates on `drawer`, `_buildAppBar`
  (leading + actions), and `_tabStripShown`. Fullscreen is forced on
  both launch paths and held: `_exitFullscreen` early-returns while
  locked, and the exit handle / tab-bar button are not rendered.
- `lib/l10n/app_en.arb` — `siteSettingsKioskMode` +
  `siteSettingsKioskModeSubtitle`.

#### Tests

- `test/web_view_model_test.dart` — `kioskMode` toJson/fromJson
  round-trip and legacy default.
