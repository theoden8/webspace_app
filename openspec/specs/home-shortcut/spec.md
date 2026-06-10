# Home Screen Shortcut Specification

## Purpose

Allow users to add a site shortcut to the home screen. Tapping the shortcut launches WebSpace and navigates to that site. On Android the system pins the shortcut directly via `ShortcutManagerCompat.requestPinShortcut`. On iOS 16+ and macOS 13+ the system exposes WebSpace sites as App Intents (`OpenSiteIntent`) that the user adds through the Shortcuts app (and pins to the home screen / Dock from there). The iOS and macOS Runner targets keep separate copies of the App Intents + plugin Swift because the App Group id differs (sandboxed macOS requires the team-prefixed form).

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

The system SHALL use the site's favicon as the shortcut icon when available, falling back to the app icon. The favicon is rasterized to a PNG on the Dart side (`exportIconAsPng`) before it crosses to native, because Android's `BitmapFactory` cannot decode SVG; this covers PNG, ICO, and SVG favicons uniformly.

#### Scenario: Site has a raster favicon

**Given** the site has a cached PNG or ICO favicon URL
**When** a shortcut is created
**Then** the favicon is decoded and re-encoded to PNG and used as the shortcut icon

#### Scenario: Site has an SVG favicon

**Given** the site's favicon is an SVG (e.g. claude.ai)
**When** a shortcut is created
**Then** the SVG is rasterized to a PNG and used as the shortcut icon
**And** the shortcut does NOT fall back to the WebSpace app icon

#### Scenario: Favicon cannot be fetched or rasterized

**Given** the site has no resolvable favicon, or fetch/rasterize fails (e.g. proxy fail-closed)
**When** a shortcut is created
**Then** the shortcut icon is the WebSpace app icon

---

### Requirement: HS-004 - Platform Availability

The "Home Shortcut" menu item SHALL be shown on Android, on iOS 16+, and on macOS 13+ (the App Intents path is shared between iOS and macOS). On Linux, web, iOS 13/14/15, and macOS 12 or earlier the menu item SHALL be hidden.

#### Scenario: Menu item shown on Android

**Given** the app is running on Android
**When** the user opens the overflow menu for a site that is not already pinned
**Then** the "Home Shortcut" option is shown

#### Scenario: Menu item shown on iOS 16+ or macOS 13+

**Given** the app is running on iOS 16.0+ or macOS 13.0+
**When** the user opens the overflow menu for any site
**Then** the "Home Shortcut" option is shown

#### Scenario: Menu item hidden on older iOS/macOS

**Given** the app is running on iOS 13/14/15 or macOS 12 or earlier
**When** the user opens the overflow menu
**Then** the "Home Shortcut" option is not shown

#### Scenario: Menu item hidden on Linux

**Given** the app is running on Linux
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

For the menu-visibility check the pinned set is widened to its **effective** form (`ShortcutPinState.effectivePinnedSiteIds`): the pinned ids plus any site a pinned tile has been rebound to via the HS-011 remap. A site an orphaned tile now routes to is already reachable, so the "Home Shortcut" item is hidden for it too — otherwise the user could pin a second, redundant tile to the same site.

#### Scenario: Android — rebound site hides the menu

**Given** an orphaned pinned tile was rebound to (or created) a site via HS-011
**When** the user opens the overflow menu for that site
**Then** the "Home Shortcut" option is not shown (the existing tile already reaches it)

---

### Requirement: HS-008 - iOS App Intent for Site Launching

The system SHALL expose an App Intent named "Open Site" (on iOS 16+ and macOS 13+) that opens WebSpace and navigates to a chosen site. The intent SHALL conform to `OpenIntent` so the system brings WebSpace to the foreground when the intent runs. The intent's site parameter SHALL be backed by a dynamic `AppEntity` query that returns the user's actual WebSpace sites.

Available on iOS 16+ / macOS 13+. On older OS versions the intent type is compiled (guarded by `@available`) but never registered; the menu item is hidden per HS-004.

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

