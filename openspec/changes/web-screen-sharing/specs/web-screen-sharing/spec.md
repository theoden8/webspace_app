# Web Screen Sharing Specification

## Purpose

Let a site that asks to share the screen get *something* usable without ever
capturing the device. The user picks an image or a video; the page is served a
`MediaStream` shaped like a shared screen and rendered from that file.

The asymmetry with [web-camera-access](../../../../specs/web-camera-access/spec.md)
is sharper than the microphone's. That feature has no real mode because no
recording permission is worth the exposure; this one has no real mode because a
real mode **cannot be scoped to the requesting site at all**. A display capture
is whole-surface by construction — `MediaProjection` mirrors the whole Android
device, and this app's own window holds the drawer, the tab strip and whichever
other site the user switches to. A site granted a real screen would be watching
every *other* site in the webspace, which is the thing per-site isolation
exists to prevent. So no per-site UI can make a real grant safe, and none is
offered.

The decision is `WebViewModel.screenShareMode` (`ask` / `virtual` / `block`),
collected by a Block / Use-a-media-file popup on first request and adjustable
later from per-site settings.

## Status

- **Status**: Completed

---

## ADDED Requirements

### Requirement: SHARE-001 — Per-site decision, with no real-screen mode

`ScreenShareMode` SHALL have exactly three values — `ask`, `virtual`, `block` —
and no value that captures a display. A `getDisplayMedia` call SHALL resolve
from the site's mode: `virtual` serves the picked surface (SHARE-008), `block`
denies, and `ask` shows a Block / Use-a-media-file popup naming the requesting
origin and records the answer.

A stored value naming a real grant SHALL parse as `ask`, so a crafted backup or
a downgrade from some future build cannot resurrect one.

#### Scenario: First request prompts and remembers

**Given** a site with `screenShareMode == ask`
**When** the page calls `getDisplayMedia()`
**Then** a Block / Use-a-media-file popup names the requesting origin
**And** the chosen mode is stored on the model and persisted via the host's save function
**And** subsequent requests resolve silently from the stored mode

#### Scenario: Burst requests share one popup

**Given** a site with `screenShareMode == ask`
**When** the page issues several share requests before the user answers
**Then** exactly one popup / file-pick is shown
**And** every in-flight request resolves with the same answer

#### Scenario: No mode captures a display

**Given** any per-site screen sharing setting the UI can produce
**When** the site calls `getDisplayMedia()`
**Then** no platform display capture is started and no OS screen-capture
permission is requested
**And** the page never receives a surface it did not get from a file the user picked

#### Scenario: A stored real grant does not survive a round trip

**Given** persisted JSON whose `screenShareMode` reads `real`
**When** the model is loaded
**Then** the mode is `ask` and the next request prompts

### Requirement: SHARE-002 — Settings control

Per-site settings SHALL expose the decision as a three-way control (Ask /
Simulated screen / Block), with the unreachable "Allowed" state shown greyed
and explained rather than omitted — the absent row *is* the guarantee.
Selecting Simulated screen SHALL prompt for the source file and SHALL show the
chosen file's name and a preview. The preview SHALL show the whole source at
its own aspect ratio, matching what the site receives, rather than the camera's
4:3 cover-fit crop. `screenShareMode` and any `virtualScreenSource` SHALL ride
`WebViewModel.toJson`/`fromJson` (`screenShareMode` serialized only when not
`ask` so untouched sites keep byte-identical JSON).

#### Scenario: Reset to Ask

**Given** a site whose stored mode is Block
**When** the user sets Screen sharing to Ask and saves
**Then** the next `getDisplayMedia` call shows the popup again

#### Scenario: Untouched sites keep their JSON

**Given** a site the user has never given a screen sharing decision
**When** its model is serialized
**Then** neither `screenShareMode` nor `virtualScreenSource` appears

#### Scenario: The unreachable state is visible

**Given** the per-site permissions screen
**When** the user opens the Screen sharing row
**Then** an "Allowed" option is shown, disabled, saying a screen capture would
also show the user's other sites

### Requirement: SHARE-003 — No native path can hand over a display

No platform this app ships SHALL be able to route a display-capture request to
a grant. Today that holds without any code in `onPermissionRequest`:

- **Android** — `WebChromeClient.onPermissionRequest` has resources for audio,
  video, MIDI sysex and protected media; there is no display one, and Android
  WebView implements no screen capture to gate.
