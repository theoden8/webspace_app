# Web Camera Access Specification

## Purpose

Let a site obtain a camera stream through `getUserMedia` when the user
allows it, per site. The motivating case is web apps whose login or
payment flow scans a QR code (banking sites especially); before this
feature every platform silently denied the webview's camera permission
request, so those flows dead-ended.

Two grant kinds are offered, because the QR the user needs to scan often
already lives on the device (a screenshot, a saved photo) or the user
does not want to expose their surroundings:

- **Real** — the device camera is handed to the page.
- **Virtual** (**Simulated camera** in the UI; `virtual` on the model) —
  the page is served a `MediaStream` rendered from a user-picked media
  file, a still image or a looped video, instead of the device camera. The
  real camera is never opened and no OS camera permission is involved.
  This is the in-browser equivalent of a virtual-camera utility (OBS
  Virtual Camera / ManyCam) scoped to one site: the browser provides the
  video pipe, the user supplies the bytes. It is deliberately neutral
  about the content — there is no inspection of what the user feeds it —
  and it is not, and does not claim to be, a defeat of liveness or
  presentation-attack detection, which inspects the imagery itself.

Camera access is user intent, not configuration: the decision is
`WebViewModel.cameraMode` (`ask` / `real` / `virtual` / `block`),
collected by a Block / Use-a-media-file / Allow popup on first request
and adjustable later from per-site settings.

## Status

- **Status**: Completed

---

## Requirements

### Requirement: CAM-001 — Per-site decision for camera-only requests

The webview SHALL resolve a camera-only web permission request (the
platform reports exactly one resource, `CAMERA`) from the site's
`cameraMode`: `real` opens the device camera, `virtual` serves the
picked source (CAM-008), `block` denies, and `ask` shows a Block /
Use-a-media-file / Allow popup naming the requesting origin and records
the answer. The stored decision is migrated from the legacy boolean
`cameraAllowed` (`true` -> `real`, `false` -> `block`, absent -> `ask`).

#### Scenario: First request prompts and remembers

**Given** a site with `cameraMode == ask`
**When** the page calls `getUserMedia({video: true})`
**Then** a Block / Use-a-media-file / Allow popup names the requesting origin
**And** the chosen mode is stored on the model and persisted via the host's save function
**And** subsequent requests resolve silently from the stored mode

#### Scenario: Burst requests share one popup

**Given** a site with `cameraMode == ask`
**When** the page issues several camera permission requests before the user answers
**Then** exactly one popup / file-pick is shown
**And** every in-flight request resolves with the same answer

### Requirement: CAM-002 — Settings control

Per-site settings SHALL expose the decision as a four-way control (Ask /
Allow / Simulated camera / Block). Selecting Simulated camera SHALL prompt
for the source file and, once one is picked, SHALL preview it at the same
4:3 cover-fit framing the site receives (a still image drawn cover-fit; a
video muted, looped, and autoplaying) so the user can confirm the clip
and see any crop before relying on it. `cameraMode` and any
`virtualCameraSource` SHALL ride `WebViewModel.toJson`/`fromJson`
(`cameraMode` serialized only when not `ask` so untouched sites keep
byte-identical JSON).

#### Scenario: Reset to Ask

**Given** a site whose stored mode is Block
**When** the user sets the Camera access dropdown to Ask and saves
**Then** the next camera request shows the popup again

#### Scenario: Picked source is previewed

**Given** a site set to Simulated camera with a picked source
**When** the per-site settings screen shows the camera row
**Then** the source is previewed at 4:3 cover-fit
**And** a video preview loops muted without a tap

### Requirement: CAM-003 — Android app-level permission at grant time

On Android, a per-site Allow SHALL additionally ensure the app holds the
CAMERA runtime permission before responding GRANT (Android's
`PermissionRequest.grant()` is a silent no-op without it). The OS-level
outcome SHALL NOT be persisted into the per-site decision: a later grant
in system settings starts working on the next page request without the
user touching the site setting.

