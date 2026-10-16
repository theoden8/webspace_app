# Lazy Webview Loading Specification

## Purpose

Implements lazy loading for webviews to prevent all sites from loading simultaneously when any single site is selected. This improves performance, reduces network usage, and prevents unwanted nested webview dialogs from appearing during normal app usage and screenshot tests.

**Formal model:** the `LoadSite`/`Evict` actions over the shared `loaded` set are composed into the cross-spec kernel [formal/kernel.tla](../../../formal/kernel.tla); eviction must never drop the visible site or the kernel's `Inv_CurrentLoaded` safety invariant fails (the `evict` demonstrator).

## Status

- **Branch**: `claude/fix-screenshot-test-webviews-RIAXN`
- **Date**: 2026-01-26
- **Status**: Completed

---

## Problem Statement

The app used an `IndexedStack` widget to manage webviews, which creates ALL child widgets upfront (even though only one is displayed). With 8 demo sites:

1. When selecting DuckDuckGo (index 0), all 8 webviews were created simultaneously
2. All 8 sites would start loading their URLs in the background
3. Background webviews could trigger cross-domain navigations (ads, OAuth redirects, tracking)
4. These navigations would open unexpected nested webview dialogs
5. During screenshot tests, Reddit and Weights & Biases webviews would appear on top of DuckDuckGo

---

## Requirements

### Requirement: LAZY-001 - Track Visited Webviews

The system SHALL track which sites have been visited by the user, as sites rather than their rows.

#### Scenario: Initialize tracking set

**Given** the app starts fresh
**When** no sites have been selected
**Then** the loaded set is empty
**And** no webviews are created

---

### Requirement: LAZY-002 - Create Webviews On-Demand

Webviews SHALL be created only when the user visits a site, EXCEPT for sites with `notificationsEnabled == true` which SHALL be auto-loaded on app startup so their page JS can fire notifications without waiting for the user to open them. Requires container mode (`_useContainers == true`); on legacy devices the notification toggle is hidden so this modification does not apply.

In container mode there are no domain-conflict restrictions (PROF-003), so all notification sites auto-load freely regardless of domain overlap.

Implementation: see the auto-load loop in `StartupController.restore` ([lib/main.dart](../../../lib/main.dart)) that adds every `notificationsEnabled` site index to `_sites.loaded` after the per-site models have been hydrated.

#### Scenario: App starts with multiple notification sites

**Given** container mode is active
**And** Site A (`slack.com`) has `notificationsEnabled` set to `true`
**And** Site B (`teams.microsoft.com`) has `notificationsEnabled` set to `true`
**And** Site C (`github.com/personal`) has `notificationsEnabled` set to `true`
**When** the app starts
**Then** Sites A, B, and C are all added to `_sites.loaded`
**And** all three webviews are created with their per-site containers
**And** all three begin executing JavaScript
**And** sites without `notificationsEnabled` remain as placeholders until visited

#### Scenario: Notification site auto-loads alongside manually visited site

**Given** container mode is active
**And** Site A (`slack.com`) has `notificationsEnabled` set to `true`
**And** the user manually visits Site B (`github.com`)
**When** both sites are loaded
**Then** both coexist in `_sites.loaded` with isolated profiles
**And** Site A continues running JavaScript in background

#### Scenario: First visit to a site

**Given** the user has not visited DuckDuckGo yet
**When** the user taps on DuckDuckGo in the drawer
**Then** DuckDuckGo is added to the loaded set
**And** only the DuckDuckGo webview is created
**And** other sites remain as empty placeholders

#### Scenario: Subsequent visits

**Given** the user has previously visited DuckDuckGo and GitHub
**When** the user switches between DuckDuckGo and GitHub
**Then** both webviews exist and preserve their state
**And** other unvisited sites remain as placeholders

### Requirement: LAZY-003 - Placeholder Widgets

The system SHALL use lightweight placeholder widgets for unvisited sites.

#### Scenario: Unvisited site in IndexedStack

**Given** the IndexedStack contains 8 sites
**When** only site 0 has been visited
**Then** sites 1-7 render as `SizedBox.shrink()` placeholders
**And** no network requests are made for sites 1-7

---

### Requirement: LAZY-004 - Preserve State on Revisit

The system SHALL preserve webview state (scroll position, form data, cookies) when switching between visited sites.

#### Scenario: Return to previously visited site

