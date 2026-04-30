# WebView Pause Lifecycle Specification

## Status
**Implemented**

## Purpose

Defines how the app pauses and resumes webviews to save resources. The split between **per-instance** pause (used on site switch) and **process-global** pause (used on app lifecycle) is load-bearing: one of them is global on Android and would freeze unrelated webviews if used at the wrong call site.

## Problem Statement

`flutter_inappwebview` exposes two pause primitives that look interchangeable but are not:

| Primitive | Android scope | iOS scope | What it pauses |
|---|---|---|---|
| `WebView.onPause()` | per-instance | n/a | best-effort: animations, geolocation. **Does not pause JavaScript.** |
| `WebView.pauseTimers()` | **process-global** | per-instance (alert() hack) | layout, parsing, JS timers (`setTimeout`/`setInterval`/`requestAnimationFrame`) |

Source: Android docs verbatim — *"`onPause()` ... does not pause JavaScript. To pause JavaScript globally, use `pauseTimers`."* and *"`pauseTimers()` ... is a global request, not restricted to just this WebView."* On iOS the plugin implements `pauseTimers()` by triggering an `alert()` whose dismissal callback is withheld by the plugin's `WKUIDelegate`, blocking the page's main JS thread.

Pre-fix the wrapper called `pauseTimers()` from every per-instance `pause()`, so a site-switch pause toggled the **global** Android flag for every loaded webview, and the matching resume toggled it back. Net effect on a site switch was zero useful pausing of the backgrounded site, plus a stutter on the active one.

## Crucial Caveat: Pause Is Not a Security Boundary

A paused webview can still:

- run **Web Workers** and **Service Workers** (separate threads/processes)
- complete **network requests already in flight** — including processing `Set-Cookie` response headers
- continue **media playback** (`<video>`/`<audio>` decoders, `currentTime` keeps advancing)
- run **WebRTC** peer connections; receive **WebSocket** frames over the wire

Therefore, pausing a webview does **not** make it safe to mutate cookies or proxy under it. The page can detect such mutations via:

- Service Worker `fetch` interception
- Web Worker periodic XHR/fetch with cookie-bearing requests
- `document.cookie` diff across `visibilitychange`
- WebRTC ICE re-gather on Android proxy swap
- media `currentTime` discontinuities

The only way to truly silence a site is `disposeWebView()` — which tears down the JS engine, network sessions, workers, and media pipelines for that page.

## Requirements

### Requirement: PAUSE-001 — Per-Instance Pause for Site Switches

The system SHALL pause the previously active webview on site switch using the per-instance API only, with no process-global side effects.

#### Scenario: Site switch from A to B

**Given** sites A and B are both loaded
**And** site A is the currently active site
**When** the user switches to site B
**Then** `pauseWebView()` is called on A
**And** A's controller receives `pause()` (Android: `WebView.onPause()`; iOS: per-instance `pauseTimers()` alert hack)
**And** A's controller does NOT receive `pauseAllJsTimers()`
**And** B's JS timers are unaffected by A's pause

#### Scenario: Sites loaded but never previously active also get paused

**Given** sites A, B, C are all loaded under container mode (which lets sites stay
  resident across webspace switches)
**And** the user activates site B
**When** the activation completes
**Then** `pauseWebView()` is called on every loaded site that is NOT B
**Because** steady state should already have them paused (each becomes paused
  when it last lost active status), but a pause-all-inactive sweep guarantees
  consistency even if a path adds to `_loadedIndices` without going through
  the previous-active pause. `pauseWebView()` is idempotent — already-paused
  or disposed-controller sites no-op.

The sweep uses `unawaited` so subsequent activation logic doesn't block on it.
This is race-safe because Dart's platform channel preserves FIFO order: the
`resume()` for the new active site is dispatched before the loop's `pause()`
calls, so the active site is never left paused.

---

### Requirement: PAUSE-002 — Process-Global Pause Only at App Lifecycle

The system SHALL pause both the active webview and process-global JS timers when the app goes to background, so every loaded webview's JS halts.

#### Scenario: App goes to background

**Given** the app is in the foreground with N loaded webviews
**When** `AppLifecycleState.paused` (or `inactive`) fires
**Then** `pauseForAppLifecycle()` is called on the active webview
**And** the controller receives `pause()` followed by `pauseAllJsTimers()`
**And** every loaded webview's JS timers are now frozen (Android: globally; iOS: pauseTimers is per-instance, so only the active webview is timer-paused — acceptable since the OS suspends the rest)