#### Scenario: OS denial does not freeze the site decision

**Given** a site the user set to Allow
**And** the OS camera permission prompt is denied
**When** the user later grants the camera permission in system settings and the page requests the camera again
**Then** the request is granted without any change to the site's setting

### Requirement: CAM-004 — Grants never widen beyond video

The camera flow SHALL handle only camera-only requests. A request that
bundles the microphone (iOS/macOS report the single resource
`CAMERA_AND_MICROPHONE`; Android reports `CAMERA` plus `MICROPHONE`)
SHALL fall through to the pre-existing default: PROMPT, which Android
and Linux WPE map to deny and iOS 15+/macOS 12+ render as WebKit's own
per-site prompt. The grant response itself SHALL name only the `CAMERA`
resource.

#### Scenario: Camera-plus-microphone is not granted by the camera flow

**Given** a site with `cameraMode == real` or `cameraMode == virtual`
**When** the page calls `getUserMedia({video: true, audio: true})`
**Then** the per-site camera flow does not handle the request
**And** the virtual-camera shim passes it through to the platform untouched

### Requirement: CAM-005 — Nested webviews prompt independently

A nested `InAppWebViewScreen` (cross-domain navigation) SHALL forward
camera requests to the same popup and remember the answer in-memory for
that screen's lifetime only, mirroring the protected-content pattern.
Nested screens have no persisted model; the parent site's stored
decision is not inherited across the origin change.

#### Scenario: Outbound link to a camera page

**Given** a site whose outbound link opens a nested webview on another domain
**When** the nested page requests the camera
**Then** the Allow/Block popup is shown
**And** the answer is reused for further requests within that nested screen
**And** nothing is persisted

### Requirement: CAM-006 — Archive-tier sites deny silently

`effectiveCameraMode` SHALL be `block` for archive-tier sites regardless
of stored value (ARCH-006: the popup, the file picker, and Android's OS
permission dialog are OS-level UI). No popup is shown; the stored mode
and any picked source are preserved for when the site leaves the archive.

#### Scenario: Archive site requests camera

**Given** an open archive containing a site with `cameraMode == real` or `virtual`
**When** a page in that site requests the camera
**Then** the request is denied without any popup

### Requirement: CAM-007 — Decision never rides the settings QR

`cameraMode` and `virtualCameraSource` SHALL be in
`SiteSettingsQrCodec.excludedKeys`: a remembered permission grant is
trust the user gave one device's popup, and the picked media is local
user content (it would also blow QR capacity) — neither is shareable
configuration.

#### Scenario: QR share strips the decision

**Given** a site with a non-`ask` `cameraMode` and a picked `virtualCameraSource`
**When** the user shares the site's settings QR
**Then** the payload contains neither `cameraMode` nor `virtualCameraSource`

### Requirement: CAM-008 — Simulated camera from a picked media file

In `virtual` mode the webview SHALL serve a synthetic camera. A
DOCUMENT_START JavaScript shim (injected with `forMainFrameOnly: false`)
intercepts a video-only `getUserMedia` and resolves it with a
`MediaStream` rendered from the site's `virtualCameraSource` — a still
image drawn onto a canvas, or a looped muted video element drawn onto a
canvas — captured via `HTMLCanvasElement.captureStream()`. The device
camera MUST NOT be opened and no OS camera permission MUST be requested.
The shim presents the synthetic track as an ordinary camera (a plausible
track label; one `videoinput` published by `enumerateDevices` whose label
is revealed only after a stream has been served) so that ordinary QR /
photo capture flows accept it and cannot fingerprint the browser by the
stream's shape. That presentation MUST hold at the surfaces a
fingerprinter inspects: the overrides live on `MediaDevices.prototype` and
`MediaStreamTrack.prototype` rather than on the instances (no own-property
leak), every override stringifies as `[native code]` including the `label`
accessor, the track reports as `MediaStreamTrack` rather than
`CanvasCaptureMediaStreamTrack`, and a track the shim did not create keeps
its real label and settings. Probes live in
`test/browser/lie_detection.test.js`; two gaps remain open there as `todo`
because they are shared by every shim in the repo rather than specific to
the camera (the `__ws*` install markers are enumerable on `window`, and a
parent realm's `Function.prototype.toString` reveals an override defined in
a child realm). When `virtual` is selected but no source has been picked,
the request MUST be denied and the picker re-offered.

