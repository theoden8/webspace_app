# Home Screen Shortcut Specification

## Purpose

Allow users to add a site shortcut to the home screen. Tapping the shortcut launches WebSpace and navigates to that site. On Android the system pins the shortcut directly via `ShortcutManagerCompat.requestPinShortcut`. On iOS 16+ the system exposes WebSpace sites as App Intents (`OpenSiteIntent`) that the user adds through the Shortcuts app and pins to the home screen from there.

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

#### Scenario: Resume after shortcut launch does not re-navigate

**Given** the user launched WebSpace via a home shortcut for site A
**And** the user then switched to site B inside the app
**When** the user backgrounds WebSpace and returns to it (no new shortcut tap)
**Then** site B stays selected
**And** the app does not jump back to site A
(The launch siteId is consumed on first read; subsequent
`AppLifecycleState.resumed` polls return null.)

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

### Requirement: HS-004 - Platform Availability

The "Home Shortcut" menu item SHALL be shown on Android and on iOS 16+. On macOS, Linux, web, and iOS 13/14/15 the menu item SHALL be hidden.

#### Scenario: Menu item shown on Android

**Given** the app is running on Android
**When** the user opens the overflow menu for a site that is not already pinned
**Then** the "Home Shortcut" option is shown

#### Scenario: Menu item shown on iOS 16 or later

**Given** the app is running on iOS 16.0 or later
**When** the user opens the overflow menu for any site
**Then** the "Home Shortcut" option is shown

#### Scenario: Menu item hidden on iOS 15 or earlier

**Given** the app is running on iOS 13, 14, or 15
**When** the user opens the overflow menu
**Then** the "Home Shortcut" option is not shown

#### Scenario: Menu item hidden on macOS and Linux

**Given** the app is running on macOS or Linux
**When** the user opens the overflow menu
**Then** the "Home Shortcut" option is not shown

---

### Requirement: HS-005 - Hide When Already Pinned (Android only)

Sites in WebSpace are stable, so a home shortcut is a one-time setup per site. On Android, the "Home Shortcut" menu item SHALL be hidden when the current site already has a pinned shortcut, and SHALL reappear if the user removes the shortcut from the launcher. On iOS this scenario does not apply: iOS does not expose an API to query whether an App Shortcut tile is currently on the home screen, so the menu item stays available on iOS regardless of pin state.

#### Scenario: Android — site already has a pinned shortcut

**Given** the user previously pinned a shortcut for the current site on Android
**When** the user opens the overflow menu
**Then** the "Home Shortcut" option is not shown for that site

#### Scenario: Android — shortcut removed from launcher

**Given** the user removed a previously pinned shortcut from their home screen
**When** the user backgrounds and re-foregrounds the app, then opens the overflow menu for that site
**Then** the "Home Shortcut" option is shown again

#### Scenario: iOS — pin state is not detected

**Given** the user has already added a shortcut for the current site to the iOS home screen
**When** the user opens the overflow menu
**Then** the "Home Shortcut" option is still shown (iOS cannot detect prior pinning)

