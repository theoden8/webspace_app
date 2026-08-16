# Web Microphone Access Specification

## Purpose

Let a site that asks for audio capture get *something* usable without ever
exposing the device microphone. The user picks an audio file; the page is
served a `MediaStream` whose audio track is that file decoded once and looped
forever.

The deliberate asymmetry with [web-camera-access](../web-camera-access/spec.md):
the camera feature offers a **real** grant alongside the virtual one, because a
QR scan sometimes genuinely needs the lens. This feature offers **no real
mode at all**. No OS recording permission is ever requested on any platform,
no `RECORD_AUDIO` manifest entry exists, and the native permission layer denies
every microphone request outright. A site either hears a file the user chose,
or it hears nothing.

The decision is `WebViewModel.microphoneMode` (`ask` / `virtual` / `block`),
collected by a Block / Use-audio-file popup on first request and adjustable
later from per-site settings.

## Status

- **Status**: Completed

---

## Requirements

### Requirement: MIC-001 — Per-site decision, with no real-microphone mode

`MicrophoneAccessMode` SHALL have exactly three values — `ask`, `virtual`,
`block` — and no value that opens a capture device. A `getUserMedia` that asks
for audio SHALL resolve from the site's mode: `virtual` serves the picked clip
(MIC-008), `block` denies, and `ask` shows a Block / Use-audio-file popup
naming the requesting origin and records the answer.

#### Scenario: First request prompts and remembers

**Given** a site with `microphoneMode == ask`
**When** the page calls `getUserMedia({audio: true})`
**Then** a Block / Use-audio-file popup names the requesting origin
**And** the chosen mode is stored on the model and persisted via the host's save function
**And** subsequent requests resolve silently from the stored mode

#### Scenario: Burst requests share one popup

**Given** a site with `microphoneMode == ask`
**When** the page issues several audio requests before the user answers
**Then** exactly one popup / file-pick is shown
**And** every in-flight request resolves with the same answer

#### Scenario: No mode grants the device

**Given** any per-site microphone setting the UI can produce
**When** the site requests audio
**Then** no platform `getUserMedia` audio call is made and no OS recording
permission is requested

### Requirement: MIC-002 — Settings control

Per-site settings SHALL expose the decision as a three-way control (Ask /
Audio file / Block). Selecting Audio file SHALL prompt for the source file and
SHALL show the chosen file's name. `microphoneMode` and any
`virtualMicrophoneSource` SHALL ride `WebViewModel.toJson`/`fromJson`
(`microphoneMode` serialized only when not `ask` so untouched sites keep
byte-identical JSON).

#### Scenario: Reset to Ask

**Given** a site whose stored mode is Block
**When** the user sets the Microphone access dropdown to Ask and saves
**Then** the next audio request shows the popup again

#### Scenario: Untouched sites keep their JSON

**Given** a site the user has never given a microphone decision
**When** its model is serialized
**Then** neither `microphoneMode` nor `virtualMicrophoneSource` appears

### Requirement: MIC-003 — The native layer denies every microphone request

Whenever the microphone resolver is wired, the webview's
`onPermissionRequest` SHALL respond `DENY` to any request whose resources
include `MICROPHONE` or `CAMERA_AND_MICROPHONE`, rather than falling through
to the default `PROMPT`.

The fall-through is not good enough: Android and Linux WPE map `PROMPT` to
deny, but iOS 15+/macOS 12+ render it as WebKit's own per-site prompt, and
answering that prompt starts a real capture with the app-level TCC
microphone prompt behind it. An explicit `DENY` is what makes "no OS
recording permission is ever requested" true on every platform.

#### Scenario: A microphone request never reaches the OS

**Given** a site whose page asks the platform for audio capture directly
**When** the native permission request arrives
**Then** it is denied without any WebKit or OS prompt

### Requirement: MIC-004 — Composition with the virtual camera

A request for audio AND video SHALL be split: the audio half is synthesised
here, and the video half is re-issued through the LIVE
`navigator.mediaDevices.getUserMedia` (not the function captured at install
time) with the `audio` constraint removed, so the camera shim resolves it per
`cameraMode` regardless of which shim was injected last. Re-entry terminates
because a video-only request always falls through this shim. Tracks from both
halves SHALL be combined into one `MediaStream`.

