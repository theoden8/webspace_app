# Web Microphone Access — real mode delta

## MODIFIED Requirements

### Requirement: MIC-001 — Per-site decision, including a real-microphone mode

`MicrophoneAccessMode` SHALL have exactly four values: `ask`, `real`,
`virtual`, `block`. A `getUserMedia` that asks for audio SHALL resolve from
the site's mode: `real` hands over the device microphone (MIC-014), `virtual`
serves the picked clip (MIC-008), `block` denies, and `ask` shows a Block /
Use-audio-file / Allow popup naming the requesting origin and records the
answer.

The feature no longer claims that no site is ever handed a microphone. It
claims something narrower and enforceable: no site is handed one without the
user saying so for that site, and no site holds one while it is off screen.
The OS decides whether the app may record at all, which is the decision the
app was previously making on the user's behalf by not declaring the
capability.

`microphoneAccessModeFromJson` SHALL parse `real` as `MicrophoneAccessMode.real`.
An older build reading that JSON degrades it to `ask` (its parser has no such
value and falls back), which is the correct direction for a downgrade: a grant
becomes a prompt, never the reverse.

#### Scenario: First request prompts and remembers

**Given** a site with `microphoneMode == ask`
**When** the page calls `getUserMedia({audio: true})`
**Then** a Block / Use-audio-file / Allow popup names the requesting origin
**And** the chosen mode is stored on the model and persisted via the host's save function
**And** subsequent requests resolve silently from the stored mode

#### Scenario: Burst requests share one popup

**Given** a site with `microphoneMode == ask`
**When** the page issues several audio requests before the user answers
**Then** exactly one popup / file-pick is shown
**And** every in-flight request resolves with the same answer

#### Scenario: A stored grant survives a round trip

**Given** persisted JSON whose `microphoneMode` reads `real`
**When** the model is loaded
**Then** the mode is `real` and the next request resolves without a popup

### Requirement: MIC-002 — Settings control

Per-site settings SHALL expose the decision as a four-way control (Ask /
Allowed / Audio file / Block). The "Allowed" option, previously rendered
disabled with an `unavailableReason`, SHALL become selectable and SHALL carry
the row's hint rather than an unavailable note. Selecting Audio file SHALL
prompt for the source file and SHALL show the chosen file's name.
`microphoneMode` and any `virtualMicrophoneSource` SHALL ride
`WebViewModel.toJson`/`fromJson` (`microphoneMode` serialized only when not
`ask` so untouched sites keep byte-identical JSON).

`microphonePermissionState` SHALL map `real` to `SitePermissionState.allowed`,
which is what draws the row and its badge in the error colour via
`opensRealDevice`. The doc comment stating that this function never returns
`allowed` is removed with the mode it described.

#### Scenario: Reset to Ask

**Given** a site whose stored mode is Block
**When** the user sets the Microphone access dropdown to Ask and saves
**Then** the next audio request shows the popup again

#### Scenario: Untouched sites keep their JSON

**Given** a site the user has never given a microphone decision
**When** its model is serialized
**Then** neither `microphoneMode` nor `virtualMicrophoneSource` appears

#### Scenario: The allowed row is reachable

**Given** the per-site permissions screen for a site
**When** the user opens the Microphone access row
**Then** the "Allowed" option is enabled and selecting it stores `real`

### Requirement: MIC-003 — The native layer grants only an active real site

The webview's `onPermissionRequest` SHALL respond to a request whose resources
include `MICROPHONE`:

- `GRANT`, when the requesting site's `effectiveMicrophoneMode` is `real`, the
  site is the one on screen, and the app-level recording permission is held
  (MIC-015);
- `DENY` otherwise.

It SHALL NOT fall through to `PROMPT` in either case. The fall-through is what
the original requirement existed to close and the reason survives the mode:
Android and Linux WPE map `PROMPT` to deny, but iOS 15+/macOS 12+ render it as
WebKit's own per-site prompt, which is a second permission decision the app
does not control and cannot reconcile with the per-site one it just made.

A request reporting `CAMERA_AND_MICROPHONE` (the single resource iOS and macOS
report for a combined capture) cannot be half-granted, so it SHALL be granted
only when `effectiveCameraMode == real` **and** `effectiveMicrophoneMode ==
real` and the site is active, and denied otherwise. MIC-004 covers what the
page sees in the mixed pairings, which never reach this path.

#### Scenario: An allowed site reaches the device

**Given** an on-screen site with `microphoneMode == real` and the app-level permission held
**When** the native permission request arrives for `MICROPHONE`
**Then** it is granted

