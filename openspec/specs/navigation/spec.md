# Navigation Specification

## Purpose

Controls all in-app navigation: system back gesture, menu back/home buttons, drawer swipe gesture, pull-to-refresh on phones, keyboard shortcuts on desktop and on Android with a keyboard, a remote's D-pad on a TV, and the header of an Android desktop window. Handles platform differences between iOS and Android, and guards async state against race conditions.

**Formal model:** the back/forward navigation actions are composed into the cross-spec kernel [formal/kernel.tla](../../../formal/kernel.tla) (with `webview-pause-lifecycle` and `lazy-webview-loading`); the `Back`/`Forward` transitions must route through the repaint chokepoint or the kernel's `RepaintLiveness` fails (the `bypass` demonstrator).

## Status

- **Date**: 2026-04-10
- **Status**: Active

---

## Problem Statement

WebSpace embeds webviews in a Scaffold with a drawer. Navigation gestures compete:

- The **system back gesture** (Android hardware back, iOS left-edge swipe) must navigate back in webview history, and do nothing when there is no history (it never opens the drawer or exits the app).
- The **drawer edge swipe** is disabled whenever a webview is active so it cannot be confused with the back gesture; the drawer is opened from the AppBar menu button.
- The **Home button** must return to the site's initial URL with a clean history so subsequent back gestures correctly detect "no history."

### Platform Quirks

