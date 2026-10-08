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

### Requirement: FS-011 - App Controls Reachable Under Revealed System Bars

The system SHALL keep the tab strip and the tab-bar button usable while the user has swiped the system bars in during full screen. When full screen shows any of the app's own controls (the tab strip kept in full screen, FS-007, or the tab-bar button and the strip it reveals, FS-009), a bar the user reveals SHALL be one the layout insets around, and the system SHALL hide the bars again after a short delay. A full screen that shows none of the app's controls, including a locked kiosk session (KIOSK-002), keeps the bars transient.

**Rationale:** Android's sticky immersive mode shows swiped-in bars as transient overlays and keeps reporting them hidden to the app: no insets arrive and the system UI visibility listener does not fire. Nothing the app keeps at the bottom edge can then move out from under the navigation bar, so the strip under it takes no taps until the bar times out (github #672). The non-sticky immersive mode makes the reveal real: the insets arrive, the strip's bottom `SafeArea` lifts it above the bar, and the platform reports the change so the app can hide the bars again. See [BUG-023](../../../docs/bugs/023-system-bar-covers-fullscreen-controls.md).

#### Scenario: Navigation bar swiped in over a kept tab strip

**Given** "Keep Tab Strip in Full Screen" is enabled
**And** the user is in full screen mode
**When** the user swipes the navigation bar in
**Then** the tab strip moves above the navigation bar and its tabs and menu stay tappable
**And** the navigation bar's buttons stay tappable
**And** about 3 seconds later the bars are hidden again and the strip returns to the bottom edge

#### Scenario: Tab-bar button in full screen

**Given** the tab strip presentation is set to Button
**And** the user is in full screen mode
**When** the user swipes the system bars in
**Then** the button, and the strip if it was revealed, inset around the bars instead of sitting under them

#### Scenario: Full screen without app controls

**Given** "Keep Tab Strip in Full Screen" is disabled and the tab strip presentation is not Button
**And** the user is in full screen mode
**When** the user swipes the system bars in
**Then** the bars overlay the content transiently and hide on their own, as before

---

### Requirement: FS-009 - Tab Strip Presentation (Hidden / Pinned / Button)

The site tab strip's presentation SHALL be a single mutually-exclusive choice, not independent toggles, because the floating button is simply the on-demand presentation of the same strip:

- **Hidden** — no tab strip and no button.
- **Always visible** — the strip is pinned at the bottom. Its full-screen behavior is a sub-choice ("Keep Tab Strip in Full Screen", FS-007).
- **Button** — the strip is hidden, and a small floating button reveals it (together with its overflow menu) on demand. The button works both in and out of full screen, so the user reaches tabs and the menu without pinning the strip. Its corner (any of the four) is chosen by dragging the button itself — either immediately (press-and-move) or after a long-press hold: while dragging it follows the finger freely, and on release it glides (animated, not teleported) to the nearest corner. The corner is remembered **per site** (`WebViewModel.tabBarButtonCorner`, riding the site's JSON like any per-site setting), so each site can keep the button out of the way of its own controls. A site that was never dragged falls back to the legacy app-wide `tabBarButtonOnRight` preference mapped to the matching bottom corner (kept read-only for migration; there is no settings control for the corner).

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

#### Scenario: Dragging the button moves it to another corner

**Given** the tab strip presentation is set to Button
**And** the floating button sits in the bottom-right corner for the current site
**When** the user drags the button (immediately, or after a long-press hold) toward the top-left of the screen
**Then** the button follows the finger freely while the drag is active
**When** the user releases in the top-left quadrant
**Then** the button glides with an animation to the top-left corner
**And** the corner is persisted on the current site's model (`WebViewModel.tabBarButtonCorner`)

#### Scenario: The corner is remembered per site

**Given** the user dragged the button to the top-left corner while site A was active
**And** site B was never dragged
**When** the user switches to site B
**Then** the button sits in site B's remembered corner (or the app-wide default if never dragged)
**When** the user switches back to site A
**Then** the button sits in the top-left corner

#### Scenario: Drag released in the same quadrant returns to its corner

**Given** the floating button sits in the bottom-right corner for the current site
**When** the user drags it slightly and releases still in the bottom-right quadrant
**Then** the button glides back to the bottom-right corner

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
- `TabBarCorner? tabBarButtonCorner` - Per-site corner for the floating tab-bar button (`lib/services/tab_bar_corner.dart`: topLeft / topRight / bottomLeft / bottomRight, serialized by enum name); null = never dragged. Serialized only when set; rides the site's JSON through settings backup automatically. `fromJson` maps the short-lived per-site `tabBarButtonOnRight` bool predecessor to the matching bottom corner.

### Runtime State

**_WebSpacePageState** (`lib/main.dart`):
- `FullscreenController.active` - Current fullscreen state (not persisted; runtime only)
- `AppPref.tabStripInFullscreen` (`lib/settings/app_prefs.dart`, default off) - Global pref under the `tabStripInFullscreen` SharedPreferences key; round-trips through settings backup
- `AppPref.tabBarButton` (default off) - Global pref under the `tabBarButton` SharedPreferences key. When set, a floating button reveals the tab strip (and its overflow menu) on demand, in and out of full screen (FS-009). Read falls back to the legacy `tabBarButtonInFullscreen` key (and backup field) once on upgrade. `AppPref.tabBarButtonOnRight` is the legacy app-wide corner default, mapped to a bottom corner via `_tabBarButtonCornerEffective` only for sites whose per-site `tabBarButtonCorner` is null (still read from prefs/backups, never written by UI anymore); `bool FullscreenController.tabBarOverlayVisible` is the runtime-only flag for "the button has revealed the strip" (reset on exit-fullscreen and site switch, never persisted).
- `AppPref.fullscreenOnShortcut` (on by default) - Global pref under the `fullscreenOnShortcut` SharedPreferences key. Both shortcut launch paths — `_openShortcutIndex` (warm) and the cold-launch restore path (`indexToRestore != null`) — route the decision through the pure `StartupRestoreEngine.shouldEnterFullscreen(viaShortcut, fullscreenOnShortcut, perSiteFullscreenMode)` policy and call `FullscreenController.enter()` when it returns true. The policy returns `perSiteFullscreenMode || (viaShortcut && fullscreenOnShortcut)`, so a normal in-app switch (`viaShortcut: false`) is never pulled into fullscreen by the global option. Covered by `test/startup_restore_engine_test.dart`.

### UI Changes

- **App bar**: Hidden when `FullscreenController.active` is true (`appBar: _fullscreen.active ? null : _buildAppBar()`)
- **Tab strip**: `_buildTabStrip()` returns null when `_fullscreen.active` unless the global `tabStripInFullscreen` pref is set (then it stays in `bottomNavigationBar` and owns the bottom safe-area inset). The `_tabStripShown` getter also renders it on demand in either mode when `_tabBarButton && FullscreenController.tabBarOverlayVisible`; the revealed strip carries an inline close button.
- **Tab bar button**: the `_tabBarButtonShown` getter places `TabBarCornerOverlay` (`lib/widgets/tab_bar_corner_button.dart`, a hit-test-transparent `Padding > AnimatedAlign` around `TabBarCornerButton`) in the body `Stack` inside a `Positioned.fill`, resting at the corner from `_tabBarButtonCornerEffective` (the active site's `tabBarButtonCorner`, or the legacy app-wide default mapped to a bottom corner when null). Shown when `_tabBarButton` is on, a site is loaded, the overlay is not already revealed, and the strip is not pinned for the current mode (`_showTabStrip` out of fullscreen / `_tabStripInFullscreen` in fullscreen). Tapping sets `FullscreenController.tabBarOverlayVisible = true` (FS-009). The widget recognizes both an immediate pan and a long-press drag (same callbacks; one recognizer wins per gesture); the drag tracks the finger through the overlay's runtime-only drag alignment (fractional position from `tabBarCornerDragFraction`, measured against the area the overlay fills; `AnimatedAlign` runs with `Duration.zero` while dragging so the button follows instantly). On release the overlay picks `tabBarCornerNearest` (quadrant of the drop point) and reports it through `onCornerChosen`; the page stores it on the current site's model and persists it through `_commitSites`, and the `AnimatedAlign` glides the button to its corner (`Motion.settle`, 250ms ease-out). Corner math is pure and covered by `test/tab_bar_corner_test.dart`; gesture recognition by `test/tab_bar_corner_button_test.dart`.
- **Input bar**: `_buildInputBar()` returns null when `_fullscreen.active`
- **Body insets**: The fullscreen body keeps top/bottom `SafeArea` active (`top: _fullscreen.active`, `bottom: _fullscreen.active || ...`). `immersiveSticky` does not reliably hide the system bars on Android 15 (edge-to-edge enforced); when a bar persists, the inset keeps the site's top/bottom controls clear of it. When the bars are truly hidden the inset is ~0 and the webview still fills the screen. Left/right insets are dropped in fullscreen (`left: !_fullscreen.active`, `right: !_fullscreen.active`) so the webview uses the display-cutout strip beside a landscape notch (FS-010); out of fullscreen they stay active so chrome avoids the notch.
- **Display cutout (FS-010)**: `MainActivity.onCreate` sets `LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES` (API 28+) so the window may extend into the cutout on short edges. Without it, hiding the system bars makes Android letterbox the cutout strip black.
- **Exit zone**: top edge when fullscreen (`MediaQuery.padding.top + 20px`, measured inside the body `SafeArea`) with a visible handle just below the notch/status bar. Only a centered 96px-wide `GestureDetector` catches the exit tap; the rest of the strip is transparent to pointers so web-app controls in the top corners stay tappable (github #401)
- **Fullscreen hint**: SnackBar shown on entering fullscreen to explain exit method
- **Menu items**: "Full Screen" added to both app bar and tab strip popup menus

### System UI

- Enter: `FullscreenController.apply()`, the one place full screen sets its mode. It asks for `FullscreenController._systemUiMode`, from the pure `fullscreenSystemUiMode` (`lib/services/fullscreen_system_ui.dart`): `immersive` when `tabStripInFullscreen` or `tabBarButton` is on and the session is not kiosk-locked, `immersiveSticky` otherwise (FS-011). On iOS every mode but `edgeToEdge` hides the status bar and home indicator alike.
- Revealed bars (FS-011): `_onSystemUiChange`, registered with `SystemChrome.setSystemUIChangeCallback` on Android (the only embedder that implements the listener), runs only under `immersive`; it nudges the surface (`system-bars`, the body resizes) and, when the overlays are visible, re-applies the mode after `kRevealedSystemBarsHideDelay` (3s). Sticky bars never reach it: Android keeps reporting them hidden.
- Exit: `SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)`, cancelling a pending re-hide
- Re-applied on app resume via `AppLifecycleController._resumeAfterPause()`, by `FullscreenController.enter()` when already in full screen (a shortcut launch can change the kiosk lock, an import the tab strip prefs), and when either tab strip pref changes in full screen
- Gate: `test/js/fullscreen_system_ui_funnel.test.js` fails a `setEnabledSystemUIMode` call that names an immersive mode itself instead of going through `FullscreenController._systemUiMode`

### Site Switching

In `_setCurrentIndex()`:
- If target site has `fullscreenMode = true`, calls `FullscreenController.enter()`
- Otherwise, calls `FullscreenController.exit()`
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
| `lib/main.dart` | Added `_fullscreen.active` state, enter/exit/toggle methods, menu items, scaffold/body changes, back handler, lifecycle handling |

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
15. Enable "Keep Tab Strip in Full Screen", enter full screen, swipe the navigation bar in
16. Verify: the tab strip sits above the navigation bar and both take taps; the bars hide again after about 3 seconds
