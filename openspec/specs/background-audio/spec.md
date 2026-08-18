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
`.ambient` when none does). `.ambient` restores the respect-the-silent-switch default so ordinary
sites don't sound through a muted phone. The category is not force-activated
here, so the app never steals audio focus while nothing is playing — but the
category alone does NOT keep playback alive: iOS suspends the process unless
the app holds an ACTIVE `.playback` session, and a suspended process is one
whose audio has stopped and whose transport controls reach nothing. Activation
is driven by actual playback, in BGAUDIO-010.

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
- A transport control the page could not act on SHALL be logged as a warning
  carrying the engine's own reason (`reportControlFailure`). Without it, "the
  play button does nothing" is silent at every layer above the page.
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
(regression test: `test/browser/media_session_frames.test.js`)
**And** even if it did report `playing: false`, the frame guard would drop it
(regression test: `test/media_session_service_test.dart`)

#### Scenario: Playback moving between frames transfers ownership

**Given** the main frame raised the notification
**When** a subframe reports `playing: true`
**Then** the subframe becomes the owner and its later `playing: false` is
honored

---

### Requirement: BGAUDIO-009 — A Site Without the Toggle Stops Sounding When It Loses the Screen

Neither pause stops media: `pauseWebView()` and `pauseForAppLifecycle()` freeze
JS timers, while the media pipeline runs independently of the JS thread (see
"Pause Is Not a Security Boundary" in the pause spec). Left alone, a site the
user never opted in for keeps playing after it loses the screen — and holds the
OS transport surface up with it, which on iOS is the app-wide Now Playing
control that the `audio` `UIBackgroundModes` entry (BGAUDIO-003) keeps alive
for every site, not just the opted-in one. That is the toggle promising the
opposite of what it does.

`WebViewModel.pauseMediaPlayback()` SHALL pause every playing media element in
the page's main frame, and SHALL early-return for a site whose
`effectiveBackgroundAudioEnabled` is true. It SHALL be dispatched wherever a
site loses the screen, always BEFORE the pause (the iOS per-instance pause
blocks the page's JS thread, so it would otherwise sit queued behind it —
the ordering constraint CAM-012 already carries):

- the previously-active site on a site switch, and on going home;
- the defensive sweep over other loaded sites at the tail of a switch;
- every index in `LifecycleBackgroundPlan.mediaPauseIndices` on app background.

`AppLifecycleEngine.backgroundPlan` SHALL populate `mediaPauseIndices` with
every loaded, in-bounds site WITHOUT background audio, ascending. Unlike the
JS-pause veto (BGAUDIO-002), the exemption here is per-site: one opted-in site
keeps its own audio, it does not license every other loaded site to keep
playing. Nothing is resumed on foreground — restarting audio the user did not
ask for is worse than leaving it paused where they can hit play.

Pausing the media is not enough on iOS: WebKit publishes its own Now Playing
info for any page that plays, and that entry outlives the audio as a control
whose play button reaches a site the app is no longer keeping alive. When no
loaded site has the toggle, `_updateBackgroundAudioSession` SHALL therefore
call `MediaSessionService.clearOsMediaSurface()`, which clears the surface
even when the app never raised it (`stopAll` alone cannot: it early-returns
because nothing of ours is active). Three things that clearing needs to
survive contact with WebKit:

- it SHALL run AFTER the media pauses complete, since WebKit republishes its
  entry while processing a pause;
- it SHALL clear twice, a short delay apart, for the republish that lands
  after the first clear anyway;
- it SHALL release the audio session (`setActive(false,
  .notifyOthersOnDeactivation)`). Clearing the metadata alone leaves an entry
  the engine repopulates; the app drops out of the OS media surface only when
  it stops holding the session. This is the ONE place that releases it — every
  other teardown keeps it, because another loaded site may still be sounding.