| Platform | Quirk | Impact |
|----------|-------|--------|
| iOS | `canGoBack()` returns `false` for `history.pushState()` entries (SPAs) | Back gesture can't trust it; mitigated by PopScope URL-comparison fallback (NAV-002) |
| iOS | `onLoadStop` does not fire for BFCache page restorations during back/forward gestures | URL bar doesn't update without `onUpdateVisitedHistory` (fixed in PR #174) |
| iOS | `target="_blank"` links may only trigger `onCreateWindow`, not `shouldOverrideUrlLoading` | Links load in current webview instead of nested browser without explicit delegation (fixed in PR #175) |
| iOS/macOS | `allowsBackForwardNavigationGestures` is enabled for the **root site webview** only | The root webview lives at the `MaterialApp` root route, which has no Flutter route-pop edge-swipe — so without the native gesture the main view has no reliable back-swipe (PopScope only fires for pushable routes). Nested `InAppWebViewScreen`s leave it off so their route-pop-at-history-start (NAV-008) isn't hijacked. |
| Android | `hasGesture` on `NavigationAction` is a reliable boolean | Used directly for gesture detection |
| iOS/macOS | WKWebView's native swipe is silent at the start of history, and consumes the gesture | The app never learns the swipe happened, so NAV-009 cannot act on it and the setting is not offered there |
| iOS/macOS | No `hasGesture`; must infer from `navigationType` (`LINK_ACTIVATED`, `FORM_SUBMITTED`) | Less reliable than Android's boolean flag |

---

## Requirements

### Requirement: NAV-001 - System Back Gesture

The system back gesture (Android back button, iOS/macOS left-edge swipe) SHALL navigate back in webview history when possible. On the root site webview, iOS/macOS use WKWebView's native back/forward swipe (`allowsBackForwardNavigationGestures`); Android, and all nested routes, use the PopScope handler. It SHALL NOT open the drawer and SHALL NOT exit the app; when there is no back history it is a no-op. What happens at that history start is the one thing the user can change, via the opt-in setting in NAV-009 — off by default and absent on Apple, which is this requirement.

**Rationale:** Users navigating content-heavy sites (especially SPA news sites) expect the back gesture to mean "go back in the page," not "open the menu" or "leave the app." Folding drawer-opening and app-exit into the back gesture made the gesture ambiguous and, combined with the iOS `canGoBack()` heuristic (NAV-002), occasionally misfired mid-navigation. The drawer is reached via the AppBar menu button; the app is left via the OS home/recents gesture.

#### Scenario: Webview has back history

**Given** a webview is visible and has navigation history
**When** the user triggers the system back gesture
**Then** the webview navigates back in history

#### Scenario: Root site webview uses the native swipe on Apple

**Given** the root site webview is visible on iOS or macOS
**When** the user performs a left-edge back swipe
**Then** WKWebView navigates back in its own history, including `history.pushState` entries
**And** at the start of history the swipe is a no-op: the app does not exit and the drawer does not open
**And** NAV-009 does not apply: the setting is not offered on Apple

#### Scenario: Webview has no back history

**Given** a webview is visible with no navigation history
**When** the user triggers the system back gesture
**Then** nothing happens (no drawer, no exit)
**And** the setting in NAV-009 is off

#### Scenario: Drawer is already open

**Given** the drawer is open
**When** the user triggers the system back gesture
**Then** the drawer closes (the app does NOT exit)

#### Scenario: No webview visible — Android

**Given** the webspace list screen is visible (no webview selected) on Android
**When** the user triggers the system back gesture
**Then** nothing happens (the gesture is swallowed; no drawer, no exit)

#### Scenario: No webview visible — non-Android

**Given** the webspace list screen is visible (no webview selected) on iOS/macOS
**When** the user triggers the system back gesture
**Then** the system pop behavior proceeds normally

---

### Requirement: NAV-002 - PopScope canGoBack Distrust (iOS/macOS)

On iOS and macOS, the PopScope back handler SHALL NOT trust `canGoBack()` for determining back navigation capability. It SHALL use URL comparison as the authoritative check.

On Android, the PopScope back handler SHALL trust `canGoBack()` directly. Chromium reports `pushState` entries correctly, so URL comparison adds no information and its 150ms window can false-positive when a slow `goBack()` (e.g. BFCache miss) leaves the URL unchanged at the time of the post-delay sample.

**Rationale:** `canGoBack()` can return `false` for `history.pushState()` entries on iOS WKWebView. Trusting it would prevent back navigation in SPAs. Android System WebView (Chromium) does not have this bug.

#### Scenario: SPA with pushState history (iOS)

**Given** a single-page app has navigated via `history.pushState()` on iOS
**And** `canGoBack()` returns `false`
**When** the user triggers the system back gesture
**Then** `goBack()` is called regardless
**And** the URL is compared before/after with a 150ms delay
**And** if the URL changed, back navigation succeeded
**And** if the URL did NOT change, the gesture is a no-op

#### Scenario: Slow back navigation (Android)

**Given** a webview is visible on Android with back history
**And** `canGoBack()` returns `true`
**When** the user triggers the system back gesture
**Then** `goBack()` is called
**And** the navigation proceeds even if the new page takes longer than 150ms to update its URL

#### Scenario: No back history (Android)

**Given** a webview is visible on Android
**And** `canGoBack()` returns `false`
**When** the user triggers the system back gesture
**Then** nothing happens (no drawer, no exit)

---

### Requirement: NAV-003 - Drawer Edge Swipe

The drawer edge swipe SHALL always be disabled when a webview is active, on every platform, so the back/edge gesture never opens the drawer. The drawer is opened via the AppBar menu button.

#### Scenario: Webview visible

**Given** a webview is visible
**When** the user swipes from the left edge
**Then** the drawer does NOT open (gesture is consumed by the disabled drag zone)

#### Scenario: No webview visible

**Given** the webspace list is shown
**When** the user swipes from the left edge
**Then** the drawer opens (on all platforms)

---

### Requirement: NAV-004 - Home Button Clears History

The Home button SHALL navigate to the site's initial URL AND clear all navigation history, so `canGoBack()` returns `false` immediately afterward.

**Rationale:** Simply loading the initial URL via `loadUrl()` preserves back history, causing `canGoBack()` to return `true` even though the user is "home." Disposing and recreating the webview guarantees a clean, zero-history state.

#### Scenario: Press Home from a deep page

**Given** a user has navigated several pages deep
**When** the user presses the Home button
**Then** the webview is disposed and recreated fresh at the initial URL
**And** the back gesture afterward finds no history (it is a no-op)

---

### Requirement: NAV-005 - Menu Back Button

The menu back button (in both portrait and landscape layouts) SHALL navigate back in webview history.

#### Scenario: Webview has back history

**Given** a webview is visible and `canGoBack()` returns `true`
**When** the user presses the back button in the menu
**Then** the webview navigates back
**And** the menu closes

#### Scenario: Webview has no back history

**Given** a webview is visible and `canGoBack()` returns `false`
**When** the user presses the back button in the menu
**Then** nothing happens (no navigation)
**And** the menu closes

**Note:** Unlike the PopScope handler (NAV-002), the menu back button trusts `canGoBack()`. This is acceptable because the PopScope fallback remains available for SPA edge cases.

---

### Requirement: NAV-006 - Pull-to-Refresh

On Android and iOS, all webviews (main and nested) SHALL support pull-to-refresh to reload the current page. A desktop has no pull gesture; its keys reload the page instead (NAV-014).

#### Scenario: Pull to refresh

**Given** a webview is visible
**When** the user pulls down on the page
**Then** the page reloads
**And** the pull-to-refresh indicator animates
**And** the indicator stops when `onLoadStop` fires

#### Scenario: Pinch to zoom does not refresh

**Given** a webview is scrolled to the top
**When** the user pinches with two fingers
**Then** the page does not reload
**And** the refresh control is disabled for the rest of that gesture
**And** a refresh that the native control fired before the gate reached it is
swallowed, stopping the indicator without reloading

**Note:** Neither `SwipeRefreshLayout` (Android) nor `UIRefreshControl` (iOS)
consults the pointer count, so a pinch reads as a downward drag. `PullToRefreshGate`
([lib/services/pull_to_refresh_gate.dart](../../../lib/services/pull_to_refresh_gate.dart))
watches Flutter's pointer stream through a `Listener` wrapped around the webview
and both disables the control and guards `onRefresh`.

---

### Requirement: NAV-007 - URL Bar Sync

The URL bar SHALL stay in sync with the current webview URL across all navigation types, including BFCache restorations. Outside an active edit, its text SHALL be the site's current URL; a submit SHALL NOT leave the typed text behind. Lineage: [docs/bugs/015-url-bar-shows-another-url.md](../../../docs/bugs/015-url-bar-shows-another-url.md).

#### Scenario: Standard navigation

**Given** a webview navigates to a new page
**When** `onLoadStop` fires
**Then** the URL bar updates to the new URL

#### Scenario: iOS back gesture with BFCache

**Given** an iOS webview restores a page from BFCache via back/forward gesture
**When** `onLoadStop` does NOT fire
**Then** `onUpdateVisitedHistory` fires instead
**And** the URL bar updates to the restored URL

#### Scenario: Timing of the update after back

**Given** a webview has a previous history entry
**When** the user goes back
**Then** the URL bar changes when the webview reports the new history entry, not when back is tapped
**And** on iOS, macOS and Linux that is at once, because the engine reports the pending URL as the navigation starts
**And** on Android it is when the entry commits, together with the page itself

#### Scenario: A URL bar submit that does not navigate this webview

**Given** the URL bar shows the site's current URL
**When** the user submits a cross-domain URL, which opens in a nested webview
**And** closes the nested webview with its back button
**Then** the URL bar shows the site's current URL again, not the submitted text
**And** the padlock and the text describe the same URL

Test: [test/url_bar_sync_test.dart](../../../test/url_bar_sync_test.dart)

---

### Requirement: NAV-008 - Nested WebView Back Gesture

The **system back gesture** (Android back button, iOS edge swipe) on a nested `InAppWebViewScreen` SHALL navigate back in the nested webview's history when possible, and only pop the nested route when there is no back history. The decision policy SHALL mirror NAV-002: on Android, trust `canGoBack()` directly; on iOS/macOS, attempt `goBack()` unconditionally and decide via URL comparison with a 150ms settle.

The **AppBar back button** on a nested `InAppWebViewScreen` SHALL always close the nested route immediately, regardless of the webview's history. It bypasses PopScope by calling `Navigator.pop` directly.

**Rationale:** Cross-domain links open a nested webview that maintains its own history. The two affordances serve different intents: the system back gesture (iOS edge swipe) is the user saying "go back in what I'm reading" — walking the nested history first matches Safari and prevents discarding pages on the first swipe. The AppBar back button is the user explicitly saying "leave this nested view and return to my parent site" — making it depend on history would surprise the user when the back arrow does nothing visible.

#### Scenario: Nested webview has back history (Android)

**Given** a nested `InAppWebViewScreen` is open on Android
**And** `canGoBack()` returns `true`
**When** the user presses the system back button
**Then** the nested webview navigates back in its own history
**And** the nested route stays open

#### Scenario: Nested webview has no back history (Android)

**Given** a nested `InAppWebViewScreen` is open on Android
**And** `canGoBack()` returns `false`
**When** the user presses the system back button
**Then** the nested route pops back to the parent webview

#### Scenario: Nested webview has back history (iOS/macOS)

**Given** a nested `InAppWebViewScreen` is open on iOS or macOS
**And** the user has navigated within it (e.g. via in-page links)
**When** the user triggers the system back gesture (iOS edge swipe)
**Then** `goBack()` is called regardless of `canGoBack()`
**And** the URL is compared before/after with a 150ms delay
**And** if the URL changed, the nested route stays open
**And** if the URL did NOT change, the nested route pops

#### Scenario: SPA with pushState in nested webview (iOS/macOS)

**Given** the nested webview on iOS has navigated via `history.pushState()`
**And** `canGoBack()` returns `false`
**When** the user triggers the system back gesture
**Then** `goBack()` is called regardless
**And** URL comparison decides whether the back succeeded
**And** if the URL changed, the nested route stays open
**And** if the URL did NOT change, the nested route pops

#### Scenario: AppBar back button always closes nested

**Given** a nested `InAppWebViewScreen` is open
**And** the nested webview has back history
**When** the user taps the AppBar back button (top-left arrow)
**Then** the nested route pops immediately
**And** `goBack()` is NOT called on the nested webview

#### Scenario: Rapid back gestures (race guard)

**Given** the user triggers the back gesture twice in quick succession
**When** the second invocation arrives while the first is still awaiting `goBack()` / URL diff
**Then** the second invocation drops (guarded by `_backGuard`)
**And** at most one `goBack()` per gesture is dispatched

---

### Requirement: NAV-009 - Back At Start Of History (opt-in)

The app SHALL expose exactly one global setting for what the system back gesture does once the webview has no page left to go back to. It SHALL default to off, which is NAV-001's no-op. It SHALL be offered on Android, Linux and Windows only: on iOS and macOS the setting SHALL be absent from App Settings and the behaviour SHALL stay pinned to NAV-001, whatever the persisted `backOpensMenu` value says.

When the setting is on, the back gesture at the start of a site's history SHALL open the drawer, and a further back gesture on a drawer *that gesture opened* SHALL close it and leave the app. A drawer the user opened any other way (AppBar menu button, webspace tap) SHALL only close, never leave the app — and leaving the app SHALL happen on Android only, where it SHALL send the app's task to the back, as Android 12 itself does for a task's root on Back. It SHALL NOT finish the activity: the engine goes with it, so every loaded site, the notification sites a wake would reload, and the page in progress are gone, and the next open is a cold start. Gate: `test/js/back_keeps_app_running.test.js`.

The setting SHALL be persisted as the `backOpensMenu` app pref and ride settings export/import; a backup carrying it on SHALL restore on Apple without turning the behaviour on. It SHALL have no effect while the kiosk shell is locked (KIOSK-002), which owns the drawer's absence. Its hint SHALL describe the app-exit escalation only on the platform where it happens.

**Rationale:** Issue #369 and issue #431 ask for opposite gestures from the same swipe: one user's news-site navigation is broken by the drawer appearing mid-article, the other lost the "menu, then exit" sequence they navigated by. Neither is wrong, and no heuristic separates them, so the choice belongs to the user. Off stays the default because it is the gesture that cannot misfire: it never takes the user somewhere they did not ask to go.

The escalation to leaving the app is bound to the drawer the gesture itself opened, because otherwise back-to-dismiss on a deliberately opened menu would quit the app — the exact ambiguity NAV-001 removed.

Apple is excluded because the app cannot see the gesture: the root site webview owns the left edge natively (NAV-001) and the root route has no Flutter pop for `PopScope` to intercept, so a start-of-history swipe is resolved silently inside WKWebView. #565 claimed a strip of that edge with an app-side recognizer, which had to infer history from `goBack()` plus a URL diff and misread it often enough to open the drawer mid-history; it was reverted. Presenting a setting that does nothing is worse than not offering it. Lineage: [docs/bugs/011-back-at-history-start-apple.md](../../../docs/bugs/011-back-at-history-start-apple.md).

With Alternative design enabled, the menu action SHALL return directly to the previous library view instead of opening a drawer. The history and tab-return rules above SHALL still run first.

#### Scenario: Setting off — start of history stays a no-op

**Given** the setting is off
**And** a webview is visible with no back history
**When** the user triggers the system back gesture
**Then** nothing happens (no drawer, no exit)

#### Scenario: Setting on — start of history opens the drawer

**Given** the setting is on
**And** a webview is visible with no back history
**When** the user triggers the system back gesture
**Then** the drawer opens

#### Scenario: Setting on with Alternative design returns to the library

**Given** Alternative design and the back-opens-menu setting are on
**And** a site is visible with no back history or tab return to spend
**When** the user triggers the system back gesture
**Then** the previous library view is shown with its selected group retained
**And** no drawer opens

#### Scenario: Setting on — second gesture leaves the app

**Given** the setting is on
**And** the drawer was opened by the back gesture on Android
**When** the user triggers the system back gesture again
**Then** the drawer closes
**And** the app is left via `SystemNavigator.pop()`, which sends its task to the back
**And** reopening it shows the same sites, still loaded, with no restart

#### Scenario: Setting on — back never quits from a deliberately opened menu

**Given** the setting is on
**And** the user opened the drawer with the AppBar menu button
**When** the user triggers the system back gesture
**Then** the drawer closes
**And** the app is NOT left

#### Scenario: Setting on — history still wins

**Given** the setting is on
**And** a webview is visible with back history
**When** the user triggers the system back gesture
**Then** the webview navigates back in history
**And** the drawer does not open

#### Scenario: Setting on — no site shown (Android)

**Given** the setting is on
**And** the webspace list screen is visible on Android
**When** the user triggers the system back gesture
**Then** the app is left (the drawer would only repeat the list already on screen)

#### Scenario: The setting does not exist on Apple

**Given** the app is running on iOS or macOS
**When** the user opens App Settings
**Then** no back-gesture setting is shown
**And** the back gesture behaves as in NAV-001, even if a restored backup has `backOpensMenu` set

#### Scenario: Hint copy names app-exit only where it applies

**Given** the app settings screen is open on Linux or Windows
**When** the user opens the setting's hint
**Then** the hint does not mention leaving the app

#### Scenario: Locked kiosk shell ignores the setting

**Given** the setting is on
**And** the kiosk shell is locked (KIOSK-002, no drawer)
**When** the user triggers the system back gesture at the start of history
**Then** nothing happens (no drawer, no exit)

---

### Requirement: NAV-010 - Leaving A Site Is Committed Before Its Teardown

Returning to the webspace list SHALL take effect on the user's tap, independently of the teardown of the site being left. `activate(null)` SHALL assign `_sites.current` and exit fullscreen **before** it captures nav state, stops a real camera capture, pauses media, or pauses the webview — nothing in that sequence decides where the user ends up.

That teardown is best-effort and SHALL be funnelled through `SiteTeardownEngine.quiesceOutgoing` (also used by the site-switch path and the defensive sweep of background sites), which:

- keeps the caller's step order (camera stop and media pause ahead of the pause — CAM-012 / BGAUDIO-009);
- takes each step's failure from its result: a step owns its failure and reports it rather than throwing it, and a step that answers failure is recorded and the ones behind it run anyway. Nothing to capture is not a failure. A step that throws is a bug the teardown does not catch;
- gives the whole sequence one budget (`SiteTeardownEngine.defaultBudget`) and returns when it expires, abandoning — not cancelling — the stalled step;
- re-checks the `SiteRuntime.activationVersion` guard before each remaining step, including after the budget expired, so an abandoned sequence whose native reply lands late cannot pause a webview a newer activation has since resumed (PAUSE-005).

Storage on this path SHALL fail closed rather than throw: `SecureWebViewStateStorage` swallows an initialization failure, degrades save/load to no-ops, and clears its memoized in-flight init so a later call retries instead of replaying the failure for the rest of the run. A save it could not make answers false, which the capture step reports as its failure.

**Rationale:** each teardown step is a native round-trip, and the commit used to sit behind all four. Any of them throwing (a state-storage init that failed once and then re-threw its memoized failure forever), being superseded (a version bump from a concurrent delete, archive close, or activation), or never answering at all left `_sites.current` on the site the user asked to leave — "back to webspaces" did nothing, silently, with nothing to retry against. The never-answering case is reachable: on iOS the per-instance pause freezes the page's JS thread (the plugin's withheld-`alert()` hack), so a site left paused by a race-cancelled switch never answers the `evaluateJavascript` that the next teardown opens with.