#### Scenario: A backgrounded allowed site does not

**Given** a site with `microphoneMode == real` that is not the one on screen
**When** the native permission request arrives
**Then** it is denied, with no WebKit or OS prompt

#### Scenario: A half-granted combined request is refused

**Given** a site with `microphoneMode == real` and `cameraMode == block`
**When** a `CAMERA_AND_MICROPHONE` request arrives on iOS or macOS
**Then** it is denied

### Requirement: MIC-004 — Composition with the camera

A request for audio AND video SHALL resolve to one `MediaStream` carrying both
halves, or fail as a whole. Per the `getUserMedia` contract a request fails
when a requested kind cannot be provided, so a `block` microphone SHALL reject
a combined request rather than silently downgrading it to video-only, and a
failing video half SHALL tear down whatever the audio half built rather than
leaking a running `AudioContext` or an open device the page can no longer
reach.

How the halves are obtained depends on the pairing:

| Microphone | Camera | Audio half | Video half |
|---|---|---|---|
| `virtual` | any | synthesised (MIC-008) | re-issued through the live `getUserMedia`, `audio` constraint removed |
| `real` | any | platform **audio-only** `getUserMedia` | re-issued the same way |
| `block` | any | rejects the whole request | not issued |

The re-issue SHALL use the LIVE `navigator.mediaDevices.getUserMedia`, not the
function captured at install time, so the camera shim resolves it per
`cameraMode` regardless of which shim was injected last. Re-entry terminates
because a video-only request always falls through the microphone shim.

The audio half is requested **audio-only even when the page asked for video
too**, in `real` as in `virtual`. That is what keeps the video half the camera
shim's decision in every pairing, and it means a page this shim reached never
produces the platform's combined `CAMERA_AND_MICROPHONE` resource at all. The
rule MIC-003 states for that resource is therefore a backstop for a frame the
shim did not reach or a build without it, not the normal path.

#### Scenario: Virtual microphone and virtual camera together

**Given** a site with `microphoneMode == virtual` and `cameraMode == virtual`, both with sources
**When** the page calls `getUserMedia({audio: true, video: true})`
**Then** the resolved stream carries one synthetic audio track and one synthetic video track
**And** neither the real microphone nor the real camera is opened

#### Scenario: Real microphone with a simulated camera

**Given** an on-screen site with `microphoneMode == real` and `cameraMode == virtual` with a source
**When** the page calls `getUserMedia({audio: true, video: true})`
**Then** the resolved stream carries one device audio track and one synthetic video track
**And** no combined `CAMERA_AND_MICROPHONE` request is issued

#### Scenario: Real microphone with a real camera is still two requests

**Given** an on-screen site with `microphoneMode == real` and `cameraMode == real`
**When** the page calls `getUserMedia({audio: true, video: true})`
**Then** the platform receives one audio-only request and one video-only request
**And** neither carries both kinds

#### Scenario: Blocked microphone fails the whole combined request

**Given** a site with `microphoneMode == block`
**When** the page calls `getUserMedia({audio: true, video: true})`
**Then** the request is rejected with `NotAllowedError`
**And** no video-only request is issued to the platform

#### Scenario: A failing video half does not strand the audio half

**Given** a site with `microphoneMode == virtual` whose camera decision denies
**When** the page calls `getUserMedia({audio: true, video: true})`
**Then** the request rejects
**And** the synthetic audio's `AudioContext` is closed

#### Scenario: A failing video half does not strand a device microphone

**Given** an on-screen site with `microphoneMode == real` whose camera decision denies
**When** the page calls `getUserMedia({audio: true, video: true})`
**Then** the request rejects
**And** the device audio track obtained for the audio half is stopped

### Requirement: MIC-009 — The substitution is not detectable by shape

In `virtual` mode the synthetic microphone SHALL present as an ordinary
capture device at the surfaces a fingerprinter inspects, so that ordinary
capture UIs accept it and no script can single this browser out by the
stream's shape:

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

In `real` mode there is no substitution to hide: `enumerateDevices` SHALL
return the platform's own list unmodified, and the device's own label,
settings and capabilities SHALL reach the page, exactly as in `block` mode
today. The masking is a property of the simulation, not of the feature, and
extending it to a real grant would misreport the hardware the user chose to
expose.

The two gaps left open in CAM-008 (`__ws*` install markers enumerable on
`window`; a parent realm's `Function.prototype.toString` revealing an override
defined in a child realm) apply here too. They are shared by every shim in the
repo rather than specific to this one.

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
`getUserMedia` and the user is offered the popup