The Android pinned-shortcut set is queried via `ShortcutManagerCompat.getShortcuts(FLAG_MATCH_PINNED)` exposed through the platform channel as `getPinnedSiteIds`. The cached set is refreshed on `initState` and on `AppLifecycleState.resumed`, which covers both the in-app pin flow (the launcher's pin dialog backgrounds the app) and out-of-app removal. On iOS the same channel method returns an empty list.

---

### Requirement: HS-008 - iOS App Intent for Site Launching

The system SHALL expose an iOS App Intent named "Open Site" that opens WebSpace and navigates to a chosen site. The intent SHALL conform to `OpenIntent` so iOS brings WebSpace to the foreground when the intent runs. The intent's site parameter SHALL be backed by a dynamic `AppEntity` query that returns the user's actual WebSpace sites.

Only available on iOS 16+. On older iOS the intent type is compiled but never registered; the menu item is hidden per HS-004.

#### Scenario: User adds the Open Site shortcut in Shortcuts.app

**Given** the user has WebSpace installed on iOS 16 or later
**When** the user opens the Shortcuts app and adds the "Open Site" action from WebSpace
**Then** the action shows a "Site" parameter whose picker lists every site currently in WebSpace by name

#### Scenario: Every site appears as a discoverable App Shortcut

**Given** the user has multiple sites in WebSpace on iOS 16 or later
**When** the user opens the Shortcuts app and views the WebSpace section
**Then** every site materializes as its own "Open <site name> in WebSpace" entry (subject to the iOS-imposed App Shortcuts cap)
**And** the entries are not collapsed to a single placeholder (e.g. "Open %@ in WebSpace") regardless of how many sites are synced

#### Scenario: Shortcut launches WebSpace to the chosen site

**Given** the user has added a Shortcut wired to `OpenSiteIntent` with a specific site selected
**When** the user taps the Shortcut tile on their home screen
**Then** WebSpace launches (or comes to the foreground)
**And** the chosen site is selected and loaded
**And** the site's `currentUrl` resets to its `initUrl` on cold-launch (HS-006)

#### Scenario: Cold launch via Shortcut

**Given** WebSpace is not running
**When** the user taps a Shortcut wired to `OpenSiteIntent` from the home screen
**Then** the app cold-launches
**And** `_restoreAppState` reads the pending siteId via `ShortcutService.getLaunchSiteId()`
**And** the chosen site is the initial active index

#### Scenario: Warm launch via Shortcut

**Given** WebSpace is already running in the background
**When** the user taps a Shortcut wired to `OpenSiteIntent`
**Then** the app comes to the foreground
**And** `_handleShortcutIntent` reads the pending siteId on the resume lifecycle event
**And** the chosen site becomes active

---

### Requirement: HS-009 - Site List Synced to App Group

The system SHALL keep the iOS App Intents site picker in sync with the user's actual WebSpace sites. Whenever the persisted site list changes (`_saveWebViewModels`) and once per launch after `_restoreAppState` finishes loading models, the system SHALL write the current `[{id, name}]` list to `UserDefaults(suiteName: "group.org.codeberg.theoden8.webspace")` under key `shortcut_sites`, and SHALL invalidate the App Shortcuts parameter cache via `AppShortcutsProvider.updateAppShortcutParameters()` so the Shortcuts app re-queries the entity provider. The per-launch sync guards against iOS materializing the per-site App Shortcuts against an empty/stale App Group (e.g. on first launch after install, before any save has run), which can otherwise surface a single stale entry whose bound target no longer matches its displayed title.

#### Scenario: Site added

**Given** WebSpace is running on iOS 16+
**When** the user creates a new site
**Then** the new site appears in the App Intents picker the next time Shortcuts.app queries

#### Scenario: Site renamed

**Given** a site exists in WebSpace
**When** the user renames it
**Then** the new name is reflected in the App Intents picker after the next save

#### Scenario: Site deleted

**Given** a site is referenced by an existing user-created Shortcut
**When** the user deletes the site in WebSpace
**Then** the deleted site no longer appears in the App Intents picker
**And** invoking the orphaned Shortcut performs no navigation (the entity resolves to nil)

#### Scenario: App Group unavailable

**Given** `UserDefaults(suiteName:)` returns nil (entitlement missing)
**When** `syncSites` is invoked
**Then** the method completes without crashing
**And** logs a warning

---

### Requirement: HS-010 - iOS "Add to Home Screen" Dialog

On iOS, tapping the "Home Shortcut" menu item SHALL show an instructional dialog explaining that iOS surfaces WebSpace sites through the Shortcuts app, with a primary button that deep-links to Shortcuts.app. The system SHALL NOT attempt to pin a shortcut programmatically (iOS has no such public API).

#### Scenario: Dialog content

**Given** the user is on iOS 16+
**When** the user taps "Home Shortcut" in the overflow menu
**Then** an `AlertDialog` is shown explaining the iOS flow ("find the Open Site action under WebSpace, pick this site, then tap Add to Home Screen")
**And** the dialog has an "Open Shortcuts" primary button and a "Cancel" button

#### Scenario: User confirms

**Given** the iOS instructional dialog is shown
**When** the user taps "Open Shortcuts"
**Then** the system opens the URL `shortcuts://` via `UIApplication.shared.open`
**And** the Shortcuts.app launches

#### Scenario: User cancels

**Given** the iOS instructional dialog is shown
**When** the user taps "Cancel"
**Then** the dialog dismisses
**And** Shortcuts.app is not opened

---

### Requirement: HS-007 - Shortcut Tap Propagates To Flagged Siblings

The system SHALL reset `currentUrl` to `initUrl` for every flagged
sibling of the launched site when an Android home-shortcut is tapped.
A site is "flagged" if `alwaysOpenHome = true` or `incognito = true`.
A "sibling" is any site that shares at least one named webspace with
the launched site. The full cold/warm, "All"-webspace, and scenario
detail lives in [always-open-home/AOH-004](../always-open-home/spec.md).

This requirement layers on top of HS-006: HS-006 governs the launched
site itself on cold launch; HS-007 governs the propagation to siblings
in any webspace containing the launched site.

#### Scenario: Sibling resets cross-reference

**Given** the user has set `alwaysOpenHome = true` for site B in webspace W and the app is running
**When** the user warm-taps the home shortcut for site A in webspace W
**Then** B's `currentUrl` resets to its `initUrl` per [AOH-004](../always-open-home/spec.md)
**And** B's webview is disposed so the next paint reloads at home

---

### Requirement: HS-011 - Domain Fallback For Orphaned Shortcuts

A pinned shortcut carries the site's `url` alongside its `siteId`. The system SHALL use that url to recover when a tapped shortcut's `siteId` no longer maps to any site — which happens after a settings restore on a new device (siteIds are random per install) or a delete+recreate. Recovery resolution runs in order:

1. **Direct match** — the `siteId` maps to a current site. Open it (HS-002), no prompt.
2. **Remembered rebind** — a prior user choice mapped this `siteId` to a live site. Open it, no prompt.
3. **Domain match** — a current site shares the shortcut url's base domain. The system SHALL prompt the user to open that site; on confirm it SHALL remember the rebind so later taps resolve via step 2.
4. **Offer to create** — no current site matches. The system SHALL prompt the user to create a new site for the shortcut url; on confirm it SHALL create the site, open it, and remember the rebind.

A shortcut pinned before this feature carries no url; if its `siteId` is gone the system falls back to the home screen (legacy HS-002 behavior). The remembered rebind map is machine state derived from shortcut activity: it is persisted in `SharedPreferences` under `shortcutSiteRemap`, is NOT part of settings export/import, and entries whose resolved target is later deleted are pruned at startup.

On Android the url rides the launch intent as the `siteUrl` extra (drained with `siteId`). On iOS the synced site list and `OpenSiteIntent` carry the url through the App Group (`pending_shortcut_url`).

#### Scenario: Restored backup, same site exists under a new siteId

**Given** the user restored a settings backup on a new device, so a site for `https://www.example.com` exists but under a different `siteId` than the one baked into a previously pinned shortcut
**When** the user taps that shortcut
**Then** the app prompts "Open <matching site>?" because the shortcut url's base domain matches the restored site
**And** on confirm the matching site is selected
**And** a subsequent tap of the same shortcut opens it directly with no prompt

#### Scenario: Pinned site was deleted, no replacement

**Given** the user deleted the site a shortcut pointed to and has no other site on that domain
**When** the user taps the shortcut
**Then** the app prompts "Create a new site for <url>?"
**And** on confirm a new site rooted at the shortcut url is created, selected, and remembered for that shortcut

#### Scenario: User declines the prompt

**Given** an orphaned shortcut's confirm/create prompt is shown
**When** the user taps Cancel
**Then** no site is opened or created and no rebind is remembered
**And** a later tap shows the prompt again

#### Scenario: Legacy shortcut without a url

**Given** a shortcut pinned before HS-011 (no url extra) whose `siteId` no longer maps to a site
**When** the user taps it
**Then** the app launches on the home screen with no site activated (HS-002)

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

Both Android and iOS share the channel `MethodChannel('org.codeberg.theoden8.webspace/shortcuts')`.

Methods:
- `pinShortcut({siteId, label, siteUrl, iconUrl})` — **Android**: requests a pinned shortcut via `ShortcutManagerCompat.requestPinShortcut()`, baking `siteUrl` into the launch intent for HS-011 domain fallback. **iOS 16+**: opens `shortcuts://` (the Dart UI shows the HS-010 instructional dialog first).
- `removeShortcut(siteId)` — Android: disables and removes the dynamic+pinned shortcut for a deleted site. iOS: no-op (the App Intents site list is recomputed from `_webViewModels` on every save via HS-009).
- `getLaunchSiteId()` — **Android**: returns a `{siteId, url}` map from the launch intent extras, then drains both (`intent.removeExtra(...)`) so it fires once per tap. **iOS**: drains the `pending_shortcut_site_id` + `pending_shortcut_url` keys from App Group UserDefaults (written by `OpenSiteIntent.perform()`) into the same map. Both platforms MUST consume-on-read: `_handleShortcutIntent` re-polls on every `AppLifecycleState.resumed`, so a non-draining read would re-navigate to the pinned site on a plain background/return with no new tap. The Dart `ShortcutService.getLaunch()` wraps the map as a `ShortcutLaunch`; a bare-string return is tolerated for shortcuts pinned before HS-011 (url null).
- `getPinnedSiteIds()` — Android: returns the set of `siteId`s currently pinned, derived from `ShortcutManagerCompat.getShortcuts(FLAG_MATCH_PINNED)` by stripping the `site_` prefix. iOS: always returns an empty list (no public API for pin-state introspection).
- `syncSites({sites: [{siteId, label, iconUrl?}]})` — **iOS only**: writes `[{id, name}]` to App Group UserDefaults under `shortcut_sites` and calls `WebSpaceShortcuts.updateAppShortcutParameters()` to refresh the Shortcuts.app picker. No-op on Android.
- `isAppIntentsSupported()` — **iOS**: true if `#available(iOS 16, *)`. Other platforms: false.

### iOS App Intents

`ios/Runner/WebSpaceAppIntents.swift` defines (all `@available(iOS 16, *)`):

- `SiteEntity: AppEntity` — one synced site with `id: String` (siteId) and `name: String`. `displayRepresentation` MUST use `DisplayRepresentation(title: LocalizedStringResource("%@", defaultValue: String.LocalizationValue(name)))`. The static `"%@"` key is stable for the compile-time App Intents metadata extractor while the runtime `defaultValue` still resolves to each site's name. Two earlier forms both collapse the materialized parameterized App Shortcuts (one per entity) down to a single visible entry in Shortcuts.app: `DisplayRepresentation(title: "\(name)")` (interpolation renders the literal `%@`), and `DisplayRepresentation(stringLiteral: name)` (resolves in the live picker but not in the materialized tiles, since a runtime string can't be a compile-time title key — the surviving tile also keeps a stale bound target).
- `SiteEntityQuery: EntityQuery` — reads the synced site list from App Group UserDefaults under `shortcut_sites` so Shortcuts.app's parameter picker shows real WebSpace sites.
- `OpenSiteIntent: AppIntent, OpenIntent` — parameterized on `SiteEntity`. `openAppWhenRun = true` foregrounds WebSpace; `perform()` writes the chosen siteId to App Group UserDefaults under `pending_shortcut_site_id`.
- `WebSpaceShortcuts: AppShortcutsProvider` — declares the discoverable "Open Site" App Shortcut with phrase template `"Open \(\.$target) in WebSpace"`.