#### Scenario: App returns to foreground

**Given** the app was backgrounded via `pauseForAppLifecycle`
**When** `AppLifecycleState.resumed` fires
**Then** `_resumeAfterLifecyclePause()` awaits the pending pause Future to prevent ordering inversion
**And** `resumeFromAppLifecycle()` is called on the active webview
**And** the controller receives `resume()` followed by `resumeAllJsTimers()`

---

### Requirement: PAUSE-003 — API Separation Is Documented at the Type Level

The `WebViewController` interface SHALL expose `pause()`/`resume()` and `pauseAllJsTimers()`/`resumeAllJsTimers()` as distinct methods with doc comments stating which is per-instance and which is process-global.

#### Scenario: Future contributor reads the interface

**Given** a contributor adds a new pause call site
**When** they read [lib/services/webview.dart:332-390](../../lib/services/webview.dart)
**Then** the doc on `pause()` plainly warns it is **not a security boundary**
**And** the doc on `pauseAllJsTimers()` plainly warns it is process-global on Android and must not be used for single-site pausing

---

### Requirement: PAUSE-005 — Cascading Memory-Pressure Lifecycle

When the OS signals memory pressure via `WidgetsBindingObserver.didHaveMemoryPressure`, the system SHALL promote one loaded site by one tier per event, cascading through three states from least to most aggressive: `live` → `cacheCleared` → `savedForRestore`.

The cascade is owned by [`SiteLifecyclePromotionEngine`](../../../lib/services/site_lifecycle_promotion_engine.dart), a pure-Dart picker that:

- Walks tiers from least to most aggressive (`live` first, then `cacheCleared`).
- Within a tier, evicts out-of-active-webspace sites before in-webspace sites.
- Within a (tier, keep) bucket, picks the LRU oldest first.
- Never picks the active site (`_currentIndex`) or the in-flight activation target (`_activationInFlightIndex`).
- Treats `savedForRestore` as terminal — those sites are no longer in `_loadedIndices`, but their state lives in [`WebViewStateStorage`](../../../lib/services/webview_state_storage.dart) keyed by `siteId`.