#### Scenario: A teardown step that never answers still returns the user home

**Given** site A is active and its JS thread is frozen by an earlier pause
**When** the user taps "Back to Webspaces"
**And** the media-pause step never answers
**Then** `_sites.current` is already null and fullscreen is already exited
**And** the sequence is abandoned once the budget expires
**And** the webspace list is shown

#### Scenario: A failing state capture does not cost the pause

**Given** site A is active
**And** the state storage fails to initialize
**When** the user returns to the webspace list
**Then** the capture step answers failure and is recorded as failed
**And** the camera stop, media pause and webview pause still run
**And** the return to the list is unaffected

#### Scenario: A newer activation still wins the teardown

**Given** a return to the webspace list is mid-teardown of site A
**When** the user taps site A again before the teardown finishes
**Then** the remaining teardown steps are skipped
**And** A is not left paused by the abandoned sequence

#### Scenario: A concurrent delete no longer strands the return

**Given** a return to the webspace list is mid-teardown
**When** another path bumps `SiteRuntime.activationVersion` (site delete, archive close)
**Then** the teardown stops early
**And** the user is still on the webspace list, because the commit already happened

---

### Requirement: NAV-012 - A Site Opened During Startup Stays Open

The startup restore SHALL NOT close a site the user opened while it was still running. `StartupController.restore` records `SiteRuntime.activationVersion` before its first `await` and, at its closing activation, asks `StartupRestoreEngine.shouldActivateAfterRestore`: a plain launch's `null` target is skipped when the version moved, and a shortcut target is applied either way, because it is the site the app was launched to open.