The Swift method-channel handler lives in `ios/Runner/ShortcutsPlugin.swift` and is registered alongside the other plugins in `AppDelegate.application(_:didFinishLaunchingWithOptions:)`.

### Shortcut Intent

The shortcut launches `MainActivity` with:
- `action`: `ACTION_VIEW`
- `extra`: `siteId` = the site's unique ID
- `flags`: `FLAG_ACTIVITY_NEW_TASK | FLAG_ACTIVITY_CLEAR_TOP`

### Launch Handling

On app start and on `onNewIntent` (app already running), read the launch
target via `ShortcutService.getLaunch()` and resolve it through
[`StartupRestoreEngine.resolveLaunch`](../../../lib/services/startup_restore_engine.dart):

1. `resolveLaunch(shortcutSiteId, shortcutUrl, models, rememberedRemap)`
   returns a sealed `LaunchResolution`:
   - `LaunchOpenSite(index)` — direct siteId hit or a remembered rebind;
     caller switches to `index` with no prompt.
   - `LaunchConfirmExisting(index, shortcutSiteId)` — siteId gone, a
     current site matches the url's base domain; caller prompts, and on
     confirm remembers `shortcutSiteId -> that site`.
   - `LaunchOfferCreate(url, shortcutSiteId)` — siteId gone, no domain
     match; caller prompts to create a site for `url`, remembering the
     rebind on confirm.
   - `LaunchNone` — no intent, or a legacy url-less shortcut whose siteId
     is gone (home screen).