- **iOS / macOS** — the plugin implements only
  `requestMediaCapturePermissionFor`, whose `WKMediaCaptureType` is camera /
  microphone / cameraAndMicrophone. WebKit's display-capture delegate is not
  implemented, so WKWebView's default (deny) stands.
- **Linux (WPE)** — a display-device `WebKitUserMediaPermissionRequest` maps to
  an **empty** resource list, which the plugin denies natively before Dart is
  consulted.

"It happens to be impossible" is not a guarantee. If the webview plugin ever
gains a `PermissionResourceType` naming a display, the app SHALL deny it
explicitly in `onPermissionRequest` rather than fall through to the PROMPT
default, which iOS 15+/macOS 12+ render as WebKit's own screen picker. The gate
is `test/screen_share_native_denial_test.dart`, which fails on the fork bump
that introduces such a value.

#### Scenario: A display request never reaches the OS picker

**Given** a site whose page asks the platform for a display capture directly
**When** the native permission request would arrive
**Then** it is denied without any WebKit or OS picker

#### Scenario: A new display resource type fails the build

**Given** a webview plugin bump that adds a display-capture permission resource
**When** the test suite runs
**Then** it fails, naming the new value and the deny that must be written

### Requirement: SHARE-004 — The camera grant never widens into a screen

The camera flow's grant response names only the `CAMERA` resource (CAM-004),
and nothing in this feature adds a resource to it. A per-site camera Allow
SHALL NOT make any display surface reachable, and the screen sharing shim SHALL
NOT touch `getUserMedia` or `enumerateDevices` — a display capture never appears
in the device list, so there is nothing there for it to patch.

#### Scenario: Camera Allow does not imply a share

**Given** a site with `cameraMode == real` and `screenShareMode == ask`
**When** the page calls `getDisplayMedia()`
**Then** the Block / Use-a-media-file popup is shown, and no surface is served
until it is answered

#### Scenario: The screen shim leaves the capture APIs alone

**Given** the screen sharing shim installed under a real engine
**When** a script reads `MediaDevices.prototype.getUserMedia` and
`MediaDevices.prototype.enumerateDevices`
**Then** both stringify as `[native code]` from the engine's own
implementations, unwrapped by this shim

### Requirement: SHARE-005 — Only the top-level document

A screen share SHALL be served only to the top-level document. A subframe SHALL
be denied, and SHALL NOT be able to raise the decision popup — a third-party
frame (an ad, a payment widget, an embedded chat) is not who the user answered
for, and a popup it raised would read as belonging to the site on screen.

This is deliberately stricter than the `display-capture` permission policy's
own `self` default, which would let a same-origin subframe through. The cost is
a rare broken flow; the benefit is that "the site the user granted, and nobody
else" needs no reasoning about frame ancestry to be true.

Three mechanisms carry it, because losing any one of them is silent — the app
still works and a frame quietly gets a grant:

1. The shim is injected `forMainFrameOnly: true`, unlike the camera and
   microphone shims. On Android the plugin implements that by wrapping the
   source in `if (window === window.top)`; on iOS/macOS WebKit enforces it.
2. The shim re-reads the same test itself and denies **before** the bridge is
   reached, so the guard survives a platform that stops honouring the flag.
3. The Dart handler is registered with the frame-aware
   `JavaScriptHandlerFunction` signature and denies `!isMainFrame`. This is the
   layer outside the page's realm: `isMainFrame` is computed by the plugin's
   own bridge preamble and reaches Dart behind the bridge secret, so page
   script can neither forge it nor call the handler around it.

Gated structurally by `test/js/screen_share_top_frame_only.test.js`, which also
pins the camera and microphone shims as all-frames so a "make them consistent"
edit cannot silently narrow them.

#### Scenario: A cross-origin iframe is refused

**Given** a site whose page embeds a cross-origin iframe
**And** the site's stored mode is `virtual` with a picked source
**When** script in the iframe calls `getDisplayMedia()`
**Then** the request is rejected with `NotAllowedError`
**And** the bridge is never called, so no popup is shown
**And** the top-level document is still served normally

### Requirement: SHARE-006 — Archive-tier sites deny silently

`effectiveScreenShareMode` SHALL be `block` for archive-tier sites regardless of
stored value (ARCH-006: the popup and the file picker are OS-level UI). No popup
is shown; the stored mode and any picked source are preserved for when the site
leaves the archive, and the site shows no drawer badge.

#### Scenario: Archive site asks to share

**Given** an open archive containing a site with `screenShareMode == virtual`
**When** a page in that site calls `getDisplayMedia()`
**Then** the request is denied without any popup
**And** the stored mode and source are unchanged