The OS controls the curve: if pressure persists, the callback fires again and the next victim is promoted. One-per-event matches the OS signaling cadence and avoids over-evicting on transient pressure (e.g. another app's foreground spike).

#### Scenario: First memory pressure event clears cache without losing state

**Given** the app has 5 loaded sites — one active and four backgrounded `live`
**When** `didHaveMemoryPressure` fires for the first time
**Then** the LRU oldest non-active site is promoted from `live` to `cacheCleared`
**And** `controller.clearCache()` is called on it (frees ~10-50 MB without disposing)
**And** the user's tab state, back/forward stack, and active site remain untouched

#### Scenario: Sustained pressure cascades all loaded sites through clearCache before disposing any

**Given** every loaded site is at the `live` tier
**When** `didHaveMemoryPressure` fires N times in succession (where N is the number of non-active loaded sites)
**Then** every non-active loaded site reaches `cacheCleared` before any reaches `savedForRestore`
**Because** the picker walks tiers from lowest to highest — `live` is exhausted first, regardless of LRU age within other tiers

#### Scenario: cacheCleared site disposes with state captured

**Given** every non-active loaded site is at `cacheCleared`
**When** `didHaveMemoryPressure` fires again
**Then** the LRU oldest cacheCleared site is promoted to `savedForRestore`
**And** `controller.saveState()` captures the navigation state to `WebViewStateStorage` keyed by siteId
**And** `disposeWebView()` tears down the webview (and in legacy mode, `CookieIsolationEngine.unloadSiteForDomainSwitch` captures cookies first)
**And** the site is removed from `_loadedIndices`
**Because** the cascade reaches its terminal tier — the renderer process is torn down (~100s MB freed); state is preserved for re-activation

#### Scenario: Re-activating a savedForRestore site rehydrates the back/forward stack

**Given** site A is in `savedForRestore` (disposed, but its bytes are in `WebViewStateStorage`)
**When** the user activates site A
**Then** `_setCurrentIndex` reads the bytes from storage and queues them on the model via `schedulePendingRestoreState`
**And** the model's `lifecycleState` is reset to `live`
**And** the webview is rebuilt — `getWebView`'s `onControllerCreated` consumes the pending bytes and calls `controller.restoreState(bytes)`
**And** the back/forward stack is restored
**And** on iOS 15+ / macOS 12+, form-field values are restored too (via `WKWebView.interactionState`)

The `initialUrlRequest` (set to `currentUrl` on the model) kicks off a navigation that lands at the most-recent saved URL; on Apple, `restoreState` may trigger a brief redundant nav (acceptable for the much-better re-activation UX). Live JS heap and DOM are not preserved — re-execution starts fresh.

#### Scenario: Active webspace tier is preserved over stale workspace

**Given** the user is on webspace `Work` with sites {A, B, active=A} and webspace `Personal` has loaded site C
**When** `didHaveMemoryPressure` fires
**Then** site C (out-of-active-webspace) is promoted before site B (in-active-webspace) at every tier transition
**Because** within a tier, the picker partitions by `preferKeepIndices` (which is the active webspace) and exhausts out-of-keep first

#### Scenario: Concurrent didHaveMemoryPressure events do not double-promote

**Given** a memory pressure event is mid-flight (capturing state, awaiting `saveState()`)
**When** the OS fires `didHaveMemoryPressure` again before the first handler completes
**Then** the second invocation drops out at the `_isHandlingMemoryPressure` guard
**And** no site is double-promoted
**Because** the OS will fire again if pressure persists, and the next picker run sees the updated state map

#### Scenario: Memory pressure during re-activation does not strand state

**Given** site A is in `savedForRestore`
**And** the user has just activated A — `_setCurrentIndex` is mid-flight, awaiting `_stateStorage.loadState`
**When** `didHaveMemoryPressure` fires
**Then** the picker excludes A from the candidate iteration
**Because** `_setCurrentIndex` records its target in `_activationInFlightIndex` (set synchronously before any await), and `_handleMemoryPressure` includes that index in its hard-protected set alongside `_currentIndex`. Without the in-flight guard, mid-activation eviction would dispose A's about-to-be-built webview, leaving `restoreState` to no-op against a null controller.

### Requirement: PAUSE-006 — State Capture on All Dispose Paths

The system SHALL capture `controller.saveState()` bytes before disposing any non-incognito loaded site, regardless of which path triggered the disposal:

- LRU cap eviction in `_setCurrentIndex` (proxy mismatch + cap overflow)
- Domain-conflict unload in legacy (non-container) cookie isolation
- Webspace switch unload in legacy mode
- Memory pressure cascade `cacheCleared → savedForRestore`

Site deletion is the only path that does NOT save state — it removes the entry from `WebViewStateStorage` instead, since the site is being thrown away entirely.

#### Scenario: Webspace switch in legacy mode preserves restorable state

**Given** legacy isolation mode is active (no per-site containers)
**And** site A is loaded in webspace `Work`, the user is now switching to `Personal` which doesn't include A
**When** `_selectWebspace(Personal)` runs the unload step
**Then** A's `saveState()` bytes are captured to `WebViewStateStorage`
**And** A's webview is disposed
**And** A's `lifecycleState` becomes `savedForRestore`
**And** later switching back to `Work` and activating A re-hydrates from the stored bytes

#### Scenario: Site deletion removes state, doesn't save

**Given** site A is in `savedForRestore` with bytes in storage
**When** the user deletes A from the site list
**Then** the orphan sweep at the end of `_deleteSite` calls `_stateStorage.removeOrphans(activeSiteIds)`
**And** A's state bytes are reaped (siteId no longer in active set)

### Requirement: PAUSE-007 — Cold-Start State Storage Defaults to In-Memory

The current default `WebViewStateStorage` implementation is in-memory (`InMemoryWebViewStateStorage`). State bytes survive webspace switches, LRU evictions, and memory-pressure disposals within a single app run, but are lost on cold start. A future on-disk implementation SHALL drop in without callers changing — the abstraction is documented at the `WebViewStateStorage` interface.

#### Scenario: App restart loses captured state

**Given** site A reached `savedForRestore` during the previous session
**When** the app cold-starts
**Then** `WebViewStateStorage` is empty
**And** activating A loads from `currentUrl` as before, without `restoreState`
**Because** in-memory storage doesn't persist across runs

#### Scenario: Startup orphan sweep keeps state aligned with active sites

**Given** the previous session had state for sites {A, B, C}, and B was deleted before app exit (but the deletion's removeOrphans race didn't reach state storage in time, or the storage was disk-backed)
**When** the app starts and `_restoreAppState` runs the orphan sweep
**Then** `_stateStorage.removeOrphans({A, C})` is called
**And** any orphaned B entry is reaped

---

### Requirement: PAUSE-004 — Null-Safe Controller Access

`pauseWebView()`, `resumeWebView()`, `pauseForAppLifecycle()`, and `resumeFromAppLifecycle()` SHALL be no-ops when the underlying controller has not yet been initialized or has been disposed.

#### Scenario: Pause called before webview attaches

**Given** a `WebViewModel` whose `controller` is null (lazy loading hasn't created it yet)
**When** `pauseWebView()` is called
**Then** no exception is thrown
**And** the call returns immediately

#### Scenario: Pause called after dispose

**Given** a `WebViewModel` whose `disposeWebView()` has been called (`controller == null`)
**When** any of the four lifecycle methods is called
**Then** no exception is thrown
**And** the call returns immediately

---

### Requirement: PAUSE-005 — Site-Switch Pause Survives Race-Cancellation

The site-switch pause SHALL respect the `_setCurrentIndexVersion` race guard so a rapid switch sequence does not invert pause/resume ordering.

#### Scenario: User taps two sites in quick succession

**Given** the user is on site A
**When** they tap site B and then site C before B's switch completes
**Then** the in-flight switch to B exits via the version-mismatch check after `pauseWebView` on A
**And** the switch to C proceeds with the correct prior state
**And** A is still in a valid paused state for C's restoration to operate against

---

## Implementation

### API Surface

[lib/services/webview.dart](../../lib/services/webview.dart):

```dart
abstract class WebViewController {
  // Per-instance: site switching uses this only.
  Future<void> pause();
  Future<void> resume();

  // Process-global on Android, per-instance on iOS.
  // App-lifecycle uses this in addition to pause()/resume().
  Future<void> pauseAllJsTimers();
  Future<void> resumeAllJsTimers();
}

class _WebViewController implements WebViewController {
  @override
  Future<void> pause() async {
    if (Platform.isAndroid) {
      await _c.pause();          // WebView.onPause()
    } else if (Platform.isIOS) {
      await _c.pauseTimers();    // plugin's per-instance alert() hack
    }
  }

  @override
  Future<void> pauseAllJsTimers() => _c.pauseTimers();
  // ... resume mirrors pause ...
}
```

### Call Sites

[lib/web_view_model.dart](../../lib/web_view_model.dart):

- `pauseWebView()` / `resumeWebView()` — per-instance, used on site switch.
- `pauseForAppLifecycle()` / `resumeFromAppLifecycle()` — calls per-instance pause **then** `pauseAllJsTimers()` (and inverse on resume).

[lib/main.dart](../../lib/main.dart):

- `didChangeAppLifecycleState`: calls `pauseForAppLifecycle()` / `resumeFromAppLifecycle()`.
- `_setCurrentIndex`: calls `pauseWebView()` / `resumeWebView()`.

### Tests

[test/webview_pause_lifecycle_test.dart](../../test/webview_pause_lifecycle_test.dart) uses a recording fake `WebViewController` and asserts:

- `pauseWebView()` invokes only `pause`, never `pauseAllJsTimers`.
- `pauseForAppLifecycle()` invokes `pause` then `pauseAllJsTimers` in that order.
- A site-switch round trip never touches `*AllJsTimers`.
- A lifecycle round trip toggles each global flag exactly once.
- All four methods are no-ops when `controller == null`.

## Files

### Modified

- `lib/services/webview.dart` — split the `WebViewController` interface; `_WebViewController.pause()` no longer calls `pauseTimers()`.
- `lib/web_view_model.dart` — added `pauseForAppLifecycle()` / `resumeFromAppLifecycle()`; updated docs on `pauseWebView()` / `resumeWebView()`.
- `lib/main.dart` — `didChangeAppLifecycleState` and `_resumeAfterLifecyclePause` use the lifecycle-named methods.

### Added

- `test/webview_pause_lifecycle_test.dart` — contract tests for the API split.
- `openspec/specs/webview-pause-lifecycle/spec.md` — this document.

## Related Specs

- [`per-site-cookie-isolation`](../per-site-cookie-isolation/spec.md) — relies on `disposeWebView()` (not pause) to safely mutate the cookie jar across domain conflicts. The "pause is not a security boundary" caveat above is why.
- [`lazy-webview-loading`](../lazy-webview-loading/spec.md) — defines `_loadedIndices`, the set across which the app-lifecycle global pause takes effect.
- [`navigation`](../navigation/spec.md) — defines the `_setCurrentIndexVersion` race guard referenced by PAUSE-005.