#### Scenario: Virtual stream replaces the camera

**Given** a site with `cameraMode == virtual` and a picked image source
**When** the page calls `getUserMedia({video: true})`
**Then** the promise resolves with a canvas-backed `MediaStream`
**And** the device camera is not opened and no OS camera permission is requested

#### Scenario: Enumeration exposes exactly one camera

**Given** a site in `virtual` mode
**When** the page calls `enumerateDevices()`
**Then** exactly one `videoinput` is reported
**And** its label is empty until a stream has been served, then the camera label

#### Scenario: Real mode leaves the device list alone

**Given** a site in `real` (or `block`) mode
**When** the page calls `enumerateDevices()`
**Then** the platform's own device list is returned unmodified
**And** a page that selects a real camera by `deviceId` still opens it

#### Scenario: Ask mode on a camera-less device stays discoverable

**Given** a site in `ask` mode on a device with no real camera
**When** the page calls `enumerateDevices()`
**Then** one synthetic `videoinput` is reported so the page still calls
`getUserMedia` and the user is offered the "use a media file" popup
**And** if the user then answers Allow, the synthetic `deviceId` is stripped
from the constraints before the real camera is opened

#### Scenario: Virtual selected with no source yet

**Given** a site with `cameraMode == virtual` and no `virtualCameraSource`
**When** the page calls `getUserMedia({video: true})`
**Then** the request is denied (NotAllowedError) rather than opening the real camera

### Requirement: CAM-010 — Real-Android-WebView coverage

The camera modes SHALL be exercised on a real Android WebView by
`integration_test/camera_test.dart` (runner:
`scripts/run_android_camera_tests.sh`), because neither lower tier runs
the engine the app ships: the jsdom tier stubs `captureStream`, and the
desktop-Chromium tier lacks Android WebView's own gates. That gap shipped
a real defect — Android WebView defaults
`mediaPlaybackRequiresUserGesture` to `true`, which blocks a
`getUserMedia` stream from ever playing, so every mode rendered a grey
frame while both lower tiers stayed green.

The main webview SHALL therefore set `mediaPlaybackRequiresUserGesture`
to `false` (guarded structurally by
`test/js/camera_autoplay_setting.test.js`).

#### Scenario: Virtual mode serves the picked image on-device

**Given** a site in `virtual` mode whose source is a solid-colour image
**When** a page on the emulator calls `getUserMedia({video: true})` and samples
a frame onto a canvas
**Then** the sampled pixel matches the picked image's colour

#### Scenario: A video source plays and loops on-device

**Given** a site in `virtual` mode whose source is a short two-colour clip
**When** a page on the emulator samples the stream until the colour changes
**Then** both of the clip's colours are observed
**And** the colour keeps changing past the clip's duration, proving it loops
rather than freezing on the first decoded frame

The probe waits for that change rather than sampling a fixed window: the
emulator's software decoder runs the clip several times slower than real time
and at a rate that varies per runner, so a fixed window turns a correctly
playing stream into a red build (the same 4s window produced 8, 2 and 0
transitions across runs). It samples until the first transition or 30s, so a
stalled decoder still fails and a healthy one exits in about a second.

#### Scenario: Blocked site is denied on-device

**Given** a site in `block` mode
**When** the same page requests the camera
**Then** it is rejected with `NotAllowedError`

#### Scenario: Real mode is asserted where a camera exists

**Given** a site in `real` mode on a device with a working camera
**When** the page requests the camera
**Then** frames arrive and are not the virtual source's colour
**And** on a runner with no camera, no CAMERA permission, or a camera whose
open call never settles, the scenario is skipped rather than failed