**Rationale:** the home grid takes taps long before the restore finishes. The proxy router's attribution pass alone held the restore for six seconds on a 20-site device, and a tap in that window activated the site, only for the restore's `activate(null)` to quiesce it and return to the webspace list. Nothing reported it: the site was paused and deselected exactly as "back to webspaces" would, and with `_sites.current` cleared the next memory-pressure event no longer protected it.

#### Scenario: Opening a site during a slow startup

**Given** the app was launched normally, not from a shortcut
**And** the restore is still awaiting startup work
**When** the user taps a site on the home grid
**Then** the site opens
**And** it is still open after the restore completes

#### Scenario: A plain launch with no tap still lands home

**Given** the app was launched normally
**When** the restore completes without the user opening anything
**Then** the webspace list is shown

#### Scenario: A shortcut launch still opens its site

**Given** the app was launched from a site's home shortcut
**When** the restore completes
**Then** the shortcut's site is active

Covered by `test/startup_restore_engine_test.dart` (the decision) and `test/js/startup_restore_keeps_user_activation.test.js` (the restore asks it, with the version captured before the first await).

---

### Requirement: NAV-013 - An Activation Shows The Site It Made Current

`SiteActivationController.activate` SHALL rebuild the page once it has assigned `_sites.current` (and, for a site, moved it to the end of `_sites.loaded`), on both the site path and the webspace-list path. A caller's own rebuild does not stand in for it: one made before the activation's awaits end draws the previous state, and a caller that never rebuilds leaves the site unbuilt.

**Rationale:** callers rebuilt on their own schedule. A notification tap rebuilt synchronously, before the activation's state reads finished; the launch link's open-in-main path did not rebuild at all. On a device those reads outlast a frame, so the app stayed on the webspace list with the site marked current and no webview. It went unnoticed while the notification-site auto-load, which rebuilds, usually reached the same site first; a faster startup let the link win.

#### Scenario: A tap whose activation outlasts its frame

**Given** the app is on the webspace list
**And** reading a site's saved navigation state takes longer than a frame
**When** a notification for that site is tapped
**Then** the site is shown once its activation completes

#### Scenario: A launch link opens its site without another rebuild

**Given** the app was launched from a link that one site claims
**When** the link's activation of that site completes
**Then** the site is shown, whether or not the notification auto-load also loads it

Covered by `test/notification_launch_app_test.dart` (the tap); the launch link reaches the page through the same `activate`.

---

### Requirement: NAV-011 - Site Info From The URL Bar

The URL bar SHALL end with an info button that opens a sheet saying which of
the user's sites the page on screen runs as and which container holds its data.
The button SHALL sit at the trailing end of the bar, so a right-to-left locale
puts it on the left, and SHALL give way to the Go button while the URL is being
edited. The URL bar SHALL be the only way to the sheet: no overflow menu SHALL
carry it, the nested screen's included.

The sheet SHALL show:

- **Site**: the site whose settings and identity the webview carries. For a
  nested screen that is the site whose link opened it, or the site outbound
  routing picked (LIR-015). For a hosted tab it is the host (LIR-018).
- **Tab of**, for a hosted tab only: the site whose tab list holds it.
- **Opened from**, for a nested screen that runs as a site other than the one
  on screen when it opened: that site.
- **Page**: the URL on screen.
- **Container**: the named site's own container, "{site}'s own container" with
  its `ws-<id>` name; a private store discarded on close (incognito off
  Android); or the store every site shares (the legacy engine). The row SHALL
  name the site rather than say "this site": with a page on one site's address
  running as another, "this site" does not say which.

The container SHALL be computed by `containerIdFor`, the same function
`WebViewFactory.createWebView` binds by, from the same inputs the webview's
`WebViewConfig` was given, so the sheet cannot name a container the webview
does not use.

#### Scenario: A routed page names the site it runs as

- **GIVEN** a DuckDuckGo site with its Tabs switch off routes `github.com` links to a GitHub site
- **WHEN** the user taps a GitHub link and then the info button of the nested screen
- **THEN** the sheet's Site row reads GitHub and its Opened from row reads DuckDuckGo
- **AND** its Container row reads "GitHub's own container"

#### Scenario: An unrouted page names its source

- **GIVEN** a DuckDuckGo site in the in-app mode that does not route
- **WHEN** a tapped link to a site the user does not have opens a nested screen and the user opens its site info
- **THEN** the Site row reads DuckDuckGo, there is no Opened from row, and the Container row reads "DuckDuckGo's own container"