The system SHALL keep the App Intents site picker in sync with the user's actual WebSpace sites. Whenever the persisted site list changes (`_saveWebViewModels`) and once per launch after `_restoreAppState` finishes loading models, the system SHALL write the current `[{id, name}]` list to the shared App Group `UserDefaults` (suite `group.org.codeberg.theoden8.webspace` on iOS; the team-prefixed `<TEAMID>.group.org.codeberg.theoden8.webspace` on sandboxed macOS) under key `shortcut_sites`, and SHALL invalidate the App Shortcuts parameter cache via `AppShortcutsProvider.updateAppShortcutParameters()` so the Shortcuts app re-queries the entity provider. The per-launch sync guards against iOS materializing the per-site App Shortcuts against an empty/stale App Group (e.g. on first launch after install, before any save has run), which can otherwise surface a single stale entry whose bound target no longer matches its displayed title.

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
**Then** the deleted site no longer appears in the App Intents picker (`suggestedEntities` is live-only)
**And** invoking the orphaned Shortcut still launches WebSpace and routes the id by domain, because `entities(for:)` resolves it from the tombstone list (HS-011 / HS-014)

#### Scenario: App Group unavailable

**Given** `UserDefaults(suiteName:)` returns nil (entitlement missing)
**When** `syncSites` is invoked
**Then** the method completes without crashing
**And** logs a warning

---

### Requirement: HS-010 - "Add to Home Screen" Dialog (iOS/macOS)

On iOS and macOS, tapping the "Home Shortcut" menu item SHALL show an instructional dialog explaining that the OS surfaces WebSpace sites through the Shortcuts app, with a primary button that deep-links to Shortcuts.app. The dialog copy SHALL match the platform (iOS: "Add to Home Screen" from the share menu; macOS: add to the Dock / run from the menu bar). The system SHALL NOT attempt to pin a shortcut programmatically (neither OS has such a public API).

#### Scenario: Dialog content

**Given** the user is on iOS 16+ or macOS 13+
**When** the user taps "Home Shortcut" in the overflow menu
**Then** an `AlertDialog` is shown explaining the flow ("find the Open Site action under WebSpace, pick this site, then add it")
**And** the dialog has an "Open Shortcuts" primary button and a "Cancel" button

#### Scenario: User confirms

**Given** the instructional dialog is shown
**When** the user taps "Open Shortcuts"
**Then** the system opens the URL `shortcuts://` (`UIApplication.shared.open` on iOS, `NSWorkspace.shared.open` on macOS)
**And** the Shortcuts.app launches

#### Scenario: User cancels

**Given** the instructional dialog is shown
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

### Requirement: HS-011 - Domain Fallback For Orphaned Shortcuts (Android + iOS/macOS)

A home shortcut identifies its site by the random `siteId`. When that `siteId` no longer maps to any site — the user deleted the site and created a new one for the same address — the tap would otherwise fail (Android falls back to the home screen; iOS shows "no longer available"). The system SHALL recover by resolving the launch against the current site list with a base-domain fallback, in order:

1. **Direct match** — the `siteId` maps to a current site. Open it (HS-002), no prompt.
2. **Remembered rebind** — a prior user choice mapped this `siteId` to a live site. Open it, no prompt.
3. **Domain match** — a url is known for this `siteId` and a current site shares its base domain. The system SHALL prompt the user to open that site; on confirm it SHALL remember the rebind so later taps resolve via step 2.
4. **Offer to create** — a url is known but no current site matches. The system SHALL prompt the user to create a new site for that url; on confirm it SHALL create the site, open it, and remember the rebind.

With no url known for the id, the system falls back to the home screen (legacy HS-002 behavior).

The resolution engine (`StartupRestoreEngine.resolveLaunch`) is platform-agnostic; the two platforms differ only in **where the url comes from**:

- **Android** — the launch intent is siteId-only, so a persisted `siteId -> url` ledger supplies the url (recorded for pinned sites, pruned to the pinned/current set; see HS-012).
- **iOS / macOS** — the launch can't be intercepted for a deleted entity unless the entity still resolves, so a deleted site is kept in a bounded **tombstone** list that `SiteEntityQuery.entities(for:)` resolves (while the picker stays live-only, HS-009). The resolved `SiteEntity` carries the url, which `OpenSiteIntent.perform()` writes into the launch payload (see HS-014). The choice for a no-match tap (reroute to an existing site or create one) is made when the handle is tapped, not at delete time, since neither OS can enumerate or disable home-screen tiles.

The ledger, tombstone list, and remembered-rebind map are machine state derived from shortcut activity: all are persisted in `SharedPreferences` (`shortcutUrlLedger`, `shortcutTombstones`, `shortcutSiteRemap`), are NOT part of settings export/import, and are bounded/pruned (HS-012, HS-014). A rebind whose resolved target is later deleted is dropped at startup.

#### Scenario: Pinned site deleted and recreated under a new id

**Given** the user pinned a shortcut for a site at `https://www.example.com`, then deleted that site and created a new one for the same address (a new random `siteId`)
**When** the user taps the original shortcut
**Then** the app prompts "Open <matching site>?" because the ledger url's base domain matches the recreated site
**And** on confirm the matching site is selected
**And** a subsequent tap of the same shortcut opens it directly with no prompt

#### Scenario: Pinned site was deleted, no replacement

**Given** the user deleted the site a shortcut pointed to and has no other site on that domain
**When** the user taps the shortcut
**Then** the app prompts "Create a new site for <url>?" using the ledger url
**And** on confirm a new site rooted at that url is created, selected, and remembered for that shortcut

#### Scenario: Deleting a site leaves its shortcut tappable

**Given** the user pinned a shortcut for a site and then deleted that site
**When** the user taps the pinned shortcut
**Then** the launcher launches WebSpace (it MUST NOT show "shortcut isn't available")
**And** the app routes the orphaned id through the ledger per this requirement
(`removeShortcut` removes only any dynamic copy and never disables the pinned tile)

#### Scenario: User declines the prompt

**Given** an orphaned shortcut's confirm/create prompt is shown
**When** the user taps Cancel
**Then** no site is opened or created and no rebind is remembered
**And** a later tap shows the prompt again

#### Scenario: Orphaned id with no ledger url

**Given** a tapped shortcut whose `siteId` maps to no site and for which the ledger holds no url
**When** the app resolves the launch
**Then** it launches on the home screen with no site activated (HS-002)

---

### Requirement: HS-012 - Shortcut URL Ledger Maintenance (Android)

The system SHALL maintain the HS-011 `siteId -> url` ledger against the launcher's actual pinned set, so it carries exactly the entries needed to route orphaned shortcuts and no stale cruft. On pin, and on every `initState` / `AppLifecycleState.resumed` (the same cadence as the HS-005 pinned-set refresh), the system SHALL:

- record `siteId -> initUrl` for every pinned shortcut whose site still exists, so a later deletion leaves a routable trail; and
- drop any ledger entry whose `siteId` is neither a current site nor in the pinned set (unreachable: the site is gone and no launcher tile points at it).

The reconcile logic is a pure function exercised in [test/startup_restore_engine_test.dart](../../../test/startup_restore_engine_test.dart).

#### Scenario: Pinning records the url

**Given** the user pins a shortcut for a site at `https://www.example.com`
**When** the pin completes
**Then** the ledger holds that site's `siteId -> https://www.example.com`

#### Scenario: Removing the launcher tile prunes the entry

**Given** a ledger entry exists for a site that has since been deleted and whose launcher tile the user has now removed
**When** the app next reconciles on resume
**Then** the entry is dropped (neither current nor pinned)

---

### Requirement: HS-013 - Delete-Time Shortcut Prompt (Android)