### Requirement: SHARE-007 — Decision never rides the settings QR

`screenShareMode` and `virtualScreenSource` SHALL be in
`SiteSettingsQrCodec.excludedKeys`: a remembered permission decision is trust
the user gave one device's popup, and the picked media is local user content (it
would also blow QR capacity) — neither is shareable configuration.

#### Scenario: QR share strips the decision

**Given** a site with a non-`ask` `screenShareMode` and a picked source
**When** the user shares the site's settings QR
**Then** the payload contains neither `screenShareMode` nor `virtualScreenSource`

### Requirement: SHARE-008 — A picked file as the shared surface

In `virtual` mode the webview SHALL serve a synthetic display surface. A
DOCUMENT_START JavaScript shim overrides `MediaDevices.prototype.getDisplayMedia`
and resolves it with a `MediaStream` rendered from the site's
`virtualScreenSource` — a still image drawn onto a canvas, or a looped muted
video drawn onto a canvas — captured via `HTMLCanvasElement.captureStream()`.

The override SHALL be installed whether or not the engine has a
`getDisplayMedia` of its own. Where it does (WebKit on desktop), overriding is
what makes the platform picker unreachable; where it does not (Android WebView,
iOS), defining it is what lets a site's share flow proceed on a file the user
chose rather than dead-ending. The cost — the API is present on an engine that
lacks it — is the same trade the camera shim makes by publishing a synthetic
`videoinput` on a camera-less device.

The surface SHALL be served **whole**: the canvas takes the source's own
dimensions, uniformly scaled down only to satisfy a `max` constraint the page
asked for. There is no cover-fit crop — the camera crops because a sensor fills
its frame, but a shared screen is shown entire.

When `virtual` is selected but no source has been picked, the request MUST be
denied and the picker re-offered.

#### Scenario: The picked surface is what the page receives

**Given** a site with `screenShareMode == virtual` and a picked image source
**When** the page calls `getDisplayMedia({video: true})` and samples a frame
**Then** the sampled pixels are the picked image's
**And** no display capture is started and no OS permission is requested

#### Scenario: A video source plays and loops

**Given** a site in `virtual` mode whose source is a video
**When** the page consumes the served track
**Then** the clip plays muted and repeats rather than freezing on one frame

#### Scenario: The whole surface is served, uncropped

**Given** a site in `virtual` mode whose source is 1600x900
**When** the page calls `getDisplayMedia({video: {width: {max: 800}}})`
**Then** the served track is 800x450
**And** no part of the source is cropped away

#### Scenario: Virtual selected with no source yet

**Given** a site with `screenShareMode == virtual` and no `virtualScreenSource`
**When** the page calls `getDisplayMedia()`
**Then** the request is denied (`NotAllowedError`) rather than capturing anything

### Requirement: SHARE-009 — The substitution is not detectable by shape

The synthetic surface SHALL present as an ordinary display capture at the
surfaces a fingerprinter inspects, so that ordinary sharing UIs accept it and no
script can single this browser out by the stream's shape:

- the track reports a plausible surface `label`;
- `getSettings()` reports the shape a display capture reports — `displaySurface`,
  `logicalSurface`, `cursor`, `resizeMode`, `width`, `height`, `aspectRatio`,
  `frameRate` — and NOT a camera's (no `facingMode`, no `groupId`);
- `getCapabilities()` and `getConstraints()` answer in kind, and
  `applyConstraints()` accepts a re-negotiation instead of rejecting as
  overconstrained;
- `clone()` keeps the clone presenting as the same surface, and keeps it exempt
  from the camera's deactivation stop;
- the track reports as `MediaStreamTrack` rather than
  `CanvasCaptureMediaStreamTrack`;
- the override lives on `MediaDevices.prototype` rather than on the
  `navigator.mediaDevices` instance (no own-property leak), and stringifies as
  `[native code]`;
- a track the shim did not create keeps its real label and settings.

The two gaps left open in CAM-008 (`__ws*` install markers enumerable on
`window`; a parent realm's `Function.prototype.toString` revealing an override
defined in a child realm) apply here too — they are shared by every shim in the
repo rather than specific to this one.

#### Scenario: The track does not read as a canvas capture

**Given** a served synthetic surface track under a real engine
**When** a script reads `track.constructor.name`, `track.kind`,
`Object.getOwnPropertyNames(track)` and `track.getSettings()`
**Then** it sees `MediaStreamTrack`, `video`, no own properties, and a settings
bag with `displaySurface` and without `facingMode`