#### Scenario: A hosted tab names both sites

- **GIVEN** a GitHub tab in DuckDuckGo's tab list, running as GitHub
- **WHEN** the user opens its site info
- **THEN** the Site row reads GitHub, the Tab of row reads DuckDuckGo
- **AND** the Container row reads "GitHub's own container"

#### Scenario: Private and shared stores say so

- **GIVEN** an incognito site on iOS, macOS or Linux
- **THEN** its sheet's Container row reads "Private, discarded when closed" with no container name
- **AND** on the legacy engine the row reads "Shared, cookies swapped per site"

#### Scenario: The button follows the text direction

- **GIVEN** the app in a right-to-left locale
- **THEN** the info button sits left of the address field
- **AND** while the address is being edited the Go button takes its place

---

### Requirement: NAV-014 - Desktop Keyboard Shortcuts

On macOS, Linux and Windows, and on Android (NAV-019), the page SHALL answer a desktop
browser's keys for the site on screen, each with the action the app already offers for
it, with Command on macOS where the others take Control:

| Keys | Action |
|---|---|
| Ctrl/Cmd-T | the site menu's New tab, where the site has tabs (TAB-005) |
| Ctrl/Cmd-W | close the tab on screen, as the Tabs sheet does, where the site has tabs |
| Ctrl/Cmd-L | put the cursor in the URL bar with the address selected, where the URL bar is on |
| Ctrl/Cmd-R, F5 | the site menu's Refresh |
| Ctrl/Cmd-F | the site menu's Find in page, out of full screen; Escape in its field closes it |
| Alt-Left; Cmd-[ or Cmd-Left on macOS | the site menu's Back |
| Alt-Right; Cmd-] or Cmd-Right on macOS | one step forward, where the page has one |
| Ctrl-Tab, Ctrl-Shift-Tab; Ctrl-PageDown, Ctrl-PageUp off macOS | the next or previous site along the tab strip, round at either end |
| Ctrl/Cmd-1 to 8, Ctrl/Cmd-9 | the site at that place along the tab strip, the last one |
| Ctrl-Q on Linux and Windows | leave the app, from any screen, a window a close only hides included (NOTIF-018); on macOS Command-Q is the app menu's, and an Android app does not quit itself |

