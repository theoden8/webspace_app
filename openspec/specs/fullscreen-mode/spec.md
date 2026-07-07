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

The system SHALL allow the user to exit full screen by tapping the top edge of the screen. The back gesture/button SHALL retain its normal behavior (web history back, open drawer, etc.) even while in full screen.

#### Scenario: Exit via top edge tap

**Given** the user is in full screen mode
**When** the user taps the top edge of the screen (status bar / notch safe area + 20px)
**Then** full screen mode is exited

#### Scenario: Exit via tab strip menu

**Given** "Keep Tab Strip in Full Screen" is enabled
**And** the user is in full screen mode with the tab strip visible
**When** the user opens the tab strip overflow menu and taps "Exit Full Screen"
**Then** full screen mode is exited

**Rationale:** With the tab strip kept in full screen, its overflow menu is the only chrome reachable while immersed. The "Full Screen" menu item reflects the current state ("Exit Full Screen" when already full screen) and toggles rather than re-entering.

#### Scenario: Back gesture in full screen

**Given** the user is in full screen mode
**When** the user performs a back gesture (swipe or button)
**Then** the back gesture behaves normally (web history back, open drawer, etc.)
**And** full screen mode remains active

#### Scenario: Fullscreen hint

**Given** the user enters full screen mode
**Then** a brief SnackBar is shown: "Tap the top of the screen to exit full screen"
**And** a visible translucent handle is displayed just below the status bar / notch area

**Rationale:** The exit zone spans `MediaQuery.padding.top + 20px` vertically but only a centered 96px-wide band catches the tap; the top corners stay transparent to pointers so web-app controls there (e.g. a sidebar toggle) receive the tap instead of exiting fullscreen. The back gesture is not consumed by fullscreen so users can navigate normally while immersed.

#### Scenario: Web control in top corner stays tappable

**Given** the user is in full screen mode on a site with a control in the top-left or top-right corner
**When** the user taps that corner
**Then** the tap reaches the web content (full screen is not exited)
**And** tapping the centered handle still exits full screen

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

### Requirement: FS-007 - Keep Tab Strip in Full Screen

The system SHALL support a global option to keep the site tab strip visible in full screen while the app bar and URL bar stay hidden, giving more screen space without losing quick site switching. The option only applies when the tab strip is enabled.

#### Scenario: Tab strip kept in full screen

**Given** "Site Tab Strip" is enabled
**And** "Keep Tab Strip in Full Screen" is enabled
**When** the user enters full screen mode
**Then** the app bar, URL bar, find toolbar, and system UI are hidden
**And** the tab strip remains visible at the bottom

#### Scenario: Tab strip hidden in full screen (default)

**Given** "Keep Tab Strip in Full Screen" is disabled
**When** the user enters full screen mode
**Then** the tab strip is hidden along with the app bar and URL bar

#### Scenario: Option gated on tab strip

**Given** "Site Tab Strip" is disabled
**Then** the "Keep Tab Strip in Full Screen" toggle is disabled (no tab strip to keep)

---

### Requirement: FS-008 - Full Screen on Shortcut Launch

The system SHALL support a global option, enabled by default, to enter full screen automatically when a site is opened from a home-screen shortcut (Android pinned shortcut / iOS App Intents). The option is independent of the per-site `fullscreenMode` setting and applies to both cold and warm shortcut launches.

#### Scenario: Cold launch from shortcut

**Given** "Full screen on shortcut launch" is enabled
**And** the app is not running
**When** the user taps a pinned home-screen shortcut for a site
**Then** the app launches that site directly in full screen mode

#### Scenario: Warm launch from shortcut

**Given** "Full screen on shortcut launch" is enabled
**And** the app is already running in the background
**When** the user taps a pinned home-screen shortcut for a site
**Then** the app switches to that site and enters full screen mode

#### Scenario: Option disabled

**Given** "Full screen on shortcut launch" is disabled
**When** the user opens a site from a home-screen shortcut
**Then** full screen is governed only by the site's per-site `fullscreenMode` (not entered just because it was opened via a shortcut)

#### Scenario: Normal site switch is unaffected

**Given** "Full screen on shortcut launch" is enabled
**When** the user switches sites from inside the app (tab strip, drawer) rather than via a shortcut
**Then** full screen is governed only by the target site's `fullscreenMode`

---

### Requirement: FS-006 - Content Reachable Under Persistent System Bars

The system SHALL keep the site's content reachable in full screen even when the platform fails to hide the system bars (e.g. Android 15 edge-to-edge, where `immersiveSticky` does not always hide the status/navigation bars).

#### Scenario: System bar persists in full screen

**Given** the user is in full screen mode on a device where a system bar remains visible
**When** the user taps the site's controls near the top or bottom edge
**Then** the body is inset by the system bar's safe area so the controls are not hidden behind the bar and remain tappable

#### Scenario: System bars fully hidden

**Given** the user is in full screen mode on a device where `immersiveSticky` hides both bars
**Then** the body safe-area inset is ~0
**And** the webview fills the entire screen

---

### Requirement: FS-010 - Use Display Cutout Space in Full Screen