CI is the skipped case by design: the AVD's emulated camera does not settle
a `getUserMedia` call under headless swiftshader, so the workflow does not
enable it and the real-camera path stays a manual / on-device check. The
probe therefore caps `getUserMedia` itself, so a hung open reports a
classifiable `TimeoutError` instead of stalling the run.

### Requirement: CAM-011 — Backgrounded sites deny silently

A camera request from a site that is not the active one SHALL be denied
without prompting, whatever its stored `cameraMode`, and SHALL leave the
stored mode and picked source untouched. Loaded-but-inactive sites keep
running JS (pause is not a security boundary, see
[webview-pause-lifecycle](../webview-pause-lifecycle/spec.md)), so without
this a background site can pop a permission dialog the user reads as
belonging to the site on screen, or — with a remembered `real`/`virtual`
grant — start capture with nothing on screen to attribute it to. The gate
lives in `CameraDecisionEngine.decide` as a required `isSiteActive`
predicate, so a new call site cannot be wired up without answering it.

Only the grant is gated. The non-prompting `webCameraMode` read behind
`enumerateDevices` is not: the shim caches it for the document's lifetime,
so denying it once would leave a site enumerating no camera long after it
came back to the foreground, and enumeration grants nothing on its own.

An answer given to a popup that was raised while the site was active still
applies when it settles after the switch — the user answered it — but the
next request from the now-backgrounded site is denied like any other.

#### Scenario: Background site with a remembered grant

**Given** a loaded site with `cameraMode == real` (or `virtual` with a source)
**And** the user is looking at a different site
**When** a page in the background site calls `getUserMedia({video: true})`
**Then** the bridge answers `block` and the request is rejected
**And** no camera is opened and the site's stored mode is unchanged

#### Scenario: Background site cannot raise the popup

**Given** a loaded site with `cameraMode == ask`
**And** the user is looking at a different site
**When** a page in the background site requests the camera
**Then** no popup and no file picker are shown
**And** the request is denied
**And** the site prompts as usual once the user switches back to it

### Requirement: CAM-009 — Fail closed without the bridge

If the `webCameraRequest` Dart bridge is unreachable, the shim SHALL deny
the request rather than fall through to the device camera.

#### Scenario: Missing bridge denies

**Given** the camera shim is injected but `flutter_inappwebview.callHandler` is absent
**When** the page calls `getUserMedia({video: true})`
**Then** the request is denied (NotAllowedError)
**And** the device camera is not opened

---

## Platform notes

- **Android**: grant requires the app's CAMERA runtime permission
  (`CameraPermissionPlugin.kt`, channel
  `org.codeberg.theoden8.webspace/camera_permission`), requested on
  demand at grant time. The manifest already declared CAMERA for the
  site-settings QR scanner.
- **iOS/macOS**: responding GRANT suppresses only WebKit's per-site
  prompt; WebKit itself triggers the app-level TCC camera prompt
  (NSCameraUsageDescription) when capture starts. macOS additionally
  carries the `com.apple.security.device.camera` sandbox entitlement.
- **Linux (WPE WebKit)**: the fork maps a video-only
  `WebKitUserMediaPermissionRequest` to `CAMERA` and GRANT/deny
  faithfully; no app-level permission layer exists.
- **Virtual mode is cross-platform and needs no native permission**: the
  shim resolves `getUserMedia` in JS from a canvas stream, so the OS
  camera and its prompt are never touched on any platform. The picked
  source is inlined as a `data:` URL on the model (like `customIconPng`)
  so it rides settings backups and lives inside the encrypted archive
  slice for archive-tier sites; `VirtualCameraService` caps it at 24 MiB.
- Tracking Protection does not force-block camera (unlike protected
  content, ETP-023): capture starts only after an explicit per-site Allow
  or a user-picked file, so it is not a silent tracking vector.
