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
capture=<bool> bgAudio=<count> loaded`, no site name or URL) so a user
report — and the CI lifecycle test — can tell whether the background froze
JS or an exemption kept it running. The count is the decision's input: a
`jsPause=true` line reads as a broken exemption until it says that zero
background-audio sites were loaded.

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
**And** the decision line reads `bgAudio=0 loaded`, naming the reason

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
  beacons `GET /beacon?ticks=N&audio=<playState>&t=<currentTime>&paused=<bool>`
  to the test's loopback server every 250 ms from a JS interval, so page-JS
  liveness is observed server-side with no bridge into the app's widget tree.
  The server serves the embedded mirror `background_audio_fixture.dart` — the
  sandboxed test app cannot read repo files at runtime (macOS CI denies with
  EPERM) — and `test/background_audio_fixture_drift_test.dart` pins mirror and
  .html byte-identical.
- `?media=` selects what the fixture plays: `none` (default; WPE in the
  headless CI container crash-loops its web process on media-pipeline init),
  `audio` (looping silent WAV), `stream` (muted `<video>` off a canvas
  `captureStream`, which needs no audio device — the CI emulator boots
  `-noaudio`). The liveness tests use `none`; BGAUDIO-007's notification tier
  uses `stream`.
- The BGAUDIO-002 decision line is asserted from `LogService`.

Both directions are covered, on the platforms where each is observable:

- **Exempt direction** (`background_audio_lifecycle_test.dart`): runs on the
  Linux/WPE + macOS per-file loops and on the Android emulator. Asserts
  `jsPause=false` and that beacons keep arriving through the backgrounded
  window with monotonically increasing ticks.
- **Negative control** (`background_audio_freeze_test.dart`): a plain site
  with no exemption. The universal assertion `jsPause=true` holds everywhere;
  the observable freeze (beacons stop) is asserted **only on Android/iOS**,
  because Linux/WPE and macOS implement no `pauseTimers()` and the JS keeps
  ticking there. The Android emulator tier
  (`scripts/run_android_background_audio_tests.sh`, wired into the
  ungated emulator job) is what makes the freeze provable against a real
  WebView — the direction the pure-Dart `test/app_lifecycle_engine_test.dart`
  decision tests cannot exercise.

#### Scenario: Exempt site stays live through an injected background window

**Given** the fixture site with `backgroundAudioEnabled` is active and beaconing
**When** the test injects `AppLifecycleState.paused`, waits 3 s of wall-clock, then injects `resumed`
**Then** the decision line reads `jsPause=false capture=true`
**And** beacons keep arriving throughout the window with monotonically increasing ticks (same live page, never reloaded)

#### Scenario: Plain site's JS freezes on Android background

**Given** a plain site (no background audio) is active and beaconing on the Android emulator
**When** the test injects `AppLifecycleState.paused`
**Then** the decision line reads `jsPause=true`
**And** after a 1 s drain the beacons stop for a 2 s window (real `pauseTimers()` froze the JS timers)
**And** injecting `resumed` thaws the timers and beacons flow again

### Requirement: BGAUDIO-006 — Android Media Notification and Foreground Service

On Android the system SHALL run a `mediaPlayback` foreground service with a
`MediaStyle` notification (title/artist/artwork + a play/pause control) while
a background-audio site is actively playing, so playback survives the OS
suspending the app and the user gets lockscreen/notification transport
controls. Media playback is a Play-accepted foreground-service type (unlike
`FOREGROUND_SERVICE_SPECIAL_USE`, which the notifications feature found
intractable), so this does not carry the notification feature's review
constraints.

- A page-JS shim on background-audio sites
  ([media_session_shim.dart](../../../lib/services/media_session_shim.dart),
  Android + `backgroundAudioEnabled` only) observes every `<audio>`/`<video>`
  element plus `navigator.mediaSession.metadata` and reports
  `{playing, title, artist, album, artwork}` to Dart through the
  `wsMediaSession` handler. "Every element" includes ones that never enter the
  document: `new Audio(src).play()` is a common playback idiom and
  `querySelectorAll` cannot see it, so the `HTMLMediaElement.prototype.play`
  patch registers detached elements in a bounded list that the scan unions in.
- [`MediaSessionService`](../../../lib/services/media_session_service.dart)
  raises (`start`) / refreshes (`update`) / tears down (`stop`) the
  notification via the `org.codeberg.theoden8.webspace/media_session` channel.
  The native service ([`MediaPlaybackService.kt`](../../../android/app/src/main/kotlin/org/codeberg/theoden8/webspace/MediaPlaybackService.kt))
  owns a `MediaSession` and calls `startForeground(..., FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)`.
- Transport controls (notification button, lockscreen, Bluetooth/headset
  media keys) travel back as `onTransport` and are applied by running
  `window.__wsMediaControl(action)` on the owning webview, which drives its
  primary media element (so the site's own MediaSession stays in sync).
- The notification exposes **play/pause/stop only** — next/previous have no
  universal web mechanism, so dead buttons are deliberately omitted.
- The service runs only while a background-audio site is loaded and playing;
  when the last such site unloads, `_updateBackgroundAudioSession` calls
  `stopAll`. Enabling the toggle requests `POST_NOTIFICATIONS` so the media
  controls are visible on Android 13+.
- Scope: the media notification is driven by the **root** site webview. A
  cross-domain nested `InAppWebViewScreen` does not raise it (acceptable
  degradation — background audio is not a privacy posture, so the
  nested-webview threading rule does not apply).

#### Scenario: Background-audio site playing shows a media notification

**Given** a site has Background audio enabled and is playing audio on Android
**When** the page reports `playing: true` through `wsMediaSession`
**Then** a `mediaPlayback` foreground service starts with a `MediaStyle`
notification carrying the title/artist and a pause control
**And** backgrounding the app keeps the audio playing

#### Scenario: Notification pause drives the page

**Given** the media notification is showing for a playing site
**When** the user taps pause (or uses a Bluetooth media key)
**Then** `onTransport('pause')` runs `window.__wsMediaControl('pause')`, which
pauses the page's media element
**And** the page reports `playing: false`, flipping the notification to a
resumable paused state

#### Scenario: Last background-audio site unloads tears the notification down

**Given** the media notification is showing
**When** the only background-audio site is unloaded or its toggle is turned off
**Then** `_updateBackgroundAudioSession` finds no loaded background-audio site
and calls `MediaSessionService.stopAll`, stopping the foreground service

#### Scenario: A player that never enters the DOM still raises the notification

**Given** a background-audio site plays through `new Audio(src).play()` without
appending the element
**When** the shim's scan runs
**Then** the element is included via the detached registry and reported
`playing: true`
(regression test: `test/browser/media_session_real_engine.test.js`)

---

### Requirement: BGAUDIO-007 — The Media Notification Is Observable End to End

Every link between the page's playback and the notification on screen SHALL be
assertable, and the terminal observable SHALL be the OS's own notification
list — not a Dart-side flag. A foreground service that started while the OS
suppressed its notification (a denied `POST_NOTIFICATIONS`) is
indistinguishable from success at every layer above the platform channel, and
that is the failure mode this requirement exists to make visible.

- `MediaSessionService` SHALL log one non-sensitive line on raise and on
  teardown (no site name, URL or track metadata), so a user's App Logs export
  says whether the bridge fired.
- Injecting the shim SHALL log one non-sensitive line (`Bridge armed for this
  site`). The chain's first link is the site's own toggle, and no downstream
  line can distinguish "Background audio is off for this site" from "the
  bridge is broken" — both are silence. The armed line makes that the one
  question an App Logs export always answers.
- The `media_session` channel SHALL expose `isNotificationActive`, answered
  from `NotificationManager.getActiveNotifications()`, and
  `MediaSessionService.notificationPosted()` SHALL surface it.
- On raising the notification the service SHALL check visibility once and log a
  warning when the OS did not post it.
- Coverage SHALL exist at three tiers, because no single one spans the chain:
  the shim's behaviour under a real engine
  (`test/browser/media_session_real_engine.test.js`, Puppeteer + headless
  Chromium — jsdom has no media pipeline, so `paused`/`currentTime` never move
  there); the channel contract and its guards
  (`test/media_session_service_test.dart`); and the notification itself on a
  real Android WebView
  (`integration_test/background_audio_media_notification_test.dart`, run by
  `scripts/run_android_background_audio_tests.sh`, which pre-grants
  `POST_NOTIFICATIONS` so the tier measures the feature and not the dialog).

#### Scenario: The notification reaches the OS notification list

**Given** a background-audio site is playing in the Android emulator tier
**When** the shim reports `playing: true`
**Then** `MediaSessionService` logs `Notification raised`
**And** `notificationPosted()` returns true — the notification is in
`getActiveNotifications()`
**And** it is still posted after an injected `AppLifecycleState.paused`

#### Scenario: A suppressed notification is not silent

**Given** the foreground service started but the OS did not post its
notification
**When** the post-raise visibility check runs
**Then** a warning naming the likely denied notification permission is logged
(regression test: `test/media_session_service_test.dart`)

#### Scenario: Teardown removes it from the OS, not just from Dart

**Given** the media notification is posted
**When** `stopAll` runs
**Then** `notificationPosted()` returns false

#### Scenario: A site with the toggle off is diagnosable from the log alone

**Given** a user reports no media notification after playing a video
**When** their App Logs export carries no `MediaSession`/`Bridge armed` line
**Then** the site's Background audio toggle was off — the shim was never
injected, so no report could ever arrive
**And** the `Lifecycle`/`App background: ... bgAudio=0 loaded` line agrees

---

### Requirement: BGAUDIO-008 — Only the Playing Frame Speaks for the Site

The shim is injected with `forMainFrameOnly: false`, so every frame of the
site runs a copy against the single `wsMediaSession` handler. Reports SHALL
therefore be frame-scoped:

- The shim SHALL mint one opaque token per frame and send it as `frame` in
  every report.
- A frame that has never held an `<audio>`/`<video>` element (its own or a
  detached one) SHALL NOT report at all. An ad / analytics / comments iframe
  has nothing to say about playback.
- `MediaSessionService` SHALL record the reporting frame on every
  `playing: true` and SHALL accept `playing: false` only from that same
  frame of that same site. Ownership moves with playback: a report of
  `playing: true` from another frame makes that frame the owner.

Without this, a site whose player sits in the main frame is silenced by its
own subframes: the ad iframe reports `playing: false` for the same `siteId`
within one debounce of the notification going up, flipping it to a paused,
`setOngoing(false)` — dismissible — state while audio is still playing, and
the main frame's report deduplication keeps it from correcting the record.

The transport controls remain main-frame-only: `evaluateJavascript` targets
the main frame, so a player inside a subframe raises the notification but its
play/pause buttons do not reach the element. Accepted degradation.

#### Scenario: An ad iframe cannot pause the notification

**Given** a background-audio site is playing in its main frame and the
notification is up
**When** a media-less iframe of the same site reports
**Then** nothing is sent — the frame is silent because it never held media
(regression test: `test/browser/media_session_real_engine.test.js`)
**And** even if it did report `playing: false`, the frame guard would drop it
(regression test: `test/media_session_service_test.dart`)

#### Scenario: Playback moving between frames transfers ownership

**Given** the main frame raised the notification
**When** a subframe reports `playing: true`
**Then** the subframe becomes the owner and its later `playing: false` is
honored

## Limitations (documented, accepted)

- **iOS without playback**: the audio session keeps the app alive only
  while audio is actually playing; a paused player suspends with the app
  as usual. iOS surfaces its own Now Playing controls from the page's
  MediaSession — the Android media service (BGAUDIO-006) is not mirrored
  there.
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
- `lib/screens/settings.dart` — per-site toggle (+ POST_NOTIFICATIONS request).
- `lib/services/site_settings_qr_codec.dart` — QR-shareable key.
- `lib/services/webview.dart` — `WebViewConfig.backgroundAudioEnabled`, media
  shim injection (+ the BGAUDIO-007 armed line), `wsMediaSession` handler.
- `lib/services/media_session_shim.dart`, `lib/services/media_session_service.dart`
  — BGAUDIO-006 page-JS bridge + Dart channel bridge; BGAUDIO-007 detached-
  element registry, raise/teardown logging and the visibility check;
  BGAUDIO-008 per-frame token and media-less-frame silence.
- `android/app/src/main/kotlin/.../MediaPlaybackService.kt`,
  `.../MediaSessionPlugin.kt`, `MainActivity.kt`, `AndroidManifest.xml` —
  BGAUDIO-006 foreground media service + permissions; BGAUDIO-007
  `isNotificationActive`.
- `tool/dump_shim_js.dart` + `test/js_fixtures/media_session/shim.js` — the
  media-session shim joins the dumped-fixture pipeline so the browser tier
  runs the exact injected string.

### Added

- `openspec/specs/background-audio/spec.md` — this document.
- `integration_test/background_audio_lifecycle_test.dart` (exempt direction),
  `integration_test/background_audio_freeze_test.dart` (negative control),
  `integration_test/background_audio_media_notification_test.dart` (BGAUDIO-007
  notification tier) + `integration_test/fixtures/background_audio.html`.
- `test/media_session_service_test.dart`,
  `test/browser/media_session_real_engine.test.js` — BGAUDIO-007 channel and
  real-engine tiers.
- `scripts/run_android_background_audio_tests.sh` + the Android emulator CI
  wiring in `.github/workflows/build-and-test.yml`.

## Related Specs

- [`webview-pause-lifecycle`](../webview-pause-lifecycle/spec.md) — the
  pause machinery this feature carves exemptions out of (PAUSE-001,
  PAUSE-002).
- [`archive`](../archive/spec.md) — ARCH-006 audit: the effective getter
  forces the exemption off for archive-tier sites.
- [`integration-tests`](../integration-tests/spec.md) — harness
  conventions the CI test follows.