When the user deletes a site that is reachable by one or more pinned tiles, the system SHALL prompt for the fate of those now-orphaned tiles, since Android cannot remove a pinned tile programmatically. A tile "reaches" the deleted site if its id IS the deleted `siteId` OR a prior HS-011 rebind points it there (`remap[tile] == siteId`) — computed via `ShortcutPinState.tilesReaching` against a **fresh** `getPinnedSiteIds()` query (not the cached set, which lags pins made this session). The prompt offers three choices, applied to every reaching tile:

- **Keep** — leave the tile(s) enabled; a tap re-routes via HS-011 (open a domain match or offer to create). This is also the outcome if the prompt is dismissed.
- **Reassign** — pick another existing site; the system records a rebind (`tile -> chosen siteId`) for each reaching tile so a tap opens the chosen site directly (HS-011 step 2).
- **Disable** — disable each reaching tile (it greys out and the launcher rejects the tap until the user removes it from the home screen) and drop its ledger and rebind entries.

The prompt appears only on **Android**, and only when at least one pinned tile reaches the deleted site (detectable via `getPinnedSiteIds`); deleting a site no tile reaches is unaffected. The prompt is Android-only because only Android can enumerate tiles (to know one exists) and disable them (so the choice has a system-UI effect). On platforms with no tile-introspection or disable API (**iOS**; macOS and Linux if/when they gain a shortcut path), a delete-time prompt would fire blindly on every deletion, so the site is tombstoned silently (HS-014) and the choice is deferred to the only moment a handle reveals itself — when it is tapped (HS-011 step 3): a tap with no live/remap/domain match offers to reroute the handle to an existing site or create a new one, and the choice is remembered as a remap.

#### Scenario: iOS records a tombstone silently on delete

**Given** the user deletes a non-archive site on iOS
**When** the deletion completes
**Then** no prompt is shown
**And** a tombstone is recorded so a Shortcut bound to the site stays resolvable and routes when tapped

#### Scenario: Tapping a handle with no match offers reroute or create

**Given** a tapped Shortcut handle resolves to no live site, remap, or domain match
**When** the launch is handled
**Then** the user is offered to reroute the handle to an existing site or create a new one
**And** the choice is remembered as a remap so the next tap resolves directly

#### Scenario: Deleting a site a tile was rebound to still prompts

**Given** an orphaned tile was rebound (HS-011) to site B, and B has no shortcut of its own
**When** the user deletes B
**Then** the prompt still appears (the rebound tile reaches B)
**And** the chosen action applies to that tile, not to B's own (absent) shortcut

#### Scenario: Deleting a shortcutted site offers keep / reassign / disable

**Given** the user deletes a site that has a pinned home shortcut
**When** the deletion completes
**Then** the system prompts with Keep, Reassign, and Disable

#### Scenario: Reassign points the tile at another site

**Given** the delete-time prompt is shown
**When** the user chooses Reassign and picks another site
**Then** a rebind from the deleted siteId to the chosen site is remembered
**And** a later tap of the tile opens the chosen site with no prompt

#### Scenario: Disable greys out the tile

**Given** the delete-time prompt is shown
**When** the user chooses Disable
**Then** the pinned shortcut is disabled
**And** the deleted id's ledger and rebind entries are dropped

#### Scenario: Deleting a site with no shortcut shows no prompt

**Given** the user deletes a site that has no pinned shortcut
**When** the deletion completes
**Then** no shortcut prompt is shown

---

### Requirement: HS-014 - Shortcut Resolution and Tombstones (iOS/macOS)

iOS/macOS cannot enumerate or remove home-screen Shortcut tiles, and they mark a tile "no longer available" whenever `SiteEntityQuery.entities(for:)` returns nothing for its bound id. To keep every WebSpace shortcut tappable, `entities(for:)` SHALL resolve **every** requested id: from the live list, then the tombstone list, and otherwise to a **placeholder** `SiteEntity(id:, name: "Removed WebSpace site", url: nil)`. `suggestedEntities()` SHALL stay **live only** (the picker and materialized App Shortcuts stay clean — HS-009). The system SHALL also:

- on deletion of any non-archive site, append `{siteId, label, url}` to a bounded tombstone list (deduped by siteId, capped — oldest evicted), persist it (`shortcutTombstones`), and re-sync the App Group (live list under `shortcut_sites`, tombstones under `shortcut_tombstones`);
- have `OpenSiteIntent.perform()` write the resolved entity's url to the App Group (`pending_shortcut_url`) so the Dart side can route by domain when a url is known.

A tap is then resolved on the Dart side (HS-011): a tombstone-resolved tile carries its url and routes by domain (open a match / offer reroute or create); a placeholder-resolved tile (no url — typically a shortcut bound to a site deleted before tombstones existed) opens WebSpace and offers to reroute the handle to an existing site. The placeholder is the only mechanism that covers shortcuts for sites deleted before tombstoning existed, since their siteIds were never recorded and iOS/macOS expose no API to enumerate or delete the tiles.

Because the OS gives no way to know whether a tile exists, the system tombstones every qualifying deletion rather than only shortcutted ones; the cap bounds growth. Archive-tier sites are never tombstoned (ARCH-006).

#### Scenario: Deleted-site Shortcut (tombstoned) still launches and routes

**Given** the user added a home Shortcut for a site, then deleted that site
**When** the user taps the Shortcut
**Then** the bound `SiteEntity` resolves from the tombstone list (it is NOT in the picker)
**And** WebSpace launches and routes the orphaned id by domain per HS-011 (open a match or offer to reroute/create)

#### Scenario: Shortcut for a pre-tombstone deletion stays tappable

**Given** a Shortcut bound to a site that was deleted before any tombstone was recorded for it
**When** the user views or taps the Shortcut
**Then** it does NOT read "no longer available" (the id resolves to a placeholder)
**And** tapping it opens WebSpace and offers to reroute the handle to an existing site

#### Scenario: Tombstoned site stays out of the picker but still runs

**Given** a site has been deleted and tombstoned
**When** the user opens the "Open Site" action in Shortcuts.app
**Then** the deleted site does NOT appear in the picker (`suggestedEntities` is live-only)
**And** an existing Shortcut already bound to it still runs (resolved via `entities(for:)`)

#### Scenario: Tombstone list is bounded

**Given** the user deletes more sites than the tombstone cap
**When** each deletion is recorded
**Then** the oldest tombstones are evicted so the list never exceeds the cap

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
- `pinShortcut({siteId, label, iconUrl})` — **Android**: requests a pinned shortcut via `ShortcutManagerCompat.requestPinShortcut()`. **iOS 16+**: opens `shortcuts://` (the Dart UI shows the HS-010 instructional dialog first).
- `removeShortcut(siteId)` — Android: removes any dynamic shortcut copy but leaves the pinned launcher tile ENABLED, so an HS-011 tap on the now-orphaned shortcut still launches the app and re-routes via the ledger. (It MUST NOT call `disableShortcuts`, which makes the launcher reject the tap with "shortcut isn't available".) iOS: no-op (the App Intents site list is recomputed from `_webViewModels` on every save via HS-009).
- `getLaunchSiteId()` — **Android**: returns the bare `siteId` string from the launch intent extra, then drains it (`intent.removeExtra("siteId")`) so it fires once per tap. **iOS**: drains `pending_shortcut_site_id` + `pending_shortcut_url` from App Group UserDefaults (written by `OpenSiteIntent.perform()`) and returns a `{siteId, url}` map. Both platforms MUST consume-on-read: `_handleShortcutIntent` re-polls on every `AppLifecycleState.resumed`, so a non-draining read would re-navigate to the pinned site on a plain background/return with no new tap. The Dart `ShortcutService.getLaunch()` tolerates both shapes (`ShortcutLaunch`); for HS-011 the caller uses `launch.url ?? shortcutUrlLedger[siteId]` (iOS carries the url, Android supplies it from the ledger).
- `getPinnedSiteIds()` — Android: returns the set of `siteId`s currently pinned, derived from `ShortcutManagerCompat.getShortcuts(FLAG_MATCH_PINNED)` by stripping the `site_` prefix. iOS: always returns an empty list (no public API for pin-state introspection).
- `disableShortcut(siteId)` — **Android only** (HS-013): `ShortcutManagerCompat.disableShortcuts` greys out a pinned tile when the user opts to kill a deleted site's shortcut. No-op elsewhere.
- `syncSites({sites: [{siteId, label, url?, iconUrl?}], tombstones: [{siteId, label, url?}]})` — **iOS only**: writes the live `sites` to `shortcut_sites` and the deleted-site `tombstones` to `shortcut_tombstones` in App Group UserDefaults (HS-014), then calls `WebSpaceShortcuts.updateAppShortcutParameters()` to refresh the picker. No-op on Android.
- `isAppIntentsSupported()` — **iOS**: true if `#available(iOS 16, *)`. Other platforms: false.

