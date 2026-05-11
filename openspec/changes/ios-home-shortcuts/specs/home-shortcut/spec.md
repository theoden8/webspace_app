# Home Shortcut — iOS App Intents delta

## MODIFIED Requirements

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

On Android, the "Home Shortcut" menu item SHALL be hidden when the current site already has a pinned shortcut, and SHALL reappear if the user removes the shortcut from the launcher. On iOS this scenario does not apply: iOS does not expose an API to query whether an App Shortcut tile is currently on the home screen, so the menu item stays available on iOS regardless of pin state.

#### Scenario: Android — site already has a pinned shortcut

**Given** the user previously pinned a shortcut for the current site on Android
**When** the user opens the overflow menu
**Then** the "Home Shortcut" option is not shown for that site

#### Scenario: Android — shortcut removed from launcher

**Given** the user removed a previously pinned shortcut from their Android home screen
**When** the user backgrounds and re-foregrounds the app, then opens the overflow menu
**Then** the "Home Shortcut" option is shown again

#### Scenario: iOS — pin state is not detected

**Given** the user has already added a shortcut for the current site to the iOS home screen
**When** the user opens the overflow menu
**Then** the "Home Shortcut" option is still shown (iOS cannot detect prior pinning)

---

## ADDED Requirements

### Requirement: HS-006 - iOS App Intent for Site Launching

The system SHALL expose an iOS App Intent named "Open Site" that opens WebSpace and navigates to a chosen site. The intent SHALL conform to `OpenIntent` so iOS brings WebSpace to the foreground when the intent runs. The intent's site parameter SHALL be backed by a dynamic `AppEntity` query that returns the user's actual WebSpace sites.

#### Scenario: User adds the Open Site shortcut in Shortcuts.app

**Given** the user has WebSpace installed on iOS 16 or later
**When** the user opens the Shortcuts app and adds the "Open Site" action from WebSpace
**Then** the action shows a "Site" parameter whose picker lists every site currently in WebSpace by name

#### Scenario: Shortcut launches WebSpace to the chosen site

**Given** the user has added a Shortcut wired to `OpenSiteIntent` with a specific site selected
**When** the user taps the Shortcut tile on their home screen
**Then** WebSpace launches (or comes to the foreground)
**And** the chosen site is selected and loaded
**And** the site's `currentUrl` is reset to its `initUrl` (matching the Android home-shortcut "land on home" behavior)

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

### Requirement: HS-007 - Site List Synced to App Group

The system SHALL keep the iOS App Intents site picker in sync with the user's actual WebSpace sites. Whenever the persisted site list changes, the system SHALL write the current `[{siteId, name}]` list to `UserDefaults(suiteName: "group.org.codeberg.theoden8.webspace")` under key `shortcut_sites`, and SHALL invalidate the App Shortcuts parameter cache via `AppShortcutsProvider.updateAppShortcutParameters()` so the Shortcuts app re-queries the entity provider.

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

### Requirement: HS-008 - iOS "Add to Home Screen" Dialog

On iOS, tapping the "Home Shortcut" menu item SHALL show an instructional dialog explaining that iOS surfaces WebSpace sites through the Shortcuts app, with a primary button that deep-links to Shortcuts.app. The system SHALL NOT attempt to pin a shortcut programmatically (iOS has no such public API).

#### Scenario: Dialog content

**Given** the user is on iOS 16+
**When** the user taps "Home Shortcut" in the overflow menu
**Then** an `AlertDialog` is shown explaining: "iOS adds WebSpace sites via the Shortcuts app. Find the 'Open Site' action for WebSpace, pick this site, then tap 'Add to Home Screen'."
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