#### Scenario: A foreign track is untouched

**Given** a `MediaStreamTrack` this shim did not create
**When** a script reads its `label` and `getSettings()`
**Then** it gets the engine's own values

### Requirement: SHARE-010 — Fail closed without the bridge

If the `webScreenShareRequest` Dart bridge is unreachable, or answers with
anything other than a well-formed decision, the shim SHALL deny the request.
Since there is no real-screen mode, denying is also the only honest answer
available.

#### Scenario: Missing bridge denies

**Given** the screen sharing shim is injected but `flutter_inappwebview.callHandler` is absent
**When** the page calls `getDisplayMedia()`
**Then** the request is denied (`NotAllowedError`)

#### Scenario: A malformed answer is not read as a grant

**Given** the bridge answers `null`, a string, a number, `{}` or `{mode: 'real'}`
**When** the page calls `getDisplayMedia()`
**Then** the request is denied in every case

### Requirement: SHARE-011 — Backgrounded sites deny silently

A screen sharing request from a site that is not the active one SHALL be denied
without prompting, whatever its stored `screenShareMode`, and SHALL leave the
stored mode and picked source untouched. This is CAM-011 applied to the display,
and it is carried by the same code: the gate is a required `isSiteActive`
predicate on the shared `MediaGrantEngine`.

CAM-011's first reason transfers exactly and is enough: a "share your screen?"
dialog naming an origin the user is not looking at reads as belonging to the
site that is on screen, and screen sharing is the grant a user is least willing
to misattribute. Its second — "a remembered grant would start capture with
nothing on screen" — does not apply, since there is no device here; the deny
therefore covers `virtual` as well as `ask`, matching the camera and the
microphone rather than carving out an exemption.

As with CAM-011, an answer given to a popup raised while the site was active
still applies when it settles after the switch — the user answered it — but the
next request from the now-backgrounded site is denied like any other.

`required` forces a call site to pass a predicate, not a correct one.
`test/capture_request_wiring_test.dart` drives the model's own
`resolveScreenShareRequest`, and `test/js/capture_active_gate.test.js`
structurally rejects a constant at every `isSiteActive` call site.

#### Scenario: Background site cannot raise the popup

**Given** a loaded site with `screenShareMode == ask`
**And** the user is looking at a different site
**When** a page in the background site calls `getDisplayMedia()`
**Then** no popup and no file picker are shown
**And** the request is denied
**And** the site prompts as usual once the user switches back to it

#### Scenario: Background site with a remembered surface

**Given** a loaded site with `screenShareMode == virtual` and a picked source
**And** the user is looking at a different site
**When** a page in the background site calls `getDisplayMedia()`
**Then** the bridge answers `block` and the request is rejected
**And** the site's stored mode and source are unchanged

### Requirement: SHARE-012 — No deactivation stop, and the surface survives one

CAM-012 ends any **device** camera capture when a site leaves the screen and
exempts the simulated camera. There is no device half here at all, so every
surface this feature serves is the exempt case: it is a local file drawn onto a
canvas, nothing is being observed, and ending it would drop a share the user
comes back to. No stop hook is installed and no call site pretends otherwise.

What this does require is that the camera's stop not reach the substituted
surface. This shim registers what it substituted in the same cross-shim
`globalThis.__wsSyntheticTracks` set the camera and microphone shims use, and
the camera's stop skips anything in it.

#### Scenario: Switching away leaves the simulated surface alone

**Given** a site serving its picked surface
**When** the user switches to another site and back
**Then** the track is still live and still carries the picked source

#### Scenario: The camera's stop recognises a surface track

**Given** a page holding both a simulated camera track and a simulated surface track
**When** `__wsStopRealCapture()` runs
**Then** neither track is stopped

### Requirement: SHARE-013 — The prompt names an origin the page did not choose