Per the getUserMedia contract a request fails as a whole when a requested kind
cannot be provided, so a `block` microphone SHALL reject a combined request
rather than silently downgrading it to video-only, and a failing video half
SHALL tear down the synthetic audio graph rather than leaking a running
`AudioContext` the page can no longer reach.

This supersedes the fall-through named in CAM-004: with this feature wired, a
combined request is handled (as audio-substitution plus a camera decision)
rather than passed to the platform. CAM-004's invariant is unchanged and now
holds absolutely — nothing in either flow ever grants audio capture.

#### Scenario: Virtual microphone and virtual camera together

**Given** a site with `microphoneMode == virtual` and `cameraMode == virtual`, both with sources
**When** the page calls `getUserMedia({audio: true, video: true})`
**Then** the resolved stream carries one synthetic audio track and one synthetic video track
**And** neither the real microphone nor the real camera is opened

#### Scenario: Blocked microphone fails the whole combined request

**Given** a site with `microphoneMode == block`
**When** the page calls `getUserMedia({audio: true, video: true})`
**Then** the request is rejected with `NotAllowedError`
**And** no video-only request is issued to the platform

#### Scenario: A failing video half does not strand the audio graph

**Given** a site with `microphoneMode == virtual` whose camera decision denies
**When** the page calls `getUserMedia({audio: true, video: true})`
**Then** the request rejects
**And** the synthetic audio's `AudioContext` is closed

### Requirement: MIC-005 — Nested webviews prompt independently

A nested `InAppWebViewScreen` (cross-domain navigation) SHALL forward
microphone requests to the same popup and remember the answer in-memory for
that screen's lifetime only, mirroring the camera pattern. Nested screens have
no persisted model; the parent site's stored decision is not inherited across
the origin change.

#### Scenario: Outbound link to a page that wants audio

**Given** a site whose outbound link opens a nested webview on another domain
**When** the nested page requests audio
**Then** the Block/Use-audio-file popup is shown
**And** the answer is reused for further requests within that nested screen
**And** nothing is persisted

### Requirement: MIC-006 — Archive-tier sites deny silently

`effectiveMicrophoneMode` SHALL be `block` for archive-tier sites regardless
of stored value (ARCH-006: the popup and the file picker are OS-level UI). No
popup is shown; the stored mode and any picked clip are preserved for when the
site leaves the archive.

#### Scenario: Archive site requests audio

**Given** an open archive containing a site with `microphoneMode == virtual`
**When** a page in that site requests audio
**Then** the request is denied without any popup
**And** the stored mode and clip are unchanged

### Requirement: MIC-007 — Decision never rides the settings QR

`microphoneMode` and `virtualMicrophoneSource` SHALL be in
`SiteSettingsQrCodec.excludedKeys`: a remembered permission decision is trust
the user gave one device's popup, and the picked clip is local user content
(it would also blow QR capacity) — neither is shareable configuration.

#### Scenario: QR share strips the decision

**Given** a site with a non-`ask` `microphoneMode` and a picked clip
**When** the user shares the site's settings QR
**Then** the payload contains neither `microphoneMode` nor `virtualMicrophoneSource`

### Requirement: MIC-008 — Looped audio file as the microphone

In `virtual` mode the webview SHALL serve a synthetic microphone. A
DOCUMENT_START JavaScript shim (injected with `forMainFrameOnly: false`)
intercepts a `getUserMedia` that asks for audio and resolves it with a
`MediaStream` whose audio track comes from an `AudioBufferSourceNode` with
`loop = true` feeding a `MediaStreamAudioDestinationNode`. The clip is decoded
from the model's `data:` URL with `atob` + `decodeAudioData` — never `fetch`,
which a page's `connect-src` CSP can block.

The clip MUST repeat indefinitely: a page sampling the track long after the
clip's duration MUST still receive signal. A track that is stopped or ends
MUST tear the graph down (engines cap how many `AudioContext`s a document may
hold). An `AudioContext` that starts suspended MUST be resumed, and retried on
the first user gesture, so the page is never handed a silent track.

When `virtual` is selected but no clip has been picked, the request MUST be
denied and the picker re-offered.

#### Scenario: The clip loops past its own length

**Given** a site in `virtual` mode whose clip is a 0.25 s tone
**When** a page samples the served track's RMS over 1.5 s
**Then** signal is present both at the start and at the end of the window