The snippet ([`buildMediaPauseJs`](../../../lib/services/media_session_shim.dart))
walks same-origin subframes itself, since `evaluateJavascript` reaches only
the main frame. Out of reach, and accepted: cross-origin subframes (the same
degradation as BGAUDIO-008's transport controls), and elements that never
entered the DOM (`new Audio(src).play()`) — the detached registry that catches
those lives in the media-session shim, which is injected only on sites that
have the toggle ON. It SHALL NOT re-pause an element that is already paused:
the page's own player listens for `pause` events.

#### Scenario: Ordinary site stops when the app goes to background

**Given** a site with Background audio OFF is playing audio
**When** the app goes to background
**Then** its index is in `mediaPauseIndices` and its media elements are paused
**And** `clearOsMediaSurface()` removes the Now Playing entry WebKit published,
so no transport control with a dead play button survives it
(regression test: `test/media_session_service_test.dart`)

#### Scenario: The opted-in site is untouched, its neighbours are not

**Given** audio site B (`backgroundAudioEnabled`) and plain site A are both loaded
**When** the app goes to background
**Then** `mediaPauseIndices` names A only
**And** B keeps playing (regression test: `test/app_lifecycle_engine_test.dart`)

#### Scenario: The stop works against a real media pipeline

**Given** an `<audio>` element playing in headless Chromium, plus one in a
same-origin iframe
**When** the dumped snippet is evaluated in the top frame
**Then** both report `paused === true` and their `currentTime` stops advancing
**And** evaluating it again fires no further `pause` events
(regression test: `test/browser/media_pause_real_engine.test.js`)

#### Scenario: A site without the toggle goes quiet across an app background

**Given** the fixture site with Background audio OFF is playing `?media=stream`
on the Android emulator
**When** the test injects `AppLifecycleState.paused`, waits, then `resumed`
**Then** the beacons that follow the resume report `paused=true` with an
unchanged `currentTime`
**And** `notificationPosted()` is false — no media surface for a site that
never opted in
(regression test: `integration_test/background_audio_media_stop_test.dart`)

#### Scenario: Switching away from an ordinary site stops its audio

**Given** plain site A is playing and the user switches to site B
**Then** `pauseMediaPlayback()` runs on A before `pauseWebView()`
**And** for a background-audio site the same call is a no-op
(regression test: `test/webview_pause_lifecycle_test.dart`)

---

### Requirement: BGAUDIO-010 — iOS Owns Its Now Playing Info and Transport Controls

On iOS the app SHALL answer the `media_session` channel from
[`MediaSessionPlugin.swift`](../../../ios/Runner/MediaSessionPlugin.swift),
mapping `start`/`update` onto `MPNowPlayingInfoCenter` (title/artist/album,
artwork, `playbackState`) and `stop` onto clearing it, and SHALL route the
`MPRemoteCommandCenter` play/pause/stop commands back as `onTransport` —
the same path the Android notification's buttons take, ending in
`window.__wsMediaControl(action)` on the owning webview.

`MediaSessionService` SHALL therefore be enabled on iOS as well as Android,
and `webview.dart` SHALL gate the shim injection and the `wsMediaSession`
handler on `MediaSessionService.isSupported` rather than on Android
specifically, so the bridge is armed exactly where something consumes its
reports.

Leaving this to WebKit — which publishes its own Now Playing info for
whatever a page plays — left the app blind to a surface it could not clear
and gave a transport tap no route into the page. Consequences of owning it:

- `start`/`update` set the `.playback` category and **activate** the session.
  Only a page that is already playing reaches them, so no audio focus is
  taken that WebKit had not taken already. This is what keeps iOS from
  suspending the process when the app leaves the foreground.
- A `play` remote command SHALL activate the session BEFORE the command is
  handed to the page. The tap that arrives there is typically the one meant to
  bring the app back from suspension, and WebKit cannot start playback against
  an inactive session — activating after the fact resumes nothing, which is
  the "I hit play and nothing plays" report.
- `stop` does NOT deactivate the session: another loaded site may still be
  sounding in the foreground, and `setActive(false)` would cut it. Reverting
  the category is BGAUDIO-003's job.
- Play / pause / stop only, as on Android. `togglePlayPause` is deliberately
  left to WebKit's own targets: a toggle handled twice cancels itself out,
  while a play or a pause handled twice is idempotent.
- All plugin state is confined to the main queue — the channel handler and
  the remote-command targets both run there (BUG-007).
- `isNotificationActive` is answered from `MPNowPlayingInfoCenter.default()
  .nowPlayingInfo != nil` (an OS read, not a local flag), keeping
  BGAUDIO-007's `notificationPosted()` meaningful on iOS.
- `disposeWebView()` SHALL call `stopForSite`: the player the session spoke
  for is gone with the webview, and stale controls whose buttons reach
  nothing are exactly the symptom this requirement exists to remove.

#### Scenario: Playback survives the app leaving the foreground

**Given** a background-audio site is playing on iOS
**When** the app goes to background
**Then** the session the page's playback report activated keeps the process
alive and the audio continues
**And** the Now Playing controls are the app's own, not a leftover WebKit entry

#### Scenario: Lock-screen play resumes the page

**Given** a background-audio site is paused with the iOS Now Playing controls up
**When** the user taps play there
**Then** `onTransport('play')` runs `window.__wsMediaControl('play')` on the
owning webview, which plays its primary media element
**And** the page's next report flips `playbackState` back to `.playing`

#### Scenario: A transport that reaches nothing says so

**Given** the page's primary media element is gone, or WebKit refuses the
`play()` (a rejected promise, e.g. `NotAllowedError`)
**When** the transport control runs `window.__wsMediaControl('play')`
**Then** the shim reports `{control, error}` and `MediaSessionService` logs one
non-sensitive warning naming the engine's own reason
**And** the ordinary playing/paused report sequence is unchanged — only
failures are reported
(regression test: `test/browser/media_session_real_engine.test.js`,
`test/media_session_service_test.dart`)

#### Scenario: Unloading the owning site clears the controls

**Given** the Now Playing controls are up for a background-audio site
**When** that site's webview is disposed
**Then** `stopForSite` clears `nowPlayingInfo` and removes the remote command
targets

#### Scenario: The bridge is armed on iOS

**Given** a site with Background audio enabled on iOS
**When** its webview is built
**Then** the media-session shim is injected and the `wsMediaSession` handler is
registered, because `MediaSessionService.isSupported` is true
(regression test: `test/media_session_service_test.dart`)

---

### Requirement: BGAUDIO-011 — Interruptions Are Recovered, and the Session State Is in the Log

An interruption (an incoming call, Siri, another app taking the session)
deactivates the app's AVAudioSession. iOS does not restore it: audio stays
dead, and every later transport tap reaches a page whose engine has no session
to play into. `MediaSessionPlugin` SHALL therefore observe
`AVAudioSession.interruptionNotification` and, while it publishes Now Playing
info for a background-audio site, re-activate the session when an interruption
ends — issuing a `play` transport when the system's `shouldResume` option says
the user expects playback back. It SHALL also re-establish the session on
`mediaServicesWereResetNotification`, since a media-server restart takes every
session and Now Playing entry with it. Recovery SHALL NOT run when the app
publishes nothing: activating a session (or asking a page to play) on behalf of
a site that is not playing steals audio focus from whatever interrupted us.

The plugin SHALL report its audio-session state to Dart (`onSessionState`),
which logs one non-sensitive line per event (no site name, URL or track
metadata) carrying the session's category and whether other audio is playing.
Every candidate cause of "the audio stopped in the background" looks identical
from Dart; the session's category and active state at that moment is what
separates them, and a device console the user cannot export does not.

All notification handling hops onto the main queue before touching plugin
state, which is confined there (BUG-007).

#### Scenario: Playback returns after a phone call

**Given** a background-audio site is playing and the app publishes Now Playing
**When** an interruption ends with `shouldResume`
**Then** the session is re-activated and a `play` transport reaches the page
**And** the App Logs carry the interruption and the re-activation

#### Scenario: An interruption while nothing of ours plays changes nothing

**Given** the app publishes no Now Playing info
**When** an interruption ends
**Then** no session is activated and no page is asked to play
(regression test: `test/js/native_media_session_targets.test.js`)

#### Scenario: The session state reaches an App Logs export

**Given** the native side reports its session state
**When** `MediaSessionService` receives `onSessionState`
**Then** one `MediaSession` line carries the category and other-audio flag
(regression test: `test/media_session_service_test.dart`)

---

### Requirement: BGAUDIO-012 — A Site That Stops Itself When Hidden Keeps Playing

Keeping the process alive (BGAUDIO-003/010/011) only settles what the OS does.
A player built for a browser tab stops on its own: when the app is
backgrounded the page is told it is hidden, and YouTube and its like pause on
`visibilitychange` / `pagehide` by their own choice. The audio then dies with
every OS-level lever correctly set, and the lockscreen play button starts a
playback the page pauses again a frame later.

While the app is backgrounded and the site's toggle is on, the media-session
shim SHALL:

- report the page as visible — `document.hidden` false and
  `document.visibilityState` `'visible'` (plus the `webkit`-prefixed pair) —
  deferring to the real values at every other time;
- swallow `visibilitychange`, `pagehide`, `freeze` and `blur` in the capture
  phase on `window` and `document`, so the page's own pause-on-hide handler
  never runs (the shim is injected at DOCUMENT_START, so its capture listener
  is registered before the page's);
- re-issue `play()` on any element that was playing and is now paused, at most
  8 times per background window, reporting a refusal through the same
  `{control, error}` path as BGAUDIO-010;
- stop fighting a pause the user asked for: a `pause`/`stop` transport clears
  the watchdog's intent for every element.

The state is handed to the page by `WebViewModel.setBackgroundPlayback`, called
for every loaded background-audio site on the lifecycle `paused` and `resumed`
branches, and is a no-op for every other site — masking visibility for a page
the user did not opt in for would keep players and timers running that should
stop. `evaluateJavascript` reaches the main frame only, so the shim relays the
state to its subframes by `postMessage`; a frame that fakes that message can
only make its own page report itself visible, on a site already opted in.

#### Scenario: A pause-on-hide player survives the background window

**Given** a background-audio site whose page pauses its player on
`visibilitychange`
**When** the app goes to background and the page receives the event
**Then** the page's handler never runs, `document.hidden` reads false, and the
element is still playing
(regression test: `test/browser/media_background_playback.test.js`)

#### Scenario: A player that stops itself anyway is resumed

**Given** the app is backgrounded with the mask in place
**When** the element pauses for its own reasons
**Then** the watchdog re-issues `play()` within a second, and a refusal is
reported as `{control: 'background-resume', error}`

#### Scenario: The user's own pause is respected

**Given** the app is backgrounded and playing
**When** the user taps pause on the lockscreen controls
**Then** the element stays paused — the watchdog does not resume it

#### Scenario: Foregrounding restores the page's own visibility

**Given** the app comes back to the foreground
**When** `setBackgroundPlayback(false)` runs
**Then** `document.hidden` / `visibilityState` report the real values again and
the events reach the page as they always have

## Limitations (documented, accepted)

- **iOS without playback**: the audio session keeps the app alive only
  while audio is actually playing; a paused player suspends with the app
  as usual. The Now Playing controls stay up in that state (resumable, as
  the Android notification does), and the tap that resumes them wakes the
  app to deliver it.
- **Subframe players**: the shim reports from any frame (BGAUDIO-008), but
  the transport controls and BGAUDIO-009's media stop both run through
  `evaluateJavascript`, which targets the main frame only.
- The exemption trades battery for playback: an enabled site's JS runs
  whenever it is loaded. The toggle is per-site and off by default.

## Files

### Modified

- `lib/web_view_model.dart` — `backgroundAudioEnabled` field (+`effective*`
  getter, toJson/fromJson), `pauseWebView()` early-return; BGAUDIO-009
  `pauseMediaPlayback()`, BGAUDIO-010 `stopForSite` on dispose.
- `lib/services/app_lifecycle_engine.dart` — `anyLoadedBackgroundAudio`,
  plan/resume gating; BGAUDIO-009 `mediaPauseIndices`.
- `lib/main.dart` — engine callbacks, decision log line, retention tier,
  `_updateBackgroundAudioSession` sync points; BGAUDIO-009 media stop at the
  site-switch, going-home, sweep and app-background call sites.
- `lib/services/background_task_service.dart` — `setBackgroundAudioActive`.
- `ios/Runner/BackgroundTaskPlugin.swift`, `ios/Runner/Info.plist` —
  AVAudioSession category switch, `audio` background mode.
- `ios/Runner/AppDelegate.swift`, `ios/Runner.xcodeproj/project.pbxproj` —
  BGAUDIO-010 plugin registration.
- `lib/screens/settings.dart` — per-site toggle (+ POST_NOTIFICATIONS request).
- `lib/services/site_settings_qr_codec.dart` — QR-shareable key.
- `lib/services/webview.dart` — `WebViewConfig.backgroundAudioEnabled`, media
  shim injection (+ the BGAUDIO-007 armed line), `wsMediaSession` handler.
- `lib/services/media_session_shim.dart` — BGAUDIO-009 `buildMediaPauseJs`
  (dumped to `test/js_fixtures/media_session/pause_media.js`); BGAUDIO-012
  visibility mask, background watchdog and `__wsMediaBackground`.
- `lib/services/media_session_shim.dart`, `lib/services/media_session_service.dart`
  — BGAUDIO-006 page-JS bridge + Dart channel bridge; BGAUDIO-007 detached-
  element registry, raise/teardown logging and the visibility check;
  BGAUDIO-008 per-frame token and media-less-frame silence; BGAUDIO-010
  `isSupported` (iOS enablement).
- `android/app/src/main/kotlin/.../MediaPlaybackService.kt`,
  `.../MediaSessionPlugin.kt`, `MainActivity.kt`, `AndroidManifest.xml` —
  BGAUDIO-006 foreground media service + permissions; BGAUDIO-007
  `isNotificationActive`.
- `tool/dump_shim_js.dart` + `test/js_fixtures/media_session/shim.js` — the
  media-session shim joins the dumped-fixture pipeline so the browser tier
  runs the exact injected string.

### Added

- `openspec/specs/background-audio/spec.md` — this document.
- `ios/Runner/MediaSessionPlugin.swift` — BGAUDIO-010 Now Playing info +
  remote command centre behind the `media_session` channel; BGAUDIO-011
  interruption recovery and session-state reporting.
- `integration_test/background_audio_lifecycle_test.dart` (exempt direction),
  `integration_test/background_audio_freeze_test.dart` (negative control),
  `integration_test/background_audio_media_notification_test.dart` (BGAUDIO-007
  notification tier) + `integration_test/fixtures/background_audio.html`.
- `test/media_session_service_test.dart`,
  `test/browser/media_session_real_engine.test.js` — BGAUDIO-007 channel and
  real-engine tiers; `test/browser/media_session_frames.test.js` +
  `test/browser/helpers/media_session_page.js` — BGAUDIO-008 multi-frame tier.
  Split by file because node:test applies `--test-timeout` to the file-level
  test as well as each subtest, and a case that plays real media costs seconds.
- `scripts/run_android_background_audio_tests.sh` + the Android emulator CI
  wiring in `.github/workflows/build-and-test.yml`.
- `integration_test/background_audio_media_stop_test.dart` (BGAUDIO-009
  emulator tier) and `test/browser/media_pause_real_engine.test.js` (the same
  snippet under real Chromium).
- `test/browser/media_background_playback.test.js` — BGAUDIO-012 against a
  page that pauses itself on hide.
- `test/js/native_media_session_targets.test.js` — BGAUDIO-010/011 structural
  gate on the iOS plugin.

## Related Specs

- [`webview-pause-lifecycle`](../webview-pause-lifecycle/spec.md) — the
  pause machinery this feature carves exemptions out of (PAUSE-001,
  PAUSE-002).
- [`archive`](../archive/spec.md) — ARCH-006 audit: the effective getter
  forces the exemption off for archive-tier sites.
- [`integration-tests`](../integration-tests/spec.md) — harness
  conventions the CI test follows.
