# Navigation Specification

## Purpose

Controls all in-app navigation: system back gesture, menu back/home buttons, drawer swipe gesture, and pull-to-refresh. Handles platform differences between iOS and Android, and guards async state against race conditions.

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
| iOS/macOS | No `hasGesture`; must infer from `navigationType` (`LINK_ACTIVATED`, `FORM_SUBMITTED`) | Less reliable than Android's boolean flag |
| Linux (WPE) | Fork's `NavigationActionType` enum has no `formSubmitted` — `WEBKIT_NAVIGATION_TYPE_FORM_SUBMITTED` collapses into `other`. `hasGesture` is not serialized for regular navigation actions; only `navigationType` is. | `_hasUserGesture` infers from `navigationType` (treats `LINK_ACTIVATED` as gesture, `FORM_SUBMITTED` is unreachable so user-driven cross-origin form posts read as no-gesture and silently block) |

---

## Requirements

### Requirement: NAV-001 - System Back Gesture

The system back gesture (Android back button, iOS/macOS left-edge swipe) SHALL navigate back in webview history when possible. On the root site webview, iOS/macOS use WKWebView's native back/forward swipe (`allowsBackForwardNavigationGestures`); Android, and all nested routes, use the PopScope handler. It SHALL NOT open the drawer and SHALL NOT exit the app; when there is no back history it is a no-op.

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

#### Scenario: Webview has no back history

**Given** a webview is visible with no navigation history
**When** the user triggers the system back gesture
**Then** nothing happens (no drawer, no exit)

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

```
System back gesture received
  │
  ├─ didPop? ──────────────────── return (system handled it)
  ├─ _isBackHandling? ─────────── return (drop concurrent)
  │
  ├─ Drawer open? ─────────────── close drawer (never exit)
  │
  ├─ No controller? ───────────── no-op (no drawer, no exit)
  │
  ├─ Android && has controller:
  │   ├─ canGoBack()? ─────────── goBack()
  │   └─ else ─────────────────── no-op
  │
  └─ iOS/macOS && has controller:
      ├─ urlBefore = getUrl()
      ├─ goBack()
      ├─ wait 150ms
      ├─ urlAfter = getUrl()
      │
      ├─ URL changed? ─────────── back succeeded
      └─ URL same? ────────────── no-op
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

#### `lib/main.dart`
- `_isBackHandling` — boolean guard for PopScope handler
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