#### Scenario: Block mode leaves the device list alone

**Given** a site in `block` mode
**When** the page calls `enumerateDevices()`
**Then** the platform's own device list is returned unmodified

#### Scenario: Real mode leaves the device list alone

**Given** a site in `real` mode on a device with two microphones
**When** the page calls `enumerateDevices()`
**Then** both `audioinput` entries are reported with their platform labels
**And** no synthetic entry is added

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
predicate on the shared `MediaGrantEngine`, so neither feature, nor a future
one, can add a call site without answering it.

Both of CAM-011's reasons now transfer, where previously only one did. "A
background site's popup reads as belonging to the site on screen" always
applied: a Block / Use-audio-file / Allow dialog naming an origin the user is
not looking at is the same trap regardless of which sensor it claims. With a
real mode, "a remembered grant would start capture with nothing on screen"
applies too, and it is the sharper of the two: a backgrounded site resolving
`real` would open the microphone behind another site's page.

The deny covers `virtual` as well, unchanged. A backgrounded site that got its
clip would be observing nothing, but the popup argument covers it and the
uniform rule is what keeps the gate one predicate rather than a per-mode
table.

As with CAM-011, only the grant is gated; the non-prompting `webMicrophoneMode`
read behind `enumerateDevices` is not, because the shim caches it for the
document's lifetime.

`required` forces a call site to pass a predicate, not a correct one:
`isSiteActive: () => true` compiles and keeps every engine test green. Two
further gates close that. `test/capture_request_wiring_test.dart` drives the
model's own `resolveMicrophoneRequest` / `resolveCameraRequest`, the wiring
`getWebView` installs, so a model that mistranslates the host predicate or
drops the archive-tier fold fails. `test/js/capture_active_gate.test.js`
structurally rejects a constant at every `isSiteActive` call site, which is
the only reach available for `InAppWebViewScreen`'s `mounted` predicate: no
unit test can get at it without mounting a platform view.

#### Scenario: Background site cannot raise the popup

**Given** a loaded site with `microphoneMode == ask`
**And** the user is looking at a different site
**When** a page in the background site requests audio
**Then** no popup and no file picker are shown
**And** the request is denied
**And** the site prompts as usual once the user switches back to it

#### Scenario: Background site with a remembered grant

**Given** a loaded site with `microphoneMode == real`
**And** the user is looking at a different site
**When** a page in the background site calls `getUserMedia({audio: true})`
**Then** the bridge answers `block`, the request is rejected, and no device is opened
**And** the site's stored mode is unchanged

#### Scenario: Background site with a remembered clip

**Given** a loaded site with `microphoneMode == virtual` and a picked clip
**And** the user is looking at a different site
**When** a page in the background site calls `getUserMedia({audio: true})`
**Then** the bridge answers `block` and the request is rejected
**And** the site's stored mode and clip are unchanged

### Requirement: MIC-012 — Deactivation ends device capture, and the clip survives it

When a site stops being the one on screen, any capture it holds from the
**device** microphone SHALL end. The **simulated** microphone SHALL keep
streaming: it is a user-picked local file looped through a WebAudio graph, so
nothing is being observed, and ending it would drop playback the user comes
back to. MIC-011 already denies a backgrounded site a fresh grant, so together
the two mean a site that is not on screen cannot be capturing audio.

This requirement previously recorded that the audio equivalent of
`__wsStopRealCapture()` "would have an empty job" and installed no such hook.
It has a job now, and giving it one surfaces a hazard the previous design was
one shim away from: the hook is defined on `globalThis` by the camera shim
alone, so a microphone shim defining its own would silently replace it, and
which capture survives a site switch would depend on injection order.

Therefore the hook SHALL be installed once over a **shared device-track
registry**: each shim appends the device tracks it hands over, whichever shim
installs the hook iterates the shared registry, and a second installation SHALL
NOT displace the first. Tracks a shim substituted SHALL continue to be skipped,
so a combined stream carrying one device track and one synthetic track loses
exactly the device half.

The registry is shared between shims but SHALL NOT be shared with the page.
Dart can only reach the hook by name from the page's own realm, so the name is
page-reachable and calling it is harmless; everything reachable through it is
not. Specifically: the hook SHALL be installed non-writable and
non-configurable, the track lists SHALL be closed over rather than held on
`globalThis`, and the skip list SHALL refuse a track already registered as
device-backed (a device track is registered while the `getUserMedia` promise is
still resolving, so the page cannot reach one before the registry does). Each
of the three was a one-line bypass while the hook was a writable global over
globals: the microphone kept recording with the app reporting capture ended.
Registration SHALL carry onto a clone, which is independently live. Because
Dart evaluates in the main frame only while the shim is injected
`forMainFrameOnly: false`, the hook SHALL relay the stop down the frame tree.
Regression: `test/js/capture_stop_tamper.test.js`.

