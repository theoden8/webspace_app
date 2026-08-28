# Navigation Specification

## Purpose

Controls all in-app navigation: system back gesture, menu back/home buttons, drawer swipe gesture, and pull-to-refresh. Handles platform differences between iOS and Android, and guards async state against race conditions.

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
| iOS | WKWebView's native swipe is silent at the start of history, and consumes the gesture | The app never learns the swipe happened, so NAV-009 cannot act on it through PopScope; the opt-in installs its own left-edge recognizer instead (NAV-011) |
| iOS/macOS | No `hasGesture`; must infer from `navigationType` (`LINK_ACTIVATED`, `FORM_SUBMITTED`) | Less reliable than Android's boolean flag |

---

## Requirements

### Requirement: NAV-001 - System Back Gesture

The system back gesture (Android back button, iOS/macOS left-edge swipe) SHALL navigate back in webview history when possible. On the root site webview, iOS/macOS use WKWebView's native back/forward swipe (`allowsBackForwardNavigationGestures`); Android, and all nested routes, use the PopScope handler. It SHALL NOT open the drawer and SHALL NOT exit the app; when there is no back history it is a no-op. What happens at that history start is the one thing the user can change, via the opt-in setting in NAV-009 — off by default, which is this requirement.

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
**And** the setting in NAV-009 is off (on, iOS takes the edge back per NAV-011)

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

All webviews (main and nested) SHALL support pull-to-refresh to reload the current page.

#### Scenario: Pull to refresh

**Given** a webview is visible
**When** the user pulls down on the page
**Then** the page reloads
**And** the pull-to-refresh indicator animates
**And** the indicator stops when `onLoadStop` fires

---

### Requirement: NAV-007 - URL Bar Sync

The URL bar SHALL stay in sync with the current webview URL across all navigation types, including BFCache restorations.

#### Scenario: Standard navigation

**Given** a webview navigates to a new page
**When** `onLoadStop` fires
**Then** the URL bar updates to the new URL

#### Scenario: iOS back gesture with BFCache

**Given** an iOS webview restores a page from BFCache via back/forward gesture
**When** `onLoadStop` does NOT fire
**Then** `onUpdateVisitedHistory` fires instead
**And** the URL bar updates to the restored URL

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
**Then** the second invocation drops (guarded by `_isBackHandling`)
**And** at most one `goBack()` per gesture is dispatched

---

### Requirement: NAV-009 - Back At Start Of History (opt-in)

The app SHALL expose exactly one global setting for what the system back gesture does once the webview has no page left to go back to. It SHALL default to off, which is NAV-001's no-op.

When the setting is on, the back gesture at the start of a site's history SHALL open the drawer, and a further back gesture on a drawer *that gesture opened* SHALL close it and leave the app. A drawer the user opened any other way (AppBar menu button, webspace tap) SHALL only close, never leave the app — and leaving the app SHALL happen on Android only, where finishing the activity is the platform's own back-at-root behaviour.

The setting SHALL be persisted as the `backOpensMenu` app pref and ride settings export/import. It SHALL have no effect while the kiosk shell is locked (KIOSK-002), which owns the drawer's absence.

**Rationale:** Issue #369 and issue #431 ask for opposite gestures from the same swipe: one user's news-site navigation is broken by the drawer appearing mid-article, the other lost the "menu, then exit" sequence they navigated by. Neither is wrong, and no heuristic separates them, so the choice belongs to the user. Off stays the default because it is the gesture that cannot misfire: it never takes the user somewhere they did not ask to go.

The escalation to leaving the app is bound to the drawer the gesture itself opened, because otherwise back-to-dismiss on a deliberately opened menu would quit the app — the exact ambiguity NAV-001 removed.

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

#### Scenario: Setting on — second gesture leaves the app

**Given** the setting is on
**And** the drawer was opened by the back gesture on Android
**When** the user triggers the system back gesture again
**Then** the drawer closes
**And** the app is left via `SystemNavigator.pop()`

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

#### Scenario: Setting on — iOS/macOS URL-comparison path

**Given** the setting is on on iOS or macOS
**And** `goBack()` was attempted and the URL did not change (NAV-002)
**When** the handler resolves the gesture
**Then** the drawer opens
**And** the app is NOT left

#### Scenario: Locked kiosk shell ignores the setting

**Given** the setting is on
**And** the kiosk shell is locked (KIOSK-002, no drawer)
**When** the user triggers the system back gesture at the start of history
**Then** nothing happens (no drawer, no exit)

---

### Requirement: NAV-011 - iOS Edge Swipe Reaches The NAV-009 Policy

While the NAV-009 setting is on and a site is visible on iOS, the app SHALL claim a narrow strip of the webview's left edge with its own horizontal drag recognizer and route a rightward drag there through the same back-gesture policy as the system back gesture. The strip SHALL exist only while the setting is on, a webview is visible, and the drawer is available (KIOSK-002); with the setting off, the edge belongs to WKWebView and NAV-001 stands unchanged.

