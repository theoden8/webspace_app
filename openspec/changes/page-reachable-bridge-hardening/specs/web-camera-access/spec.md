## MODIFIED Requirements

### Requirement: CAM-012 — Deactivation ends device capture

When a site stops being the one on screen, any capture it holds from the
**device** camera SHALL end. The **simulated** camera SHALL keep streaming:
it is a user-picked local file drawn onto a canvas, so nothing is being
observed, and ending it would drop a half-finished scan the user comes back
to. CAM-011 already denies a backgrounded site a fresh grant, so together the
two mean a site that is not on screen cannot be capturing from the camera.

Pausing is not what achieves this — a paused webview keeps media pipelines
alive by design ([webview-pause-lifecycle](../../../../specs/webview-pause-lifecycle/spec.md)).
The stop is an explicit `__wsStopRealCapture()` call into the page, which ends
every track the shim handed over from a `real` grant or passed through from a
platform-granted `getUserMedia` (the camera+microphone case of CAM-004), and
skips tracks it created itself.

Two ordering properties hold at every call site, both gated structurally by
`test/js/camera_capture_stop_funnel.test.js`:

- the stop is posted **before** `pauseWebView()`, because the iOS
  per-instance pause blocks the page's JS thread, so JS posted after it would
  not run until the site is resumed;
- it is **not** folded into `pauseWebView()`, which early-returns for
  notification and background-audio sites — exactly the sites whose JS keeps
  running while backgrounded.

The stop runs in the page's own realm, so the page can call it — which is
harmless — but SHALL NOT be able to defeat it. The hook is therefore installed
non-writable and non-configurable, its track lists are closed over rather than
held on `globalThis`, and its skip list refuses a track already registered as
device-backed. Registration SHALL carry onto a clone (`MediaStreamTrack.clone`,
`MediaStream.clone`), since a clone is independently live and stopping the
original leaves it capturing. Because Dart evaluates in the main frame only and
the shim is injected `forMainFrameOnly: false`, the hook SHALL relay the stop
down the frame tree; a relayed message can only end capture, never start it.
Regression: `test/js/capture_stop_tamper.test.js`.

#### Scenario: The page cannot neutralise the stop

**Given** a site in `real` mode holding a live camera track
**When** page script replaces `__wsStopRealCapture`, empties a global track
list, or marks its device track as substituted
**And** the user switches to another site
**Then** the track still ends

#### Scenario: A cloned device track is ended too

**Given** a site in `real` mode that cloned the track it was handed
**When** the user switches to another site
**Then** both the original and the clone end

#### Scenario: Switching away ends the camera

**Given** a site in `real` mode holding a live camera track
**When** the user switches to another site
**Then** the track ends (`readyState == 'ended'`, an `ended` event fires)
**And** the site cannot re-acquire one while it is off screen (CAM-011)

#### Scenario: The simulated camera survives a switch

**Given** a site in `virtual` mode serving its picked media file
**When** the user switches away and back
**Then** the synthetic track is still live
**And** its frames still carry the picked source

#### Scenario: Exempt-from-pause sites are not exempt from this

**Given** a backgrounded site with `notificationsEnabled` or background audio
**When** it stops being the site on screen
**Then** its device capture ends even though `pauseWebView()` skips it

## ADDED Requirements

### Requirement: CAM-014 — A device grant does not travel to a subframe

The camera shim is injected `forMainFrameOnly: false` so a QR scanner embedded
in a cross-origin frame is covered (CAM-004). That also puts a third-party ad
frame on the same handler, and `real` is the one mode that opens the device.
A settled `real` grant SHALL therefore short-circuit only for the top document;
a subframe SHALL be asked separately, and its popup SHALL name the frame's own
origin (computed by the plugin's bridge preamble, so page script can neither
forge it nor call the handler around it). The answer a subframe popup produced
SHALL apply to that request only and SHALL NOT be written back to the site's
stored mode — one frame cannot flip the whole site to `real`. Request
coalescing SHALL be keyed by prompt origin, so a subframe never rides the
answer the user gave for the top document.

The device-free answers are inherited as they are: `block` denies, and
`virtual` serves the file the user picked, which observes nothing.

Allowing a frame makes the shim call the real `getUserMedia`, and the platform
permission request that follows reaches the same resolver milliseconds later
for the same origin. A subframe answer SHALL therefore be held for a short
grace window, keyed by prompt origin, so that follow-up reuses it rather than
asking the user the same question twice. The window does not persist anything
and cannot hand back an answer given for a different frame.

Gated by `test/js/page_bridge_authority.test.js` and
`test/camera_decision_engine_test.dart`.

#### Scenario: An ad frame does not inherit the site's camera

**Given** site "Acme" is set to `real` and is the site on screen
**When** a cross-origin frame it embeds calls `getUserMedia({video: true})`
**Then** the user is asked, and the dialog names the frame's origin
**And** the site's own mode is still `real` whatever the user answers

#### Scenario: A frame's allow does not become the site's

**Given** site "Acme" is set to `ask`
**When** a cross-origin frame asks and the user allows it
**Then** the frame gets its stream
**And** the site's stored mode is still `ask`

#### Scenario: A QR scanner in a frame still works unprompted

**Given** site "Acme" is set to `virtual` with a picked image
**When** a cross-origin frame calls `getUserMedia({video: true})`
**Then** it is served the picked image with no popup
