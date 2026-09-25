# Block screenshots

## ADDED Requirements

### Requirement: SCREENBLOCK-001 - Offered only where the platform can block capture

The block SHALL be offered on Android only, where `FLAG_SECURE` keeps the
window out of screenshots, screen recordings, screen sharing and the
recent-apps preview. On iOS, macOS and Linux both switches SHALL be absent,
because no public API there keeps a screenshot out (on macOS 15+
ScreenCaptureKit ignores `NSWindow.sharingType`). A stored value SHALL be kept
on every platform, so a backup restored on Android still carries it.

#### Scenario: No switch on iOS

**Given** the app runs on iOS
**When** the user opens a site's Privacy screen or App settings
**Then** no Block screenshots switch is shown

#### Scenario: A stored value survives a platform without the switch

**Given** a site with `blockScreenshots` on is imported on macOS
**When** the sites are saved and later exported
**Then** the site's JSON still carries `blockScreenshots: true`

---

### Requirement: SCREENBLOCK-002 - The window is blocked while a blocking site is on screen

The window SHALL be blocked when the app-wide switch is on, or when the site on
screen has its own switch on (`screenCaptureBlocked`). With no site on screen
(the webspaces list), only the app-wide switch SHALL count. The decision SHALL
be applied from `_WebSpacePageState.build`, so the site shown and the window
flag change in the same frame, whichever path changed the site. A nested
webview (`InAppWebViewScreen`) shares the window, so it is covered by its
parent site's value without carrying the field.

Implementation: `lib/services/screen_capture_guard.dart`,
`android/app/src/main/kotlin/org/codeberg/theoden8/webspace/ScreenCapturePlugin.kt`.

#### Scenario: Switching away from a blocking site

**Given** the app-wide switch is off
**And** site "Bank" has Block screenshots on and site "News" has it off
**When** the user switches from "Bank" to "News"
**Then** `FLAG_SECURE` is cleared and a screenshot of "News" is taken normally

#### Scenario: Back to the webspaces list

**Given** the app-wide switch is off and "Bank" is on screen with the block on
**When** the user returns to the webspaces list
**Then** `FLAG_SECURE` is cleared

#### Scenario: App-wide switch

**Given** the app-wide switch is on
**When** any site or the webspaces list is on screen
**Then** `FLAG_SECURE` is set
**And** the recent-apps preview of the app is hidden

#### Scenario: Nested webview

**Given** "Bank" has Block screenshots on
**When** a link opens in a nested webview over "Bank"
**Then** the window stays blocked while the nested webview is shown

---

### Requirement: SCREENBLOCK-003 - Settings

A site's Privacy screen SHALL show a Block screenshots switch under a Screen
capture heading. While the app-wide switch is on, the site's switch SHALL read
as on, be locked, and carry the subtitle "On for the whole app in App
Settings"; the site's stored value SHALL be kept, so turning the app-wide
switch off restores the user's own choice. App settings > Privacy SHALL show the
app-wide Block screenshots switch. What each switch covers SHALL be explained in
its hint, not its subtitle (settings-hints).

#### Scenario: Locked on under the app-wide switch

**Given** the app-wide switch is on
**When** the user opens a site's Privacy screen
**Then** the Block screenshots switch is on and cannot be changed
**And** its subtitle says it is on for the whole app

#### Scenario: Privacy row summary

**Given** a site has Block screenshots on and Tracking Protection off
**When** the user opens the site's settings
**Then** the Privacy row's summary lists Block screenshots

---

### Requirement: SCREENBLOCK-004 - Persistence

`WebViewModel.blockScreenshots` SHALL default to off and SHALL be written to
JSON only when on, so a site that never used it serialises exactly as before. A
wrong-typed value SHALL read as off. It SHALL ride settings backups and site QR
codes (`SiteSettingsQrCodec.includedKeys`): it is configuration, not a secret.
The app-wide switch SHALL be registered in `kExportedAppPrefs` under
`blockScreenshots`, default off, and re-read after an import.

Archive-tier sites (ARCH-006) SHALL keep the stored value: the flag writes
nothing to disk and names no site, it only withholds the window's pixels.

#### Scenario: Backup round trip

**Given** the app-wide switch is on and site "Bank" has Block screenshots on
**When** the user exports settings and imports them on another Android device
**Then** the app-wide switch is on
**And** "Bank" has Block screenshots on

#### Scenario: Unused field is not written

**Given** a site that never turned Block screenshots on
**When** its JSON is produced
**Then** it has no `blockScreenshots` key
