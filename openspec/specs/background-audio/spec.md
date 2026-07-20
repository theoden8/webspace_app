# Background Audio Specification

## Status
**Implemented**

## Purpose

Per-site `backgroundAudioEnabled` toggle that keeps a site's audio playing
when the site loses the screen — on a site switch inside the app, and when
the whole app goes to background. Intended for music, radio and podcast
sites (the user question that motivated it: "can you play audio in the
background with your app?").

## Problem Statement

Two lifecycle mechanisms silence a playing site (see
[webview-pause-lifecycle](../webview-pause-lifecycle/spec.md)):

1. **Site switch**: `pauseWebView()` on iOS is the plugin's `pauseTimers()`
   alert-deadlock hack — it blocks the page's main JS thread. A simple
   `<audio src=mp3>` decoder survives (decoding is off-thread), but every
   streaming player (MSE — YouTube Music, SoundCloud, most radio sites)
   needs JS to keep feeding buffers and stalls within seconds.
2. **App background**: `pauseForAppLifecycle()` freezes JS timers — on
   Android via the **process-global** `pauseTimers()`, so every loaded
   webview is affected, not just the active one. Additionally on iOS the OS
   suspends the whole app shortly after backgrounding unless it has an
   active `.playback` audio session and the `audio` background mode.

Pausing was never the thing keeping audio *playing* — media pipelines run
independently of the JS thread (see "Pause Is Not a Security Boundary" in
the pause spec) — but frozen JS starves streaming players, and on iOS the
missing audio session gets the process suspended outright.

## Requirements

### Requirement: BGAUDIO-001 — Site Switch Never Pauses a Background-Audio Site

`WebViewModel.pauseWebView()` SHALL be a no-op for a site whose
`effectiveBackgroundAudioEnabled` is true, mirroring the notification-site
exemption. Archive-tier sites are excluded by the effective getter
(ARCH-006): audio audibly playing while the app looks idle — and the site
surfacing in the OS now-playing UI — would reveal an open archive.

#### Scenario: Music keeps playing across a site switch

**Given** site A has `backgroundAudioEnabled` and is playing audio
**When** the user switches to site B
**Then** `pauseWebView()` early-returns for A — no `pause()` reaches the controller
**And** A's JS thread keeps feeding its player; audio continues

#### Scenario: Archive-tier site is still paused

**Given** an archive-tier site with `backgroundAudioEnabled` stored true
**When** `pauseWebView()` runs on it
**Then** the per-instance pause is issued as for any ordinary site
(regression test: `test/webview_pause_lifecycle_test.dart`)

---

### Requirement: BGAUDIO-002 — App Background Skips the Global JS Pause While a Background-Audio Site Is Loaded

`AppLifecycleEngine.backgroundPlan` SHALL return `jsPauseIndex: null` when
ANY loaded site has `effectiveBackgroundAudioEnabled` — not only when the
active site does. On Android the app-lifecycle JS pause is process-global,
so pausing the active site would also starve a backgrounded audio site's
player. On iOS the pause is per-instance; skipping it merely leaves the
active site running too — an accepted battery cost for one decision that
behaves the same on both platforms. `resumeJsIndex` SHALL mirror the
decision (nothing was paused, nothing to resume); state capture
(`captureStateIndex`) is NOT gated on the exemption.

The `paused` branch of `didChangeAppLifecycleState` SHALL log one
non-sensitive decision line (`App background: jsPause=<bool>
capture=<bool>`, no site name or URL) so a user report — and the CI
lifecycle test — can tell whether the background froze JS or an exemption
kept it running.

#### Scenario: Active audio site backgrounds unpaused

**Given** the active site has `backgroundAudioEnabled`
**When** the app goes to background
**Then** the plan carries no `jsPauseIndex` and the decision line reads `jsPause=false`
**And** state capture still runs for the active site

#### Scenario: Loaded background audio site vetoes the pause of a plain active site

**Given** plain site A is active and audio site B (`backgroundAudioEnabled`) is loaded in the background
**When** the app goes to background
**Then** no JS pause is issued
**Because** Android's `pauseTimers()` is process-global — pausing A would freeze B's player

#### Scenario: Unloaded audio site does not veto

**Given** plain site A is active and audio site B is NOT loaded
**When** the app goes to background
**Then** the plan pauses A as usual (`jsPause=true`)

---

### Requirement: BGAUDIO-003 — iOS Playback Audio Session and Background Mode

On iOS the app SHALL declare the `audio` `UIBackgroundModes` entry, and
SHALL hold the shared `AVAudioSession` in the `.playback` category while
any loaded site has `effectiveBackgroundAudioEnabled` (reverting to
`.ambient` when none does). `.playback` plus the background mode is what
lets WKWebView media keep running after the app leaves the foreground;
`.ambient` restores the respect-the-silent-switch default so ordinary
sites don't sound through a muted phone. Only the category is set — the
session is not force-activated, so the app never steals audio focus while
nothing is playing.

Sync points (all idempotent, routed through
`BackgroundTaskService.setBackgroundAudioActive`): per-site settings save,
site activation tail (`_setCurrentIndex`), site deletion GC, and the
lifecycle `paused` branch.

#### Scenario: Toggling the setting on prepares the audio session

**Given** the user enables Background audio for a loaded site on iOS
**When** the settings screen saves
**Then** `setBackgroundAudioActive(true)` sets the `.playback` category
**And** backgrounding the app during playback keeps the audio running

#### Scenario: Deleting the last background-audio site restores ambient

**Given** the only background-audio site is deleted
**When** the deletion GC runs
**Then** the category reverts to `.ambient`

---

### Requirement: BGAUDIO-004 — Retention Priority

Background-audio sites SHALL share the `notification` retention tier in
`SiteRetentionPriority`: both exist to keep running while other sites take
the screen, so under memory pressure and LRU eviction they are evicted
only after every ordinary non-active site is gone. (The formal model
[formal/retention.tla](../../../formal/retention.tla) abstracts the tier
as a per-site retained flag; no model change is required.)

#### Scenario: Audio site outlives ordinary sites under pressure

**Given** an audio site and several ordinary sites are loaded in the background
**When** memory pressure evicts sites one by one
**Then** every ordinary non-active site is promoted before the audio site

---

### Requirement: BGAUDIO-005 — CI-Testable Background Mode

The repository SHALL carry an integration test
(`integration_test/background_audio_lifecycle_test.dart`) that exercises
the background path on the real engine in CI (Linux WPE + macOS jobs),
without OS-level backgrounding:

- Lifecycle transitions are injected via
  `tester.binding.handleAppLifecycleStateChanged` (which synthesizes the
  legal intermediate states).
- The HTML fixture
  ([integration_test/fixtures/background_audio.html](../../../integration_test/fixtures/background_audio.html))
  beacons `GET /beacon?ticks=N&audio=<playState>` to the test's loopback
  server every 250 ms from a JS interval, so page-JS liveness is observed
  server-side with no bridge into the app's widget tree.
- The BGAUDIO-002 decision line is asserted from `LogService`.

The "JS actually freezes for a non-exempt site" direction is NOT asserted:
the Linux and macOS plugins implement no `pauseTimers()`, so it only holds
on Android/iOS hardware. The decision matrix is covered by
`test/app_lifecycle_engine_test.dart`.

#### Scenario: Exempt site stays live through an injected background window

**Given** the fixture site with `backgroundAudioEnabled` is active and beaconing
**When** the test injects `AppLifecycleState.paused`, waits 3 s of wall-clock, then injects `resumed`
**Then** the decision line reads `jsPause=false capture=true`
**And** beacons keep arriving throughout the window with monotonically increasing ticks (same live page, never reloaded)

## Limitations (documented, accepted)

- **Android process death**: no foreground media service is used (Play
  review posture matches the notifications feature). Audio keeps playing
  while the process lives; if the OS kills the app under pressure the
  audio stops. The retention tier and the OS's own reluctance to kill
  audio-playing processes mitigate this.
- **iOS without playback**: the audio session keeps the app alive only
  while audio is actually playing; a paused player suspends with the app
  as usual.
- The exemption trades battery for playback: an enabled site's JS runs
  whenever it is loaded. The toggle is per-site and off by default.

## Files

### Modified

- `lib/web_view_model.dart` — `backgroundAudioEnabled` field (+`effective*`
  getter, toJson/fromJson), `pauseWebView()` early-return.
- `lib/services/app_lifecycle_engine.dart` — `anyLoadedBackgroundAudio`,
  plan/resume gating.
- `lib/main.dart` — engine callbacks, decision log line, retention tier,
  `_updateBackgroundAudioSession` sync points.
- `lib/services/background_task_service.dart` — `setBackgroundAudioActive`.
- `ios/Runner/BackgroundTaskPlugin.swift`, `ios/Runner/Info.plist` —
  AVAudioSession category switch, `audio` background mode.
- `lib/screens/settings.dart` — per-site toggle.
- `lib/services/site_settings_qr_codec.dart` — QR-shareable key.

### Added

- `openspec/specs/background-audio/spec.md` — this document.
- `integration_test/background_audio_lifecycle_test.dart` +
  `integration_test/fixtures/background_audio.html`.

## Related Specs

- [`webview-pause-lifecycle`](../webview-pause-lifecycle/spec.md) — the
  pause machinery this feature carves exemptions out of (PAUSE-001,
  PAUSE-002).
- [`archive`](../archive/spec.md) — ARCH-006 audit: the effective getter
  forces the exemption off for archive-tier sites.
- [`integration-tests`](../integration-tests/spec.md) — harness
  conventions the CI test follows.