**Given** the user visited DuckDuckGo and scrolled down
**When** the user visits GitHub and returns to DuckDuckGo
**Then** DuckDuckGo's scroll position is preserved
**And** no page reload occurs

---

### Requirement: LAZY-005 - Handle Site Deletion

The system SHALL keep the loaded set naming the sites it named when a site is deleted.

#### Scenario: Delete a site above loaded ones

**Given** the sites at rows 0, 2, and 5 have been visited
**When** the site at row 1 is deleted
**Then** the same three sites are loaded, now at rows 0, 1 and 4
**And** deleting a loaded site takes it out of the loaded set

---

### Requirement: LAZY-006 - Clear State on Import

The system SHALL clear the loaded set when importing settings.

#### Scenario: Import new settings

**Given** the user has visited several sites
**When** settings are imported from a backup
**Then** the loaded set is cleared
**And** new sites start fresh without preloading

---

### Requirement: LAZY-007 - The Site On Screen Is Built

Whenever no activation is in flight, the site on screen SHALL be in the loaded set (`Inv_CurrentLoaded` in `formal/kernel.tla`). A switch whose residency step unloaded the site on screen (a domain conflict, a proxy mismatch) and that a change then supersedes without choosing a site (a delete or an archive close of another site) SHALL leave for the webspace list, as a change that removes the site on screen does, never LAZY-003's placeholder. The loaded set, the site on screen and every flow's target SHALL be held as sites, not rows, so no row move or removal can make any of them name another site; a removal takes its sites out of the loaded set and the screen. A row move SHALL supersede nothing: a switch it lands in finishes on the site it was opening (BUG-029). A home reset of the site on screen SHALL keep it loaded, its webview let go of so the frame builds it afresh at its home page (`SiteActivationController.unload`). The activation walks (`test/site_activation_walk_test.dart`) and every schedule within a bound (`test/activation_schedules_test.dart`) check both, and `formal/activation.tla`, whose `loaded` and `current` are sites, catches the mistake `nohome` in its delete world.

#### Scenario: A delete supersedes a switch that unloaded the site on screen

**Given** site A is on screen under the legacy engine
**And** the user taps site B on A's base domain, whose switch unloads A
**When** a third site is deleted before the switch finishes
**Then** the switch bails
**And** the webspace list is shown, not A's placeholder

#### Scenario: A home reset of the site on screen

**Given** site A always opens home and is on screen
**When** a link into A resets it to its home page
**Then** A stays loaded and is built afresh at its home page
**And** LAZY-003's placeholder is never shown

#### Scenario: A row move lands while a switch is opening a site

**Given** site A is on screen and the user taps site B
**When** the user moves a row before B's switch finishes
**Then** the switch finishes and B is on screen, loaded

#### Scenario: A row move lands during a memory-pressure unload

**Given** sites A, on screen, and B are loaded, and memory pressure is unloading B
**When** a row move shifts both before B's capture finishes
**Then** B leaves the loaded set
**And** A stays loaded

---

## Implementation

[`SiteRuntime`](../../../lib/controllers/site_runtime.dart) holds the sites with a built webview (`loaded`, least recently used first) and the site on screen (`shown`) as sites; `current` and `loadedRows` are the rows read off them. [`SiteWebViewStack`](../../../lib/widgets/site_webview_stack.dart) draws an `IndexedStack` over those rows and builds a webview only for a loaded one. `SiteRuntime.apply` takes a removed site out of both; a move leaves them as they are. An activation is `SiteActivationController.activate`.

---

## Benefits

### Performance
- Only visited sites load their URLs
- Reduced memory usage (fewer active webviews)
- Faster initial site display

### Network
- No background network requests for unvisited sites
- Reduced bandwidth usage
- No unnecessary cookies/tracking from background pages

### User Experience
- No unexpected nested webview popups
- Cleaner screenshot generation
- Sites only load when explicitly selected

### Testing
- Screenshot tests capture intended content
- No interference from background webviews
- Deterministic test behavior

---

## Files

### Modified
- `lib/main.dart`
  - Added `_sites.loaded` Set to `_WebSpacePageState`
  - Added `activate()` helper method
  - Updated all `_sites.current` assignments to use helper
  - Modified `IndexedStack` to check `_sites.loaded` before creating widgets
  - Added index shifting logic in site deletion handler
  - Clear `_sites.loaded` on settings import