#### Scenario: Virtual selected with no clip yet

**Given** a site with `microphoneMode == virtual` and no `virtualMicrophoneSource`
**When** the page calls `getUserMedia({audio: true})`
**Then** the request is denied (`NotAllowedError`)

#### Scenario: Stopping the track closes the audio graph

**Given** a served synthetic microphone track
**When** the page calls `track.stop()`
**Then** the buffer source is stopped and the `AudioContext` is closed

### Requirement: MIC-009 — The substitution is not detectable by shape

The synthetic microphone SHALL present as an ordinary capture device at the
surfaces a fingerprinter inspects, so that ordinary capture UIs accept it and
no script can single this browser out by the stream's shape:

- the track reports a plausible device `label`, and `enumerateDevices`
  publishes one matching `audioinput` whose label is revealed only after a
  stream has been served (the spec's own permission gating);
- `getSettings()` reports the full capture shape a real microphone reports
  (`deviceId`, `groupId`, `sampleRate`, `sampleSize`, `channelCount`,
  `echoCancellation`, `autoGainControl`, `noiseSuppression`, `latency`) rather
  than the near-empty bag a WebAudio destination track returns, mirroring the
  processing flags and channel count the page actually asked for;
- `getCapabilities()` and `getConstraints()` answer in kind, and
  `applyConstraints()` accepts a re-negotiation instead of rejecting as
  overconstrained;
- `clone()` keeps the clone presenting as the same device;
- the overrides live on `MediaDevices.prototype` and
  `MediaStreamTrack.prototype` rather than on the instances (no own-property
  leak), and every override stringifies as `[native code]` including the
  `label` accessor;
- a track the shim did not create keeps its real label, settings and
  capabilities.

The two gaps left open in CAM-008 (`__ws*` install markers enumerable on
`window`; a parent realm's `Function.prototype.toString` revealing an override
defined in a child realm) apply here too — they are shared by every shim in
the repo rather than specific to this one.

#### Scenario: Enumeration exposes exactly one microphone

**Given** a site in `virtual` mode on a device with a real microphone
**When** the page calls `enumerateDevices()`
**Then** exactly one `audioinput` is reported, and it is not the real one
**And** its label is empty until a stream has been served, then the device label
**And** the platform's `videoinput` and `audiooutput` entries are unchanged

#### Scenario: Ask mode on a microphone-less device stays discoverable

**Given** a site in `ask` mode on a device with no real microphone
**When** the page calls `enumerateDevices()`
**Then** one synthetic `audioinput` is reported so the page still calls
`getUserMedia` and the user is offered the "use audio file" popup

#### Scenario: Block mode leaves the device list alone

**Given** a site in `block` mode
**When** the page calls `enumerateDevices()`
**Then** the platform's own device list is returned unmodified

#### Scenario: The track does not read as synthetic

**Given** a served synthetic microphone track under a real engine
**When** a script reads `track.constructor.name`, `track.kind`, `track.readyState`
and `Object.getOwnPropertyNames(track)`
**Then** it sees `MediaStreamTrack`, `audio`, `live`, and no own properties

### Requirement: MIC-011 — Backgrounded sites deny silently

A microphone request from a site that is not the active one SHALL be denied
without prompting, whatever its stored `microphoneMode`, and SHALL leave the
stored mode and picked clip untouched. This is CAM-011 applied to audio, and
it is carried by the same code: the gate is a required `isSiteActive`
predicate on the shared `MediaGrantEngine`, so neither feature — nor a future
one — can add a call site without answering it.

Only one of CAM-011's two reasons transfers, and it is enough. The camera's
"a remembered grant would start capture with nothing on screen" does not
apply: there is no device here, so a backgrounded site that got its clip
would be observing nothing. But "a background site's popup reads as belonging
to the site on screen" applies exactly — a Block / Use-audio-file dialog
naming an origin the user is not looking at is the same trap regardless of
which sensor it claims. The deny therefore covers `virtual` as well as `ask`,
matching the camera rather than carving out an exemption for the mode whose
grant is harmless.

As with CAM-011, only the grant is gated; the non-prompting `webMicrophoneMode`
read behind `enumerateDevices` is not, because the shim caches it for the
document's lifetime.

#### Scenario: Background site cannot raise the popup

**Given** a loaded site with `microphoneMode == ask`
**And** the user is looking at a different site
**When** a page in the background site requests audio
**Then** no popup and no file picker are shown
**And** the request is denied
**And** the site prompts as usual once the user switches back to it

#### Scenario: Background site with a remembered clip

**Given** a loaded site with `microphoneMode == virtual` and a picked clip
**And** the user is looking at a different site
**When** a page in the background site calls `getUserMedia({audio: true})`
**Then** the bridge answers `block` and the request is rejected
**And** the site's stored mode and clip are unchanged

### Requirement: MIC-012 — No deactivation stop, and the clip survives one

CAM-012 ends any **device** camera capture when a site leaves the screen and
exempts the simulated camera. The microphone has no device half at all, so
there is nothing to end: every audio track this feature serves is the exempt
case, and the audio equivalent of `__wsStopRealCapture()` would have an empty
job. No such hook is installed, and no call site pretends otherwise.

What this does require is that the camera's stop not reach the substituted
audio track. Both shims register what they substituted in one cross-shim
`globalThis.__wsSyntheticTracks` set, and the camera's stop skips anything in
it. A combined audio+video request is served by both shims and returns a
single stream carrying both tracks, so whichever shim wraps the other sees
the other's track and must be able to recognise it — without the shared set
the simulated microphone would be killed on every site switch, and only by
accident of injection order is it not.

#### Scenario: Switching away leaves the simulated microphone alone

**Given** a site serving its picked clip, alone or alongside a simulated camera
**When** the user switches to another site and back
**Then** the audio track is still live and still carries the clip

#### Scenario: The stop hook recognises an audio track it did not create

**Given** a stream carrying a simulated video track and a simulated audio track
**When** `__wsStopRealCapture()` runs
**Then** neither track is stopped
**And** the call reports having stopped nothing

### Requirement: MIC-010 — Fail closed without the bridge

If the `webMicrophoneRequest` Dart bridge is unreachable, the shim SHALL deny
the request. Since there is no real-microphone mode, denying is also the only
honest answer available.

#### Scenario: Missing bridge denies

**Given** the microphone shim is injected but `flutter_inappwebview.callHandler` is absent
**When** the page calls `getUserMedia({audio: true})`
**Then** the request is denied (`NotAllowedError`)

---

## Platform notes

- **No native permission layer exists for this feature on any platform.**
  There is no Android `RECORD_AUDIO` manifest entry, no
  `NSMicrophoneUsageDescription` requirement, no macOS
  `com.apple.security.device.audio-input` entitlement. The synthesis is pure
  JS (WebAudio), so nothing under it needs one, and MIC-003 denies the native
  request so nothing can back-door one in.
- **Storage**: the picked clip is inlined as a `data:` URL on the model (like
  `customIconPng` and the virtual-camera source) so it rides settings backups
  and lives inside the encrypted archive slice for archive-tier sites.
  `VirtualMicrophoneService` caps it at 8 MiB — smaller than the camera's 24
  MiB because the shim decodes the whole clip into an `AudioBuffer` up front,
  which it must, to loop it without a seam.
- **Autoplay**: Android WebView's `mediaPlaybackRequiresUserGesture = false`
  (set for CAM-010) also governs WebAudio start-up in Chromium WebView. The
  shim additionally resumes the context and retries on the first gesture, so
  an engine that still suspends does not hand the page a silent track.
- Tracking Protection does not force-block the microphone: nothing is captured
  in any mode, so there is no tracking vector for the umbrella to close.

## Test tiers

- **Dart** — `test/microphone_test.dart` (model, serialization, archive
  override, QR exclusion), `test/microphone_decision_engine_test.dart`
  (decide → coalesce → persist against the real engine).
- **jsdom** — `test/js/microphone_stream_shim.test.js`: the decision funnel,
  the combined-request split, prototype-level override placement,
  `enumerateDevices` masking. WebAudio is stubbed; nothing about real audio is
  claimed here.
- **Real engine** — `test/browser/microphone_stream_real_engine.test.js`:
  Chromium serves the page from `127.0.0.1` (getUserMedia needs a secure
  context), the shim is fed a WAV generated in the test (never committed — it
  is a derivative of its parameters), and the served track is read back
  through an `AnalyserNode` to prove it carries signal AND still carries it
  long after the clip's own duration, which is the loop. The same tier asserts
  the page's `microphone` permission state never moves.
