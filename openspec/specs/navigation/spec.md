# Navigation Specification

## Purpose

Controls all in-app navigation: system back gesture, menu back/home buttons, drawer swipe gesture, and pull-to-refresh. Handles platform differences between iOS and Android, and guards async state against race conditions.

## Status

- **Date**: 2026-04-10
- **Status**: Active

---

## Problem Statement

WebSpace embeds webviews in a Scaffold with a drawer. Navigation gestures compete:

- The **system back gesture** (Android hardware back, iOS left-edge swipe) must navigate back in webview history or open the drawer as fallback.
- The **drawer edge swipe** must not conflict with webview back navigation on iOS.
- The **Home button** must return to the site's initial URL with a clean history so subsequent back gestures correctly detect "no history."
- **Async `canGoBack()` calls** (native IPC) can produce stale results when the user switches sites, presses Home, or navigates rapidly.

### Platform Quirks

| Platform | Quirk | Impact |
|----------|-------|--------|
| iOS | `canGoBack()` returns `false` for `history.pushState()` entries (SPAs) | Drawer becomes swipeable when it shouldn't; mitigated by PopScope URL-comparison fallback |
| iOS | `onLoadStop` does not fire for BFCache page restorations during back/forward gestures | URL bar doesn't update without `onUpdateVisitedHistory` (fixed in PR #174) |
| iOS | `target="_blank"` links may only trigger `onCreateWindow`, not `shouldOverrideUrlLoading` | Links load in current webview instead of nested browser without explicit delegation (fixed in PR #175) |
| iOS | `allowsBackForwardNavigationGestures` is NOT set (defaults to `false`) | WKWebView has no native back swipe; only the drawer edge gesture and PopScope participate |
| Android | `hasGesture` on `NavigationAction` is a reliable boolean | Used directly for gesture detection |
| iOS/macOS | No `hasGesture`; must infer from `navigationType` (`LINK_ACTIVATED`, `FORM_SUBMITTED`) | Less reliable than Android's boolean flag |

---

## Requirements

### Requirement: NAV-001 - System Back Gesture

The system back gesture (Android back button, iOS edge swipe via PopScope) SHALL navigate back in webview history when possible, and open the drawer as fallback.

#### Scenario: Webview has back history

**Given** a webview is visible and has navigation history
**When** the user triggers the system back gesture
**Then** the webview navigates back in history

#### Scenario: Webview has no back history

**Given** a webview is visible with no navigation history
**When** the user triggers the system back gesture
**Then** the drawer opens

#### Scenario: Drawer is already open (Android)

**Given** the drawer is open on Android
**When** the user triggers the system back gesture
**Then** the app exits (via `SystemNavigator.pop()`)

**Rationale:** On Android, the drawer serves as a visual "you're about to leave" cue. The first back gesture opens the drawer; the second exits. This two-step pattern prevents accidental exits in a multi-site browser where reloading webviews is costly, without resorting to an annoying "press back again to exit" toast.

#### Scenario: Drawer is already open (non-Android)

**Given** the drawer is open on iOS/macOS
**When** the user triggers the system back gesture
**Then** the drawer closes

#### Scenario: No webview visible — Android

**Given** the webspace list screen is visible (no webview selected) on Android
**When** the user triggers the system back gesture
**Then** the drawer opens (as an exit warning)

#### Scenario: No webview visible — non-Android

**Given** the webspace list screen is visible (no webview selected) on iOS/macOS
**When** the user triggers the system back gesture
**Then** the system pop behavior proceeds normally (app may exit)

---

### Requirement: NAV-002 - PopScope canGoBack Distrust

The PopScope back handler SHALL NOT trust `canGoBack()` for determining back navigation capability. It SHALL use URL comparison as the authoritative check.

**Rationale:** `canGoBack()` can return `false` for `history.pushState()` entries on iOS. Trusting it would prevent back navigation in SPAs.

#### Scenario: SPA with pushState history

**Given** a single-page app has navigated via `history.pushState()`
**And** `canGoBack()` returns `false`
**When** the user triggers the system back gesture
**Then** `goBack()` is called regardless
**And** the URL is compared before/after with a 150ms delay
**And** if the URL changed, back navigation succeeded
**And** if the URL did NOT change, the drawer opens as fallback

---

### Requirement: NAV-003 - iOS Drawer Edge Swipe

On iOS, the drawer edge swipe SHALL be enabled when the active webview has no back history, and disabled otherwise.

On Android, the drawer edge swipe SHALL always be disabled when a webview is active (the hardware back button provides fallback navigation).

#### Scenario: iOS webview with no back history

**Given** a webview is visible on iOS
**And** `_canGoBack` is `false`
**When** the user swipes from the left edge
**Then** the drawer opens

#### Scenario: iOS webview with back history

**Given** a webview is visible on iOS
**And** `_canGoBack` is `true`
**When** the user swipes from the left edge
**Then** nothing happens (gesture is consumed by the disabled drag zone)

#### Scenario: No webview visible

**Given** the webspace list is shown
**When** the user swipes from the left edge
**Then** the drawer opens (on all platforms)

---

### Requirement: NAV-004 - Home Button Clears History

The Home button SHALL navigate to the site's initial URL AND clear all navigation history, so `canGoBack()` returns `false` immediately afterward.

**Rationale:** Simply loading the initial URL via `loadUrl()` preserves back history, causing `canGoBack()` to return `true` even though the user is "home." This breaks the iOS drawer swipe (NAV-003).

#### Scenario: Press Home from a deep page

**Given** a user has navigated several pages deep
**When** the user presses the Home button
**Then** the webview is disposed and recreated fresh at the initial URL
**And** `_canGoBack` is immediately set to `false`
**And** any in-flight `_updateCanGoBack` calls are invalidated
**And** on iOS, the drawer edge swipe is immediately enabled

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

## Race Condition Guards

### Guard: RACE-001 - _canGoBackVersion Counter

**Problem:** `_updateCanGoBack()` calls `await controller.canGoBack()` (async native IPC). During the await, `_goHome()` or `_setCurrentIndex()` may set `_canGoBack = false`. When the stale IPC result returns `true`, it overwrites the correct `false`.

**Solution:** Version counter `_canGoBackVersion` is incremented:
- At the start of each `_updateCanGoBack()` call
- When `_goHome()` resets state
- When `_setCurrentIndex()` switches sites
- When the PopScope handler detects landing on the home URL

After the `await`, the result is discarded if `version != _canGoBackVersion`.

```
_updateCanGoBack() called         _goHome() called
  version = ++counter (v=1)         counter++ (v=2)
  await canGoBack()                 _canGoBack = false  [correct]
  ... IPC resolves true ...
  version(1) != counter(2) → DISCARD
```

### Guard: RACE-005 - Home URL Synchronous Fast-Path

**Problem:** After `goBack()` lands on the site's home URL, `_canGoBack` must become `false` to enable the iOS drawer edge swipe. But `_updateCanGoBack()` is async — it calls `await canGoBack()` which takes indeterminate time. Meanwhile, `onLoadStop` or `onUpdateVisitedHistory` callbacks can fire and start *new* `_updateCanGoBack()` calls whose version counters post-date the PopScope handler's bump, making the version guard (RACE-001) ineffective against them.

**Solution:** `_updateCanGoBack()` checks `currentUrl` against `initUrl` *synchronously* before the async `canGoBack()` call (using `_isHomeUrl()` which normalizes trailing slashes). When at the home URL, `_canGoBack` is set to `false` immediately and the async path is skipped entirely, eliminating the race window.

Additionally, the PopScope handler performs the same check right after a successful `goBack()` to cover the window before `onUrlChanged` fires.

**Note:** URL comparison uses `_isHomeUrl()` which strips trailing slashes, since webviews normalize `https://example.com` to `https://example.com/`.

### Guard: RACE-002 - _isBackHandling Flag

**Problem:** The PopScope `onPopInvokedWithResult` handler is async. Rapid back gestures could invoke it concurrently, causing double navigation or drawer flash.

**Solution:** Boolean `_isBackHandling` flag drops concurrent invocations. Cleared in a `finally` block to guarantee cleanup.

### Guard: RACE-003 - _setCurrentIndexVersion Counter

**Problem:** `_setCurrentIndex()` performs multiple async operations (cookie capture, domain conflict resolution, cookie restoration). Rapid site switching could interleave these operations.

**Solution:** Version counter `_setCurrentIndexVersion` is checked after each `await` gap. If the version changed (another `_setCurrentIndex` call started), the stale call returns early.

### Guard: RACE-004 - _goHome() Synchronous Execution

**Problem:** If `_goHome()` were async, rapid taps could interleave with webview recreation.

**Solution:** `_goHome()` is fully synchronous. It completes in a single microtask:
1. Drops the site's cached HTML via `HtmlCacheService.deleteCache(siteId)` so the next load starts from the live page instead of a stale snapshot (the cached frame could otherwise flash with pre-edit content or mismatched theme before user scripts re-run)
2. Resets `currentUrl` to `initUrl`
3. Disposes webview (`webview = null`, `controller = null`)
4. Bumps `_canGoBackVersion`
5. Sets `_canGoBack = false` via `setState`
6. Saves state (fire-and-forget async, but idempotent)

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
  ├─ Drawer open?
  │   ├─ Android? ─────────────── exit app (SystemNavigator.pop)
  │   └─ Other? ───────────────── close drawer
  │
  ├─ Android && no webview? ───── open drawer (exit warning)
  │
  ├─ No controller? ───────────── open drawer
  │
  └─ Has controller:
      ├─ urlBefore = getUrl()
      ├─ goBack()
      ├─ wait 150ms
      ├─ urlAfter = getUrl()
      │
      ├─ URL changed? ─────────── back succeeded
      │   └─ (iOS) at home URL? ── _canGoBack=false (enable drawer swipe)
      └─ URL same? ────────────── open drawer (fallback)
```

### Decision Flow: Drawer Edge Drag Width

```
Build Scaffold
  │
  ├─ No webview visible? ──────── null (default, swipeable)
  │
  └─ Webview visible:
      ├─ iOS && !_canGoBack? ──── null (swipeable, no history to conflict with)
      └─ Otherwise ────────────── 0 (disabled)
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
      ├─ _canGoBackVersion++       ← invalidate in-flight checks
      ├─ setState(_canGoBack=false) ← immediate drawer enable on iOS
      └─ _saveWebViewModels()      ← persist reset URL
      
      Next frame: getWebView() sees webview==null
        → creates fresh webview with UniqueKey
        → loads initUrl with zero history
```

### Files

#### `lib/main.dart`
- `_canGoBack` — iOS-only state: whether current webview has back history
- `_canGoBackVersion` — version counter guarding `_updateCanGoBack`
- `_isBackHandling` — boolean guard for PopScope handler
- `_isHomeUrl()` — static helper: compares URLs ignoring trailing slash normalization
- `_updateCanGoBack()` — async check of `controller.canGoBack()` with version guard and synchronous home-URL fast-path (RACE-005)
- `_goHome()` — synchronous: dispose webview, reset URL, invalidate version
- `PopScope` widget — wraps Scaffold; `canPop: false` always on Android (two-step exit), `!webviewIsVisible` on other platforms; handles system back gesture with URL comparison
- `drawerEdgeDragWidth` — conditional drawer edge swipe based on platform and `_canGoBack`
- Back button `IconButton` (portrait ~line 1685, landscape ~line 2047)
- Home button `IconButton` (portrait ~line 1701, landscape ~line 2063)

#### `lib/web_view_model.dart`
- `stateSetterF` callback — injected closure that calls `setState` + `_updateCanGoBack()`
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
5. When at the initial URL, verify back opens the drawer

### Manual Test: Android Two-Step Exit (Webview)

1. (Android) Add a site and navigate to its initial URL
2. Press system back — verify the drawer opens
3. Press system back again — verify the app exits/minimizes

### Manual Test: Android Two-Step Exit (Homepage)

1. (Android) Go to the webspace list (no webview selected)
2. Press system back — verify the drawer opens
3. Press system back again — verify the app exits/minimizes

### Manual Test: Home Button Clears History

1. Navigate to several pages deep in a site
2. Open the menu and press the Home button
3. Verify the site returns to its initial URL
4. Press system back — verify the drawer opens (no back history)
5. (iOS) Swipe from left edge — verify the drawer opens

### Manual Test: iOS Drawer Swipe After Back Navigation

1. (iOS) Start at a site's home URL
2. Navigate to a second page
3. Swipe back (system back gesture) to return to the home URL
4. Immediately swipe from the left edge — verify the drawer opens (no delay needed; home URL fast-path in `_updateCanGoBack` enables drawer synchronously)

### Manual Test: Rapid Home Tap (Race Condition)

1. Navigate to a deep page
2. Open the menu and rapidly double-tap the Home button
3. Verify the site returns to its initial URL without errors
4. Verify `_canGoBack` is `false` (drawer swipeable on iOS)

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
