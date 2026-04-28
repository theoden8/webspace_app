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