The system SHALL render the webview into the display cutout (notch) region on the short edges in full screen, so no black letterbox bar appears beside the notch. Out of full screen the body SHALL inset around the cutout so app chrome and content avoid the notch.

#### Scenario: Landscape notch in full screen

**Given** a device with a display cutout on a short edge (e.g. a landscape left/right notch)
**And** the user is in full screen mode
**Then** the window extends into the cutout strip (`LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES`)
**And** the webview fills the space beside the notch with no black bar
**And** the top/bottom safe-area insets still keep top/bottom controls clear of any persistent system bar

#### Scenario: Cutout out of full screen

**Given** a device with a landscape display cutout
**And** the user is NOT in full screen
**Then** the body insets around the cutout (left/right `SafeArea` active) so the app bar and content avoid the notch

---

### Requirement: FS-009 - Tab Strip Presentation (Hidden / Pinned / Button)

The site tab strip's presentation SHALL be a single mutually-exclusive choice, not independent toggles, because the floating button is simply the on-demand presentation of the same strip:

- **Hidden** — no tab strip and no button.
- **Always visible** — the strip is pinned at the bottom. Its full-screen behavior is a sub-choice ("Keep Tab Strip in Full Screen", FS-007).
- **Button** — the strip is hidden, and a small floating button reveals it (together with its overflow menu) on demand. The button works both in and out of full screen, so the user reaches tabs and the menu without pinning the strip. Its corner (bottom-left or bottom-right) is chosen by long-press-dragging the button itself: while dragging it follows the finger horizontally, and on release it snaps to the nearest bottom corner. The corner is remembered **per site** (`WebViewModel.tabBarButtonOnRight`, riding the site's JSON like any per-site setting), so each site can keep the button out of the way of its own controls. A site that was never dragged falls back to the legacy app-wide `tabBarButtonOnRight` preference (kept read-only for migration; there is no settings control for it).

Selecting Hidden or Button clears the "Keep Tab Strip in Full Screen" sub-choice (it only applies to a pinned strip). The "Keep Tab Strip in Full Screen" control is shown only for the pinned mode it belongs to; the button's corner has no settings control (it is placed by dragging the button itself).

The button is suppressed while the strip is already on screen: in Always mode, or in either mode while a button-revealed strip is still showing (the revealed strip then carries its own inline dismiss control), or in a locked kiosk session (KIOSK-002).

The presentation is backed by two booleans, `showTabStrip` (pinned) and `tabBarButton` (on-demand), which the single control keeps mutually exclusive. The legacy `tabBarButtonInFullscreen` preference (full-screen-only button) is migrated to `tabBarButton` on upgrade and from imported backups.

#### Scenario: Reveal tab bar out of full screen (Button mode)

**Given** the tab strip presentation is set to Button
**And** the user is not in full screen
**When** the user taps the floating button
**Then** the tab strip is shown with its overflow menu and a dismiss control
**When** the user taps the dismiss control
**Then** the tab strip is hidden and the floating button reappears

#### Scenario: Reveal tab bar in full screen (Button mode)

**Given** the tab strip presentation is set to Button
**And** the user is in full screen
**When** the user taps the floating button
**Then** the tab strip is shown with its overflow menu while the app bar and URL bar stay hidden

#### Scenario: Button and pinned strip are mutually exclusive

**Given** the tab strip presentation is set to Always visible
**When** the user changes it to Button
**Then** the pinned strip is no longer shown
**And** the "Keep Tab Strip in Full Screen" sub-choice is cleared

#### Scenario: Button suppressed when strip already pinned

**Given** the tab strip presentation is set to Always visible
**Then** the floating button is not shown

#### Scenario: Selecting a site dismisses the revealed strip

**Given** the user revealed the tab strip via the floating button
**When** the user taps a site in the revealed strip
**Then** the app switches to that site and the revealed strip is dismissed

#### Scenario: Long-press drag moves the button to the other corner

**Given** the tab strip presentation is set to Button
**And** the floating button sits in the bottom-right corner for the current site
**When** the user long-presses the button and drags it toward the left edge
**Then** the button follows the finger horizontally while the drag is active
**When** the user releases on the left half of the screen
**Then** the button snaps to the bottom-left corner
**And** the corner is persisted on the current site's model (`WebViewModel.tabBarButtonOnRight`)

#### Scenario: The corner is remembered per site

**Given** the user dragged the button to the bottom-left corner while site A was active
**And** site B was never dragged
**When** the user switches to site B
**Then** the button sits in site B's remembered corner (or the app-wide default if never dragged)
**When** the user switches back to site A
**Then** the button sits in the bottom-left corner

#### Scenario: Drag released on the same half is a no-op

**Given** the floating button sits in the bottom-right corner for the current site
**When** the user long-press-drags it and releases on the right half of the screen
**Then** the button returns to the bottom-right corner

#### Scenario: Legacy corner preference still honored

**Given** a user upgraded from (or imported a backup written by) a build where the corner was the app-wide `tabBarButtonOnRight` preference set to bottom-left
**And** none of their sites carry a per-site corner yet
**Then** the button appears in the bottom-left corner on every site until a site is dragged

---

## Implementation Details

### Data Model

**WebViewModel** (`lib/web_view_model.dart`):
- `bool fullscreenMode = false` - Per-site setting for auto-fullscreen
- Serialized in `toJson()` / `fromJson()` with default `false`
- `bool? tabBarButtonOnRight` - Per-site corner for the floating tab-bar button (true = right); null = never dragged. Serialized only when set; rides the site's JSON through settings backup automatically.

### Runtime State

**_WebSpacePageState** (`lib/main.dart`):
- `bool _isFullscreen = false` - Current fullscreen state (not persisted; runtime only)
- `bool _tabStripInFullscreen = false` - Global pref mirror of the `tabStripInFullscreen` SharedPreferences key (registered in `kExportedAppPrefs`, round-trips through settings backup)
- `bool _tabBarButton = false` - Global pref mirror of the `tabBarButton` SharedPreferences key (registered in `kExportedAppPrefs`). When set, a floating button reveals the tab strip (and its overflow menu) on demand, in and out of full screen (FS-009). Read falls back to the legacy `tabBarButtonInFullscreen` key (and backup field) once on upgrade. `bool _tabBarButtonOnRight` is the legacy app-wide corner default, used via `_tabBarButtonOnRightEffective` only for sites whose per-site `tabBarButtonOnRight` is null (still read from prefs/backups, never written by UI anymore); `bool _tabBarOverlayVisible` is the runtime-only flag for "the button has revealed the strip" (reset on exit-fullscreen and site switch, never persisted).
- `bool _fullscreenOnShortcut = true` - Global pref mirror of the `fullscreenOnShortcut` SharedPreferences key (registered in `kExportedAppPrefs`, on by default). Both shortcut launch paths — `_openShortcutIndex` (warm) and the cold-launch restore path (`indexToRestore != null`) — route the decision through the pure `StartupRestoreEngine.shouldEnterFullscreen(viaShortcut, fullscreenOnShortcut, perSiteFullscreenMode)` policy and call `_enterFullscreen()` when it returns true. The policy returns `perSiteFullscreenMode || (viaShortcut && fullscreenOnShortcut)`, so a normal in-app switch (`viaShortcut: false`) is never pulled into fullscreen by the global option. Covered by `test/startup_restore_engine_test.dart`.

### UI Changes

- **App bar**: Hidden when `_isFullscreen` is true (`appBar: _isFullscreen ? null : _buildAppBar()`)
- **Tab strip**: `_buildTabStrip()` returns null when `_isFullscreen` unless the global `tabStripInFullscreen` pref is set (then it stays in `bottomNavigationBar` and owns the bottom safe-area inset). The `_tabStripShown` getter also renders it on demand in either mode when `_tabBarButton && _tabBarOverlayVisible`; the revealed strip carries an inline close button.
- **Tab bar button**: the `_tabBarButtonShown` getter places a floating circular button in the body `Stack` (bottom corner per `_tabBarButtonOnRightEffective`: the active site's `tabBarButtonOnRight`, or the legacy app-wide default when null). Shown when `_tabBarButton` is on, a site is loaded, the overlay is not already revealed, and the strip is not pinned for the current mode (`_showTabStrip` out of fullscreen / `_tabStripInFullscreen` in fullscreen). Tapping sets `_tabBarOverlayVisible = true` (FS-009). A long-press drag tracks the finger through the runtime-only `_tabBarButtonDragLeft` (stack-local left offset, clamped to the body `Stack` keyed by `_bodyStackKey`); on release `_endTabBarButtonDrag` snaps to the nearest bottom corner by comparing the button center against the stack midline, stores the corner on the current site's model, and persists via `_saveWebViewModels`.
- **Input bar**: `_buildInputBar()` returns null when `_isFullscreen`
- **Body insets**: The fullscreen body keeps top/bottom `SafeArea` active (`top: _isFullscreen`, `bottom: _isFullscreen || ...`). `immersiveSticky` does not reliably hide the system bars on Android 15 (edge-to-edge enforced); when a bar persists, the inset keeps the site's top/bottom controls clear of it. When the bars are truly hidden the inset is ~0 and the webview still fills the screen. Left/right insets are dropped in fullscreen (`left: !_isFullscreen`, `right: !_isFullscreen`) so the webview uses the display-cutout strip beside a landscape notch (FS-010); out of fullscreen they stay active so chrome avoids the notch.
- **Display cutout (FS-010)**: `MainActivity.onCreate` sets `LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES` (API 28+) so the window may extend into the cutout on short edges. Without it, hiding the system bars makes Android letterbox the cutout strip black.
- **Exit zone**: top edge when fullscreen (`MediaQuery.padding.top + 20px`, measured inside the body `SafeArea`) with a visible handle just below the notch/status bar. Only a centered 96px-wide `GestureDetector` catches the exit tap; the rest of the strip is transparent to pointers so web-app controls in the top corners stay tappable (github #401)
- **Fullscreen hint**: SnackBar shown on entering fullscreen to explain exit method
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

The back gesture/button is NOT consumed by fullscreen — it retains its normal behavior (web history back, open drawer, etc.) even while in full screen.

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