The origin rendered in the screen sharing decision dialog SHALL be read from the
webview (`controller.getUrl()`, falling back to the site's configured URL),
never from the shim's argument. Same reasoning as CAM-013: the handler is
reachable from page script, so a page-supplied origin would let it ask the user
for a share in another site's name. The shim passes an origin only so the
handler shape matches the other capture bridges; the Dart side ignores it.

#### Scenario: A page-supplied origin is ignored

**Given** site "Acme" is loaded at `https://acme.example/app`
**When** page script calls the `webScreenShareRequest` handler with
`"https://bank.example"` as its argument
**Then** the decision dialog names `https://acme.example/app`

### Requirement: SHARE-014 — Nested webviews prompt independently

A nested `InAppWebViewScreen` (cross-domain navigation) SHALL forward screen
sharing requests to the same popup and remember the answer in-memory for that
screen's lifetime only, mirroring the camera and microphone pattern. Nested
screens have no persisted model; the parent site's stored decision is not
inherited across the origin change.

#### Scenario: Outbound link to a page that wants a share

**Given** a site whose outbound link opens a nested webview on another domain
**When** the nested page calls `getDisplayMedia()`
**Then** the Block / Use-a-media-file popup is shown
**And** the answer is reused for further requests within that nested screen
**And** nothing is persisted

### Requirement: SHARE-015 — The stream never carries audio

The served stream SHALL contain no audio track, whatever the page requested. A
`getDisplayMedia({audio: true})` resolves video-only, which the spec permits
(system audio is best-effort), so system-audio capture is impossible by
construction rather than by refusal. An audio-only request (`video: false`) is
rejected with a `TypeError`, as in a real browser, and without raising the
popup.

#### Scenario: A request for system audio resolves without it

**Given** a site in `virtual` mode with a picked source
**When** the page calls `getDisplayMedia({video: true, audio: true})`
**Then** the resolved stream carries one video track and no audio track

#### Scenario: An audio-only request is malformed, not denied

**Given** any site
**When** the page calls `getDisplayMedia({video: false, audio: true})`
**Then** the promise rejects with a `TypeError`
**And** no popup is shown

---

## Platform notes

- **No native permission layer exists for this feature on any platform**, and
  none is added: there is no Android manifest entry, no
  `NSScreenCaptureUsageDescription`, no macOS screen-recording entitlement. The
  substitution is pure JS (canvas `captureStream`), so nothing under it needs
  one, and SHARE-003 gates the day the platform layer changes.
- **Storage**: the picked source is inlined as a `data:` URL on the model (like
  `customIconPng` and the virtual-camera source) so it rides settings backups
  and lives inside the encrypted archive slice for archive-tier sites.
  `VirtualScreenService` caps it at 24 MiB, sharing
  `VirtualVisualMediaPicker.maxBytes` with the simulated camera.
- **Element Capture, Region Capture and Captured Surface Control** operate on an
  existing display-capture track (`cropTo`, `restrictTo`, scroll/zoom control).
  Since no real one is ever handed out, they are inert here: the only track they
  could reach is a canvas the user supplied.
- **Autoplay**: Android WebView's `mediaPlaybackRequiresUserGesture = false`
  (set for CAM-010) also governs the `<video>` element behind a video surface.
- **No user-gesture gate** is enforced by the shim. Real browsers require
  transient activation for `getDisplayMedia`, but the thing that gate protects
  against — a silent capture — cannot happen here: the only surface a site can
  ever get is a file the user picked, and SHARE-011 already denies a
  backgrounded site.
- Tracking Protection does not force-block screen sharing: nothing is captured
  in any mode, so there is no tracking vector for the umbrella to close.

## Test tiers

- **Dart** — `test/screen_share_test.dart` (model, serialization, archive
  override, QR exclusion, permission-state projection, drawer badge),
  `test/screen_share_decision_engine_test.dart` (decide → coalesce → persist
  against the real engine), `test/capture_request_wiring_test.dart` (the
  model's own resolver, which is what `getWebView` installs),
  `test/screen_share_native_denial_test.dart` (SHARE-003).
- **Structural** — `test/js/screen_share_top_frame_only.test.js` (SHARE-005's
  three mechanisms), `test/js/capture_active_gate.test.js` (SHARE-011's
  predicate at every call site).
- **jsdom** — `test/js/screen_share_shim.test.js`: the decision funnel, the
  subframe deny (run inside a real jsdom iframe, since `window.top` is not
  stubbable), the uncropped surface geometry, prototype-level override
  placement, fail-closed paths. Canvas capture is stubbed; nothing about real
  frames is claimed here.
- **Real engine** — `test/browser/screen_share_real_engine.test.js`: Chromium
  serves the page from `127.0.0.1` (`getDisplayMedia` needs a secure context)
  and asserts the served frames carry the picked colour, that the track does not
  read as a canvas capture, that Chromium's own `getDisplayMedia` is unreachable
  once the shim is in (which is the assertion jsdom cannot make, having none),
  and that a cross-origin iframe is refused without reaching the bridge.