The camera's two ordering properties hold unchanged for audio and are gated by
the same structural test:

- the stop is posted **before** `pauseWebView()`, because the iOS
  per-instance pause blocks the page's JS thread, so JS posted after it would
  not run until the site is resumed;
- it is **not** folded into `pauseWebView()`, which early-returns for
  notification and background-audio sites, exactly the sites whose JS keeps
  running while backgrounded.

`WebViewModel.stopRealCameraCapture` is renamed `stopRealCapture`: it now ends
both device captures, and a name that says camera would leave the next reader
believing audio is exempt, which is what this requirement used to say.

#### Scenario: Switching away ends a device microphone

**Given** an on-screen site with `microphoneMode == real` holding a live audio track
**When** the user switches to another site
**Then** the track ends (`readyState == 'ended'`, an `ended` event fires)
**And** the site cannot re-acquire one while it is off screen (MIC-011)

#### Scenario: Switching away leaves the simulated microphone alone

**Given** a site serving its picked clip, alone or alongside a simulated camera
**When** the user switches to another site and back
**Then** the audio track is still live and still carries the clip

#### Scenario: The stop hook recognises an audio track it did not create

**Given** a stream carrying a simulated video track and a simulated audio track
**When** the deactivation stop runs
**Then** neither track is stopped
**And** the call reports having stopped nothing

#### Scenario: One hook covers both shims whatever the injection order

**Given** both the camera and microphone shims are injected, in either order
**And** a site holding one device audio track and one device video track
**When** the deactivation stop runs
**Then** both tracks end

#### Scenario: Exempt-from-pause sites are not exempt from this

**Given** a backgrounded site with `notificationsEnabled` or background audio
**When** it stops being the site on screen
**Then** its device audio capture ends even though `pauseWebView()` skips it

## ADDED Requirements

### Requirement: MIC-014 — The containment contract for a real grant

Holding the recording capability is only defensible if what the app does with
it is narrower than what the OS granted. The OS grants "this app may record".
The app SHALL reduce that to "this site, while the user is looking at it,
visibly, and not if it is archived". Every clause below is a property some
other requirement already carries; this requirement exists so the set is
readable in one place and so a future capture feature has a contract to copy
rather than a precedent to reconstruct.

| Clause | Carried by |
|---|---|
| A site holds the microphone only after the user allowed it for that site | MIC-001 |
| Only the site on screen can be granted | MIC-011 |
| Capture ends when the site leaves the screen | MIC-012 |
| At most one site is capturing at any moment | MIC-011 + MIC-012 together |
| The grant is visible in the drawer while held | PERMBADGE-001 |
| An archive-tier site is never granted, and its stored intent survives | MIC-006 / ARCH-006 |
| A nested webview decides for itself and persists nothing | MIC-005 |
| A subframe cannot obtain what the top frame was denied | MIC-013 + MIC-016 |
| The page cannot defeat the stop that ends capture | MIC-012 |
| The decision is never shared as configuration | MIC-007 |
| No bridge means no grant | MIC-010 |

"At most one site is capturing" is a derived property, not a separate
mechanism, and it SHALL stay derived: it follows from a grant requiring the
site to be active and deactivation ending capture, so nothing needs to track a
global capture owner. A future change that lets a backgrounded site keep
capturing (a call that survives a site switch, say) breaks this clause and
SHALL introduce the owner it then needs, rather than quietly widening MIC-011.

The contract SHALL be re-read whenever a per-site feature gains a real device
mode, and the ARCH-006 per-site feature audit SHALL be re-run at that time.

#### Scenario: Two sites cannot capture at once

**Given** site A on screen holding a device audio track
**When** the user switches to site B and site B is granted the microphone
**Then** site A's track has ended
**And** exactly one device audio capture is live

#### Scenario: The grant is visible while it is held

**Given** a site with `microphoneMode == real`
**When** its drawer tile renders
**Then** a microphone badge is drawn in the error colour

#### Scenario: An archive-tier site is never granted

**Given** an open archive containing a site with `microphoneMode == real`
**When** a page in that site requests audio
**Then** the request is denied without any popup and no device is opened
**And** the stored mode is unchanged

### Requirement: MIC-015 — The app holds the capability, deliberately and revocably