A drag that resolves as horizontal SHALL be handled by the app, and one that resolves as vertical SHALL reach the page, so scrolling at the left edge still works. Leaving the app stays Android-only (NAV-009), so on iOS the strip only ever navigates back or opens the drawer.

The setting's hint SHALL describe the app-exit escalation only on the platform where it happens.

**Rationale:** the root site webview owns the left edge natively (`allowsBackForwardNavigationGestures`, NAV-001) and the root route has no Flutter pop for `PopScope` to intercept, so on iOS the swipe was resolved entirely inside WKWebView — which does nothing, silently, at the start of history. NAV-009 could therefore never fire on iOS, and the toggle read as broken. Taking the edge back costs WKWebView's interactive swipe animation, which is why it is scoped to the sessions that opted in.

Before #371 this worked by a different route: `drawerEdgeDragWidth` was left enabled on iOS exactly while a tracked `_canGoBack` was false, so the Scaffold's own edge drag opened the drawer at history start. #371 removed both the drag and the tracking, and #512 later handed the edge to WKWebView. That mechanism is not restored here: it gated on `canGoBack()`, which is unreliable on iOS in both directions (NAV-002), so it opened the drawer where history existed and stayed shut where it did not. The recognizer decides from the same `goBack()` + URL diff NAV-002 makes authoritative instead.

The hint said "On Android, pressing back again leaves the app" on every platform, describing a behaviour iOS does not have.

#### Scenario: Setting on — iOS edge swipe at the start of history

**Given** the setting is on on iOS
**And** a webview is visible with no back history
**When** the user swipes right from the left edge
**Then** the drawer opens
**And** the app is NOT left

#### Scenario: Setting on — iOS edge swipe with history

**Given** the setting is on on iOS
**And** a webview is visible with back history
**When** the user swipes right from the left edge
**Then** the webview navigates back (the NAV-002 URL-comparison path)
**And** the drawer does not open

#### Scenario: Setting off — the edge stays WKWebView's

**Given** the setting is off on iOS
**When** a site is visible
**Then** the app installs no recognizer over the left edge
**And** the native back/forward swipe behaves as in NAV-001

#### Scenario: Vertical scrolling at the left edge still reaches the page

**Given** the setting is on on iOS
**When** the user drags vertically starting at the left edge
**Then** the page scrolls
**And** no back gesture is resolved

#### Scenario: Hint copy names app-exit only where it applies

**Given** the app settings screen is open
**When** the user opens the setting's hint on a platform other than Android
**Then** the hint does not mention leaving the app

---

### Requirement: NAV-010 - Leaving A Site Is Committed Before Its Teardown

Returning to the webspace list SHALL take effect on the user's tap, independently of the teardown of the site being left. `_setCurrentIndex(null)` SHALL assign `_currentIndex` and exit fullscreen **before** it captures nav state, stops a real camera capture, pauses media, or pauses the webview — nothing in that sequence decides where the user ends up.

That teardown is best-effort and SHALL be funnelled through `SiteTeardownEngine.quiesceOutgoing` (also used by the site-switch path and the defensive sweep of background sites), which:

- keeps the caller's step order (camera stop and media pause ahead of the pause — CAM-012 / BGAUDIO-009);
- treats a step that throws as best-effort and runs the ones behind it anyway;
- gives the whole sequence one budget (`SiteTeardownEngine.defaultBudget`) and returns when it expires, abandoning — not cancelling — the stalled step;
- re-checks the `_setCurrentIndexVersion` guard before each remaining step, including after the budget expired, so an abandoned sequence whose native reply lands late cannot pause a webview a newer activation has since resumed (PAUSE-005).

Storage on this path SHALL fail closed rather than throw: `SecureWebViewStateStorage` swallows an initialization failure, degrades save/load to no-ops, and clears its memoized in-flight init so a later call retries instead of replaying the failure for the rest of the run.

**Rationale:** each teardown step is a native round-trip, and the commit used to sit behind all four. Any of them throwing (a state-storage init that failed once and then re-threw its memoized failure forever), being superseded (a version bump from a concurrent delete, archive close, or activation), or never answering at all left `_currentIndex` on the site the user asked to leave — "back to webspaces" did nothing, silently, with nothing to retry against. The never-answering case is reachable: on iOS the per-instance pause freezes the page's JS thread (the plugin's withheld-`alert()` hack), so a site left paused by a race-cancelled switch never answers the `evaluateJavascript` that the next teardown opens with.

#### Scenario: A teardown step that never answers still returns the user home

**Given** site A is active and its JS thread is frozen by an earlier pause
**When** the user taps "Back to Webspaces"
**And** the media-pause step never answers
**Then** `_currentIndex` is already null and fullscreen is already exited
**And** the sequence is abandoned once the budget expires
**And** the webspace list is shown

#### Scenario: A failing state capture does not cost the pause

**Given** site A is active
**And** the state storage fails to initialize
**When** the user returns to the webspace list
**Then** the capture step is recorded as failed
**And** the camera stop, media pause and webview pause still run
**And** the return to the list is unaffected

#### Scenario: A newer activation still wins the teardown