A key SHALL reach the shortcuts before the focused widget: Linux's webview keeps
every key it is given, and so does a page on Android (NAV-019). On macOS a page has the first chance at a key, as WKWebView
gives it, and the shortcuts take what the page leaves. A key the page has no answer
for at that moment (no site on screen, a site without tabs, no site at that place)
SHALL go on to the focused widget, and so SHALL every other key: Ctrl/Cmd-A selects
all in the page or the field that has focus, as the webview and the text field do on
their own. While a dialog, a sheet, a menu or another screen is over the page, the
keys SHALL be theirs. A held key SHALL ask once. A locked kiosk session (KIOSK-002)
SHALL keep only Refresh, Back and Forward, which stay on the site. While one of the
app's own text fields has focus (the URL bar, the find bar), Cmd-Left and Cmd-Right
SHALL be the field's, taking the caret to the line's ends as Safari leaves them; the
other keys, Cmd-[ and Alt-Left among them, keep their action there.

A nested screen (NAV-008) on top SHALL answer the keys for its own page: Refresh,
Find in page, its URL bar, Forward, and Back as its back gesture does it, so at the
start of its history the screen closes; Ctrl/Cmd-W SHALL close it, as its app bar's
back arrow does. New tab and the site keys are the page's and do nothing there.

Both menus SHALL write the key beside each item one runs, as the platform's menus
write keys: "⌘T" on macOS, "Ctrl+T" elsewhere, with the platform localizations'
names for the keys. The buttons of their top row that a key runs, Back and Refresh,
SHALL name it on a second line of their tooltips. On Android a key is written only while
a hardware keyboard is attached, and on iOS none is.

#### Scenario: A new tab and its close

- **GIVEN** a site with tabs on screen on Linux
- **WHEN** the user presses Ctrl-T
- **THEN** the site has a new tab, on screen
- **AND** Ctrl-W closes it and shows the tab before it

#### Scenario: The URL bar

- **GIVEN** a site on screen with the URL bar on
- **WHEN** the user presses Ctrl-L
- **THEN** the URL bar has the focus with the whole address selected

#### Scenario: Moving along the sites

- **GIVEN** three sites in the selected webspace, the first on screen
- **WHEN** the user presses Ctrl-2, then Ctrl-9, then Ctrl-Tab
- **THEN** the second site, then the third, then the first is on screen

#### Scenario: A menu keeps the keys

- **GIVEN** the site menu is open over the page
- **WHEN** the user presses Ctrl-T
- **THEN** no tab opens

#### Scenario: A nested screen's own keys

- **GIVEN** a nested screen over the page
- **WHEN** the user presses Ctrl-R
- **THEN** the nested page reloads and the site's page behind it does not
- **AND** Ctrl-W closes the nested screen, and Ctrl-2 there switches no site

#### Scenario: The menus name the keys

- **GIVEN** a site on screen on Linux
- **WHEN** the user opens the site menu
- **THEN** New tab reads Ctrl+T and Find reads Ctrl+F beside them
- **AND** the Back button's tooltip names Alt+← and the Refresh button's Ctrl+R

#### Scenario: Command-Left in the URL bar

- **GIVEN** a site on screen on macOS with the cursor in the URL bar
- **WHEN** the user presses Cmd-Left
- **THEN** the caret goes to the start of the address and the page stays
- **AND** outside the URL bar Cmd-Left goes back

#### Scenario: A kiosk stays on its site

- **GIVEN** a locked kiosk session
- **WHEN** the user presses Ctrl-Tab or Ctrl-2
- **THEN** the site on screen stays

Test: [test/keyboard_shortcut_test.dart](../../../test/keyboard_shortcut_test.dart)

---

### Requirement: NAV-015 - The Nested Menu Leads With The Site Menu's Row

A nested screen's overflow menu SHALL open with the site menu's top row, built by the
same code: Back, Share, and Refresh, or Stop while the page loads. Home SHALL be left
out, as a nested screen has no site home. The row's Back SHALL walk the nested page's
history only; closing the screen stays with its app bar's back arrow and the back
gesture (NAV-008). The menu's other items follow the row.

#### Scenario: The same row

- **GIVEN** a nested screen over the page
- **WHEN** the user opens its overflow menu
- **THEN** its first row holds Back, Share and Refresh, and no Home
- **AND** the row's Refresh reloads the nested page

Test: [test/keyboard_shortcut_test.dart](../../../test/keyboard_shortcut_test.dart)

---

### Requirement: NAV-017 - A Click Beside A Menu Over The Page Closes It

A click on a site's page while a menu, a dialog or a sheet is over it SHALL reach the
route on top, as a click anywhere else does: a menu closes, and the page takes nothing.
This holds for the site's own page and a nested screen's (NAV-008). On macOS a
platform view takes every click Flutter has not painted over (flutter/flutter#128519),
and a menu's barrier paints nothing, so while another route covers the page it SHALL
be painted over with a veil no eye can see; the page under it SHALL NOT be remounted
when the veil comes or goes. Elsewhere the page is Flutter's to hit-test, and the
route's barrier already takes the click.

#### Scenario: A click on the page closes the site menu

- **GIVEN** the site menu open over a site's page on macOS
- **WHEN** the user clicks the page beside the menu
- **THEN** the menu closes and the page receives no click

Test: [test/route_cover_test.dart](../../../test/route_cover_test.dart)

---

### Requirement: NAV-018 - A Refresh While A Page Loads Loads It Again

A Refresh of any kind (Ctrl/Cmd-R, F5, pull-to-refresh, the menus' Refresh) while the
page is still loading SHALL load the page in flight again, as a browser's reload does,
not the page shown before it. WebKit's reload reloads the document on screen, so in
the middle of a navigation it drops the load the user is waiting on, or does nothing
before the first page commits. A load in flight at an http or https address SHALL be
issued again with the headers a navigation the app issues carries (the site's
language among them), which replaces the pending load; any other load reloads. A load
the site may not issue (LEAK-010) SHALL stay refused.

#### Scenario: Ctrl-R on a slow first load

- **GIVEN** a site whose first page is still loading
- **WHEN** the user presses Ctrl/Cmd-R
- **THEN** that page is requested again, in the site's language
- **AND** a page that has finished loading reloads as before

Test: [test/webview_controller_lifetime_test.dart](../../../test/webview_controller_lifetime_test.dart)

---

### Requirement: NAV-016 - A TV Remote Reaches The Page And The App Bar

Where a remote's D-pad drives the device rather than a touchscreen (Android TV, or an
Android device with neither a touchscreen nor a pointer standing in for one,
`android.hardware.faketouch`, as a desktop's mouse does; probed once at startup by
`RemoteInput`), a site's
page SHALL take the D-pad the way a TV browser does, and the app's chrome SHALL stay
reachable from it:

- While the page has focus, the four arrows and the centre button SHALL reach the webview,
  whose own spatial navigation moves between links and scrolls. Flutter takes every key before a platform
  view and spends an arrow on moving its own focus, so without this the page never sees one.
- Focus arriving on the page by the D-pad SHALL give the webview native focus, which a
  Flutter focus move alone does not.
- An arrow the page had no use for (it moved no focus, scrolled nothing and was not taken
  with `preventDefault`) SHALL move focus out of the page in that direction, to the app bar
  above it or the tab strip below. In a text field the arrows SHALL stay with the caret, and
  a held arrow SHALL never leave the page.
- The app SHALL appear in the Android TV launcher with a banner, and SHALL install on a
  device without a touchscreen.

Everything outside the page SHALL be reachable and usable by the D-pad and OK alone,
since a remote has no long press, no Menu key and nothing to drag with:

- Up and Down SHALL leave a one-line text field (the library's search, the URL bar);
  Left and Right stay with its caret, and a field of several lines keeps all four.
- Up and Down SHALL leave a slider (a settings row's zoom, say); Left and Right change its
  value. The app runs in Flutter's directional navigation there, which Flutter never picks
  itself, so a disabled control also takes focus and the D-pad can rest on it.
- An outline SHALL mark whatever has focus, drawn inside the control. A site page (its
  engine outlines the focused link), a launcher icon and a tab strip chip outline
  themselves, so no second outline is drawn over them.
- A launcher icon pressed with OK or Enter SHALL open as a tap does; held, it SHALL open
  its menu as a long press does. This holds for any key, on every device.
- In a launcher grid that reorders, an icon's menu and a group's SHALL offer Move Up and
  Move Down, the moves a drag makes; "All" never moves.
- In an open library folder, a move down or up from the folder SHALL go into it, and the
  dimmed home screen behind it SHALL take no focus.
- Every chip of the tab strip SHALL take focus: OK opens its site, or the Tabs sheet on the
  one on screen. Every row of the Tabs sheet and its web search are reachable as they are.

A key reaches only the document of the frame holding focus, so the edge is read by a
script in every frame (`lib/js/remote_edge.js`): a frame SHALL pass an arrow it had no use
for to its parent, which SHALL pass it on only if it came from the frame holding its focus
and nothing there moved focus or scrolled since the key, and only the top document SHALL
call the bridge. The app SHALL move focus out at most once per D-pad press, and only for
the arrow pressed, so a frame that reports an arrow nobody pressed moves nothing.

On an Android device no remote drives, the page takes a keyboard's keys instead (NAV-019),
with no page script. On every other platform the page's webview SHALL be built exactly as
before: no wrapper, no page script. Popups opened by a page are not covered.

#### Scenario: Scrolling and following links with the D-pad

- **GIVEN** a TV, and a site's page on screen
- **WHEN** the user moves down from the app bar with the D-pad
- **THEN** the page takes focus, and further arrows move between its links and scroll it
- **AND** the centre button opens the focused link

#### Scenario: Back to the app bar

- **GIVEN** a TV, and a page scrolled to its top with its first link focused
- **WHEN** the user presses up
- **THEN** focus moves to the app bar, from where the menu and the site switcher open

#### Scenario: Out of a frame

- **GIVEN** a TV, and a page whose content is a frame from another origin, its first link
  focused
- **WHEN** the user presses up
- **THEN** focus moves to the app bar, as it does from the page itself
- **AND** a frame the user is not in, an ad say, cannot move the app's focus

#### Scenario: A site in a folder, by remote

- **GIVEN** a TV in Alternative design
- **WHEN** the user presses down past the search field, onto a folder, OK, then down twice
- **THEN** a site in that folder has focus, and OK opens it
- **AND** OK held instead opens its menu, with the moves its folder allows

#### Scenario: Another site from the tab strip

- **GIVEN** a TV with the tab strip on
- **WHEN** the user moves along the strip and presses OK on a site
- **THEN** that site opens; OK on the site on screen opens its tabs

Test: [test/page_focus_test.dart](../../../test/page_focus_test.dart),
[test/js/remote_edge.test.js](../../../test/js/remote_edge.test.js),
[test/browser/remote_edge_frames.test.js](../../../test/browser/remote_edge_frames.test.js)
(cross-origin frames in Chromium, spatial navigation on),
[test/remote_controls_test.dart](../../../test/remote_controls_test.dart),
[test/remote_library_test.dart](../../../test/remote_library_test.dart),
[test/remote_tabs_test.dart](../../../test/remote_tabs_test.dart),
[integration_test/remote_tv_test.dart](../../../integration_test/remote_tv_test.dart)
(the Android TV emulator, INTEG-017)

---

### Requirement: NAV-019 - An Android Desktop Window And A Keyboard

Where Android runs the app in a window of its desktop windowing (Android 15 and later) or
with a hardware keyboard attached (a tablet's, a laptop's), the app SHALL answer as it does
on a desktop wherever the desktop's answer applies, as NAV-016 answers a TV's remote:

- The header Android draws over a desktop window SHALL be transparent, so the app's own bar
  runs under its buttons and the content is set below the header once. An opaque header
  is set below twice: Android lays the app out below it, and Flutter, which reads the
  header from the window's insets, pads the top for it again.
- The header's buttons SHALL be drawn dark over a light app and light over a dark one,
  following the app's theme, the app's own choice of it included.
- The keys of NAV-014 SHALL answer with Control, as Chrome on Android takes them, save
  Ctrl-Q, which goes on to the page: an Android app does not quit itself.
- The menus SHALL write each key beside its item while a hardware keyboard is attached,
  followed as one is attached or folded away, and none while none is.
- While a site's page has focus, every key the shortcuts left SHALL reach the webview.
  Flutter takes every key before a platform view and spends the arrows and Tab on moving
  its own focus, so without this a page's field could not move its caret and a page could
  not be scrolled or tabbed through. Tab and the arrows stay in the page, as Linux's
  webview keeps them; a click or Ctrl-L leaves it.
- Focus arriving on the page from the keyboard (Tab from the app bar) SHALL give the
  webview native focus while a keyboard is attached. Without one, focus arrives only by a
  touch, which gives it on its own.

Where a remote drives the device, NAV-016 applies instead: its D-pad keeps its edge moves.

#### Scenario: The header of a desktop window

- **GIVEN** the app in a window of Android's desktop windowing, in the dark theme
- **WHEN** App Settings opens
- **THEN** its app bar runs under the window's buttons, with no empty band between them
- **AND** the buttons are light; in the light theme they are dark

#### Scenario: A new tab from the keyboard

- **GIVEN** an Android device with a keyboard attached and a site with tabs on screen
- **WHEN** the user presses Ctrl-T
- **THEN** the site has a new tab, on screen
- **AND** the site menu writes Ctrl+T beside New tab, and writes nothing once the keyboard
  is detached

#### Scenario: Typing in a page

- **GIVEN** an Android device with a keyboard and a page's text field focused
- **WHEN** the user presses Left, then Tab
- **THEN** the caret moves left, then the page's next field has focus
- **AND** the app bar never takes focus

Test: [test/page_focus_test.dart](../../../test/page_focus_test.dart) (the page's keys),
[test/keyboard_shortcut_test.dart](../../../test/keyboard_shortcut_test.dart) (Control,
no Ctrl-Q, the keys written), [test/window_caption_test.dart](../../../test/window_caption_test.dart)
(the header's buttons),
[integration_test/android_desktop_test.dart](../../../integration_test/android_desktop_test.dart)
(the Android desktop emulator, INTEG-018: the header laid out once, the keys through
the real key path).

## Race Condition Guards

### Guard: RACE-002 - _backGuard

**Problem:** The PopScope `onPopInvokedWithResult` handler is async. Rapid back gestures could invoke it concurrently, causing double navigation or drawer flash.

**Solution:** A `ReentryGuard` (`_backGuard`) drops concurrent invocations. Its `run` releases it in its own `finally`, so no exit path leaves it held.

### Guard: RACE-003 - SiteRuntime.activationVersion Counter

**Problem:** `activate()` performs multiple async operations (cookie capture, domain conflict resolution, cookie restoration). Rapid site switching could interleave these operations.

**Solution:** Version counter `SiteRuntime.activationVersion` is checked after each `await` gap. If the version changed (another `activate` call started), the stale call returns early.

### Guard: RACE-004 - goHome() Synchronous Execution

**Problem:** If `goHome()` were async, rapid taps could interleave with webview recreation.

**Solution:** `goHome()` is fully synchronous. It completes in a single microtask:
1. Resets `currentUrl` to `initUrl`
2. Disposes webview (`webview = null`, `controller = null`)
3. Triggers a rebuild via `setState` so the webview is recreated fresh
4. Saves state (fire-and-forget async, but idempotent)

Double-tap is harmless: second call disposes an already-null webview.

---

## Implementation

### Decision Flow: System Back Gesture

The call site gathers state (drawer, controller, `canGoBack()` where it is
trusted) and `decideBackGesture` in
[lib/services/back_gesture_engine.dart](../../../lib/services/back_gesture_engine.dart)
returns the action; `openMenu` below is the NAV-009 setting, and is forced off
on iOS/macOS and while the kiosk shell is locked.

```
System back gesture received
  │
  ├─ didPop? ──────────────────── return (system handled it)
  ├─ _backGuard.busy? ────────── return (drop concurrent)
  │
  ├─ Drawer open?
  │   ├─ openMenu && opened by this gesture && Android ─── close drawer + exit app
  │   └─ else ──────────────────────────────────────────── close drawer
  │
  ├─ No controller? ───────────── openMenu && Android ? exit app : no-op
  │
  ├─ Android && has controller:
  │   ├─ canGoBack()? ─────────── goBack()
  │   └─ else ─────────────────── openMenu ? open drawer : no-op
  │
  └─ iOS/macOS && has controller:
      ├─ urlBefore = getUrl()
      ├─ goBack()
      ├─ wait 150ms
      ├─ urlAfter = getUrl()
      │
      ├─ URL changed? ─────────── back succeeded
      └─ URL same? ────────────── openMenu ? open drawer : no-op
```

### Decision Flow: Drawer Edge Drag Width

```
Build Scaffold
  │
  ├─ No webview visible? ──────── null (default, swipeable)
  └─ Webview visible? ─────────── 0 (disabled, all platforms)
```

### Decision Flow: Home Button

```
Home button pressed
  │
  ├─ Close menu (Navigator.pop)
  │
  └─ goHome():
      ├─ model.currentUrl = model.initUrl
      ├─ model.disposeWebView()    ← webview=null, controller=null
      ├─ setState(() {})           ← trigger rebuild
      └─ _commitSites(SitesEdited())  ← persist reset URL
      
      Next frame: getWebView() sees webview==null
        → creates fresh webview with UniqueKey
        → loads initUrl with zero history
```

### Files

#### `lib/services/back_gesture_engine.dart`
- `decideBackGesture` / `decideAfterAttemptedGoBack` — the whole policy above as
  pure functions returning a `BackGestureAction`; `BackAtHistoryStart` is the
  NAV-009 setting. `backAtHistoryStartConfigurable` says where that setting is
  offered at all. Tests: [test/back_gesture_engine_test.dart](../../../test/back_gesture_engine_test.dart)

#### `lib/controllers/back_gesture_controller.dart`
- `_backGuard` — `ReentryGuard` for the PopScope handler
- `_backAtHistoryStart` — NAV-009 setting, mirrored from the `backOpensMenu` pref
  on load and import, and pinned to `ignore` where `_backAtHistoryStartOffered`
  is false (iOS/macOS)
- `_drawerOpenedByBackGesture` — set when the handler opens the drawer, cleared by
  `Scaffold.onDrawerChanged` (`drawerChanged`) on every close, so only a gesture-opened drawer escalates
- `_openDrawerFromBackGesture()` — the one place that opens the drawer for NAV-009

#### `lib/screens/webspace_page.dart`
- `goHome()` — synchronous: dispose webview, reset URL, trigger rebuild
- `PopScope` widget — wraps Scaffold; `canPop: false` always on Android (so back never exits the app), `!webviewIsVisible` on other platforms; handles system back gesture with URL comparison, navigating webview history only
- `drawerEdgeDragWidth` — `0` whenever a webview is visible (drawer edge swipe disabled on all platforms); `null` otherwise
- Back button `IconButton` (portrait ~line 1685, landscape ~line 2047)
- Home button `IconButton` (portrait ~line 1701, landscape ~line 2063)

#### `lib/services/keyboard_shortcuts.dart`
- `KeyboardShortcut.keys` — every key a shortcut takes, per platform (NAV-014)
- `KeyboardShortcuts` — takes the keys for the `ShortcutScreen` on top, through `FocusManager.addEarlyKeyEventHandler`, on desktop only; `editingText` leaves Cmd-Left and Cmd-Right to a focused text field

#### `lib/services/webview_controller.dart`
- `PlatformWebViewController.reload` — issues a load in flight again rather than reloading the page before it (NAV-018)

#### `lib/services/route_cover.dart`
- `RouteCover.over` — veils a site's page on macOS while another route covers it, so a click there reaches that route (NAV-017)

#### `lib/controllers/keyboard_shortcut_controller.dart`
- `KeyboardShortcutController.answerShortcut` — the page's answer to each, through the controllers that own tabs, Refresh, Back and Forward; the nested screen's own answers are `_InAppWebViewScreenState.answerShortcut`

#### `lib/widgets/url_bar.dart`
- `UrlBarState.edit()` — the focus and selection a tap gives, for Ctrl/Cmd-L (NAV-014)

#### `lib/widgets/site_menu.dart`
- `siteMenuNavRow` — the top row of the site menu and of the nested screen's (NAV-015)
- `_handleSubmit()` — awaits `onUrlSubmitted`, then shows `currentUrl` again; a submit that leaves `currentUrl` unchanged would otherwise leave the typed text behind (NAV-007)
- `didUpdateWidget` — follows `currentUrl` except while the user is editing

#### `lib/web_view_model.dart`
- `stateSetterF` callback — injected closure that calls `setState`
- `getWebView()` — creates webview with `key: UniqueKey()` for fresh state on recreation
- `disposeWebView()` — sets `webview = null`, `controller = null`
- `onUrlChanged` callback — triggers `stateSetterF` on URL change

#### `lib/services/webview.dart`
- `onUpdateVisitedHistory` — fires on all history changes including BFCache restorations
- `onLoadStop` — fires on page load completion, may miss BFCache on iOS
- `_hasUserGesture()` — platform-specific gesture detection for navigation actions
- `WebViewController.canGoBack()` / `.goBack()` — delegates to flutter_inappwebview

---

## Related PRs

| PR | Title | Relevance |
|----|-------|-----------|
| #168 | Add pull-to-refresh and back gesture navigation | Initial PopScope + pull-to-refresh + drawer conflict disable |
| #170 | Use back button to toggle drawer when webview can't go back | PopScope fallback: drawer opens when no history |
| #172 | Enable drawer swipe-right on iOS when webview can't go back | iOS `_canGoBack` state + conditional `drawerEdgeDragWidth` |
| #174 | Fix URL bar not updating on Safari back gesture | Added `onUpdateVisitedHistory` for BFCache restorations |
| #175 | Fix F-Droid badge opening in current webview instead of nested on iOS | `onCreateWindow` delegation for `target="_blank"` on iOS |

---

## Testing

### Manual Test: System Back Navigates History

1. Add a site (e.g., wikipedia.org)
2. Navigate to several pages via links
3. Press system back (Android) or trigger PopScope (iOS)
4. Verify each press navigates back one page
5. When at the initial URL, verify back does nothing (no drawer, no exit)

### Manual Test: Back At Start Of History (NAV-009)

1. (Android/Linux/Windows) App settings → turn on "Back gesture opens the menu"
2. Open a site, press system back at its initial URL — the drawer opens
3. Press system back again — the drawer closes and the app is left (Android)
4. Open the drawer with the AppBar menu button, press system back — it only closes
5. Turn the setting off again and repeat step 2 — back does nothing
6. (iOS/macOS) App settings shows no such row, and the left-edge swipe is
   WKWebView's own: back through history, nothing at its start

### Manual Test: Android Back Never Exits (Webview)

1. (Android) Add a site and navigate to its initial URL
2. Press system back repeatedly — verify the app neither opens the drawer nor exits
3. Verify the drawer still opens via the AppBar menu button

### Manual Test: Android Back On Homepage

1. (Android) Go to the webspace list (no webview selected)
2. Press system back — verify nothing happens (no drawer, no exit)

### Manual Test: Home Button Clears History

1. Navigate to several pages deep in a site
2. Open the menu and press the Home button
3. Verify the site returns to its initial URL
4. Press system back — verify nothing happens (no back history)

### Manual Test: Drawer Edge Swipe Disabled With Webview

1. Open any site so a webview is visible
2. Swipe from the left edge — verify the drawer does NOT open
3. Open the drawer via the AppBar menu button — verify it works

### Manual Test: Back To Webspaces Always Leaves The Site

1. Open a site, then tap "Back to Webspaces" (menu or drawer)
2. Verify the webspace list appears every time, including:
   - right after switching between two sites in quick succession
   - right after deleting another site
   - on a page that stopped responding

### Manual Test: Rapid Home Tap (Race Condition)

1. Navigate to a deep page
2. Open the menu and rapidly double-tap the Home button
3. Verify the site returns to its initial URL without errors

### Manual Test: Pull-to-Refresh

1. Open any site in the main webview
2. Pull down on the page
3. Verify the refresh indicator appears and the page reloads
4. Open a cross-domain link (opens nested webview)
5. Pull down in the nested webview
6. Verify refresh works in nested webview too
7. Scroll back to the top and pinch to zoom with two fingers
8. Verify no refresh indicator appears and the page does not reload
9. Verify a normal one-finger pull still refreshes right after

### Manual Test: URL Bar Sync on iOS Back Gesture

1. (iOS) Navigate to several pages
2. Trigger back navigation (via menu back button)
3. Verify the URL bar updates to the previous page's URL
4. Verify this works even for BFCache-restored pages