2. On cold launch the confirm/create prompts are deferred to the first
   post-frame (no UI exists mid-`_restoreAppState`); direct hits activate
   inline. The warm path (`_handleShortcutIntent`) prompts immediately.
3. The remembered rebind map is persisted in `SharedPreferences` under
   `shortcutSiteRemap` (HS-011) and pruned of dangling targets at startup.

`resolveLaunchTarget` is retained as the siteId-only view (direct hit or
null). Both rules are exercised headlessly in
[test/startup_restore_engine_test.dart](../../../test/startup_restore_engine_test.dart);
no widget tree required.

### Files

#### New
- `lib/services/shortcut_service.dart` — Flutter wrapper around the platform channel (Android pin + iOS sync/launch)
- `lib/services/startup_restore_engine.dart` — `resolveLaunchTarget` shortcut→index resolution
- `ios/Runner/WebSpaceAppIntents.swift` — `SiteEntity`, `SiteEntityQuery`, `OpenSiteIntent`, `WebSpaceShortcuts` (iOS 16+)
- `ios/Runner/ShortcutsPlugin.swift` — iOS method-channel handler
- `test/startup_restore_engine_test.dart` — unit tests for the resolution rule
- `test/shortcut_service_test.dart` — unit tests for the Dart service surface
- `openspec/specs/home-shortcut/spec.md` — this specification

#### Modified
- `android/app/src/main/kotlin/.../MainActivity.kt` — native shortcut creation and intent handling
- `ios/Runner/AppDelegate.swift` — wire `ShortcutsPlugin`
- `ios/Runner.xcodeproj/project.pbxproj` — register the new Swift files
- `lib/main.dart` — menu item, shortcut action, launch intent handling, iOS site sync

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