**Given** a return to the webspace list is mid-teardown of site A
**When** the user taps site A again before the teardown finishes
**Then** the remaining teardown steps are skipped
**And** A is not left paused by the abandoned sequence

#### Scenario: A concurrent delete no longer strands the return

**Given** a return to the webspace list is mid-teardown
**When** another path bumps `_setCurrentIndexVersion` (site delete, archive close)
**Then** the teardown stops early
**And** the user is still on the webspace list, because the commit already happened

---

## Race Condition Guards

### Guard: RACE-002 - _isBackHandling Flag

**Problem:** The PopScope `onPopInvokedWithResult` handler is async. Rapid back gestures could invoke it concurrently, causing double navigation or drawer flash.

**Solution:** Boolean `_isBackHandling` flag drops concurrent invocations. Cleared in a `finally` block to guarantee cleanup.

### Guard: RACE-003 - _setCurrentIndexVersion Counter

**Problem:** `_setCurrentIndex()` performs multiple async operations (cookie capture, domain conflict resolution, cookie restoration). Rapid site switching could interleave these operations.

**Solution:** Version counter `_setCurrentIndexVersion` is checked after each `await` gap. If the version changed (another `_setCurrentIndex` call started), the stale call returns early.

### Guard: RACE-004 - _goHome() Synchronous Execution

**Problem:** If `_goHome()` were async, rapid taps could interleave with webview recreation.

**Solution:** `_goHome()` is fully synchronous. It completes in a single microtask:
1. Drops the site's cached HTML via `_deleteCacheIfOnline(siteId)` so the next load starts from the live page instead of a stale snapshot (the cached frame could otherwise flash with pre-edit content or mismatched theme before user scripts re-run). The helper is fire-and-forget and skips deletion when the device is offline, so offline users keep a renderable snapshot.
2. Resets `currentUrl` to `initUrl`
3. Disposes webview (`webview = null`, `controller = null`)
4. Triggers a rebuild via `setState` so the webview is recreated fresh
5. Saves state (fire-and-forget async, but idempotent)

Double-tap is harmless: second call disposes an already-null webview. `deleteCache` on the second call is also a no-op (file already removed).

---

## Implementation

### Decision Flow: System Back Gesture

The call site gathers state (drawer, controller, `canGoBack()` where it is
trusted) and `decideBackGesture` in
[lib/services/back_gesture_engine.dart](../../../lib/services/back_gesture_engine.dart)
returns the action; `openMenu` below is the NAV-009 setting, and is forced off
while the kiosk shell is locked.

```
System back gesture received
  │
  ├─ didPop? ──────────────────── return (system handled it)
  ├─ _isBackHandling? ─────────── return (drop concurrent)
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
  └─ _goHome():
      ├─ model.currentUrl = model.initUrl
      ├─ model.disposeWebView()    ← webview=null, controller=null
      ├─ setState(() {})           ← trigger rebuild
      └─ _saveWebViewModels()      ← persist reset URL
      
      Next frame: getWebView() sees webview==null
        → creates fresh webview with UniqueKey
        → loads initUrl with zero history
```

### Files

#### `lib/services/back_gesture_engine.dart`
- `decideBackGesture` / `decideAfterAttemptedGoBack` — the whole policy above as
  pure functions returning a `BackGestureAction`; `BackAtHistoryStart` is the
  NAV-009 setting. Tests: [test/back_gesture_engine_test.dart](../../../test/back_gesture_engine_test.dart)

#### `lib/main.dart`
- `_isBackHandling` — boolean guard for PopScope handler
- `_backAtHistoryStart` — NAV-009 setting, mirrored from the `backOpensMenu` pref
- `_drawerOpenedByBackGesture` — set when the handler opens the drawer, cleared by
  `Scaffold.onDrawerChanged` on every close, so only a gesture-opened drawer escalates
- `_openDrawerFromBackGesture()` — the one place that opens the drawer for NAV-009
- `_goHome()` — synchronous: dispose webview, reset URL, trigger rebuild
- `PopScope` widget — wraps Scaffold; `canPop: false` always on Android (so back never exits the app), `!webviewIsVisible` on other platforms; handles system back gesture with URL comparison, navigating webview history only
- `drawerEdgeDragWidth` — `0` whenever a webview is visible (drawer edge swipe disabled on all platforms); `null` otherwise
- Back button `IconButton` (portrait ~line 1685, landscape ~line 2047)
- Home button `IconButton` (portrait ~line 1701, landscape ~line 2063)

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

1. App settings → turn on "Back gesture opens the menu"
2. Open a site, press system back at its initial URL — the drawer opens
3. Press system back again — the drawer closes and the app is left (Android)
4. Open the drawer with the AppBar menu button, press system back — it only closes
5. Turn the setting off again and repeat step 2 — back does nothing

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

### Manual Test: URL Bar Sync on iOS Back Gesture

1. (iOS) Navigate to several pages
2. Trigger back navigation (via menu back button)
3. Verify the URL bar updates to the previous page's URL
4. Verify this works even for BFCache-restored pages