### iOS App Intents

`ios/Runner/WebSpaceAppIntents.swift` defines (all `@available(iOS 16, *)`):

- `SiteEntity: AppEntity` — one synced site with `id: String` (siteId), `name: String`, and `url: String?` (so a tombstone-resolved deleted site can route by domain, HS-011/HS-014). `displayRepresentation` MUST use `DisplayRepresentation(title: LocalizedStringResource("%@", defaultValue: String.LocalizationValue(name)))`. The static `"%@"` key is stable for the compile-time App Intents metadata extractor while the runtime `defaultValue` still resolves to each site's name. Two earlier forms both collapse the materialized parameterized App Shortcuts (one per entity) down to a single visible entry in Shortcuts.app: `DisplayRepresentation(title: "\(name)")` (interpolation renders the literal `%@`), and `DisplayRepresentation(stringLiteral: name)` (resolves in the live picker but not in the materialized tiles, since a runtime string can't be a compile-time title key — the surviving tile also keeps a stale bound target).
- `SiteEntityQuery: EntityQuery` — `suggestedEntities()` returns `shortcut_sites` (live only) so the picker / materialized App Shortcuts stay clean; `entities(for:)` resolves **every** requested id from `shortcut_sites` ∪ `shortcut_tombstones`, falling back to a placeholder `SiteEntity` for any unknown id so a tile never reads "no longer available" (HS-014).
- `OpenSiteIntent: AppIntent, OpenIntent` — parameterized on `SiteEntity`. `openAppWhenRun = true` foregrounds WebSpace; `perform()` writes the chosen siteId to `pending_shortcut_site_id` and its url to `pending_shortcut_url` in App Group UserDefaults.
- `WebSpaceShortcuts: AppShortcutsProvider` — declares the discoverable "Open Site" App Shortcut with phrase template `"Open \(\.$target) in WebSpace"`.

The Swift method-channel handler lives in `ios/Runner/ShortcutsPlugin.swift` and is registered alongside the other plugins in `AppDelegate.application(_:didFinishLaunchingWithOptions:)`.

### Shortcut Intent

The shortcut launches `MainActivity` with:
- `action`: `ACTION_VIEW`
- `extra`: `siteId` = the site's unique ID
- `flags`: `FLAG_ACTIVITY_NEW_TASK | FLAG_ACTIVITY_CLEAR_TOP`

### Launch Handling

On app start and on `onNewIntent` (app already running), read the launch
`siteId` via `ShortcutService.getLaunchSiteId()`, pair it with its
`shortcutUrlLedger` url (HS-011/HS-012), and resolve through
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
   - `LaunchNone` — no intent, or an orphaned siteId with no ledger url
     (home screen).
2. On cold launch the confirm/create prompts are deferred to the first
   post-frame (no UI exists mid-`_restoreAppState`); direct hits activate
   inline. The warm path (`_handleShortcutIntent`) prompts immediately.
3. The remembered rebind map (`shortcutSiteRemap`) and the url ledger
   (`shortcutUrlLedger`) are persisted in `SharedPreferences` (HS-011 /
   HS-012); dangling rebind targets are pruned at startup and the ledger
   is reconciled to the pinned set.

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