The app SHALL declare the recording capability on each platform that can
serve a real grant, and SHALL treat that declaration as a security surface
rather than configuration:

- Android: `android.permission.RECORD_AUDIO` in the manifest, plus a
  `MicrophonePermissionService` (channel
  `org.codeberg.theoden8.webspace/microphone_permission`) that requests the
  runtime permission on demand at grant time. `PermissionRequest.grant()`
  fails silently without it, the same way the camera does. The camera's plugin
  and service are generalised rather than copied: one
  `CapturePermissionPlugin` parameterised by (channel, method, permission,
  request code) with a factory per capability, and one
  `CapturePermissionService` behind the two named entry points. Each capability
  SHALL keep its own request code, so a prompt for one never resolves the
  waiters queued on the other.
- iOS: `NSMicrophoneUsageDescription`. Responding GRANT suppresses only
  WebKit's per-site prompt; WebKit itself triggers the app-level TCC prompt
  when capture starts.
- macOS: `NSMicrophoneUsageDescription` in `macos/Runner/Info.plist` (which
  today declares only the camera one) and the
  `com.apple.security.device.audio-input` sandbox entitlement in both
  entitlements files.
- Linux (WPE): **unverified.** The fork maps a video-only user-media request
  to `CAMERA` and honours GRANT; whether it maps an audio request to
  `MICROPHONE` and honours a grant the same way has not been read out of the
  fork. The option is offered there like everywhere else, and the failure
  direction if the fork does not route audio is safe: the request never
  reaches Dart and WPE denies it natively, so an allowed site gets a denial
  rather than an unannounced capture. What it costs is a setting that silently
  does nothing, which is why confirming the path stays an open task rather
  than a note. Do not write a Linux-specific behaviour into this requirement
  before reading the fork.

The app-level permission SHALL be re-checked on every request and cached
nowhere, so a permission the user revokes in system settings stops the next
request without the user touching the site setting, and a permission granted
later starts working the same way. Per-site intent lives on
`microphoneMode`; OS state is read, never mirrored.

`test/js/os_capability_declarations.test.js` SHALL be updated by explicit
edit: the three absence assertions naming the microphone are replaced by
presence assertions, and the file's header stops using the microphone as its
worked example of a capability the app does not hold. The gate's purpose is
unchanged and is the reason the edit must be explicit: widening a set turns an
impossibility into a gate, and that is a decision, not a manifest line.

The camera's declarations, and every other set the gate pins, SHALL be left
alone by this change.

#### Scenario: A revoked OS permission stops the next request

**Given** an on-screen site with `microphoneMode == real` that captured successfully
**When** the user revokes the app's microphone permission in system settings
**And** the page requests audio again
**Then** the request is denied
**And** the site's stored mode is still `real`

#### Scenario: A re-granted OS permission needs no site edit

**Given** the site from the previous scenario
**When** the user re-grants the app's microphone permission in system settings
**And** the page requests audio again
**Then** the request is granted

#### Scenario: The declaration gate names what the app now holds

**Given** the OS capability declaration test
**When** it runs against the manifests
**Then** `RECORD_AUDIO`, `NSMicrophoneUsageDescription` and
`com.apple.security.device.audio-input` are asserted present
**And** the location absences are asserted exactly as before

### Requirement: MIC-016 — A device grant does not travel to a subframe

The microphone shim is injected `forMainFrameOnly: false`, so a third-party ad
frame reaches the same handler as the page, and `real` is the mode that hands
over the device under the MIC-014 containment contract. A settled `real` grant
SHALL therefore short-circuit only for the top document; a subframe SHALL be
asked separately, its popup SHALL name the frame's own origin, and the answer
SHALL apply to that request only rather than being written back to the site's
stored mode. Request coalescing SHALL be keyed by prompt origin, so a subframe
never rides the answer the user gave for the top document. The device-free
answers are inherited as they are: `block` denies, and `virtual` loops the clip
the user picked, which records nothing.

This is the camera's CAM-014 verbatim, on the same shared grant engine, including
the grace window that keeps the platform's follow-up request from asking the
user twice.

#### Scenario: An ad frame does not inherit the site's microphone

**Given** site "Meet" is set to `real` and is the site on screen
**When** a cross-origin frame it embeds calls `getUserMedia({audio: true})`
**Then** the user is asked, and the dialog names the frame's origin
**And** the site's own mode is still `real` whatever the user answers

#### Scenario: A frame's allow does not become the site's

**Given** site "Meet" is set to `ask`
**When** a cross-origin frame asks and the user allows it
**Then** the site's stored mode is still `ask`
