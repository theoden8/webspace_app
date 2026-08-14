# Web Camera Access Specification

## Purpose

Let a site use the device camera through `getUserMedia` when the user
explicitly allows it, per site. The motivating case is web apps whose
login or payment flow scans a QR code (banking sites especially); before
this feature every platform silently denied the webview's camera
permission request, so those flows dead-ended.

Camera access is user intent, not configuration: the decision is
collected by an Allow/Block popup on first request, remembered per site,
and adjustable later from per-site settings (Ask / Always allow /
Always block).

## Status

- **Status**: Completed

---

## Requirements

### Requirement: CAM-001 — Per-site decision for camera-only requests

The webview SHALL resolve a camera-only web permission request (the
platform reports exactly one resource, `CAMERA`) from the site's
remembered decision (`WebViewModel.cameraAllowed`): `true` grants,
`false` denies, `null` shows an Allow/Block popup naming the requesting
origin and records the answer.

#### Scenario: First request prompts and remembers

**Given** a site with `cameraAllowed == null`
**When** the page calls `getUserMedia({video: true})`
**Then** an Allow/Block popup names the requesting origin
**And** the choice is stored on the model and persisted via the host's save function
**And** subsequent requests grant or deny silently from the stored value

#### Scenario: Burst requests share one popup

**Given** a site with `cameraAllowed == null`
**When** the page issues several camera permission requests before the user answers
**Then** exactly one popup is shown
**And** every in-flight request resolves with the same answer

### Requirement: CAM-002 — Settings control

Per-site settings SHALL expose the decision as a three-state control
(Ask = `null`, Always allow = `true`, Always block = `false`), and the
value SHALL ride `WebViewModel.toJson`/`fromJson` (serialized only when
non-null so untouched sites keep byte-identical JSON).

#### Scenario: Reset to Ask

**Given** a site whose stored decision is Always block
**When** the user sets the Camera access dropdown to Ask and saves
**Then** the next camera request shows the popup again

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

**Given** a site with `cameraAllowed == true`
**When** the page calls `getUserMedia({video: true, audio: true})`
**Then** the per-site camera flow does not grant the request

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

`effectiveCameraAllowed` SHALL be `false` for archive-tier sites
regardless of stored value (ARCH-006: the popup and Android's OS
permission dialog are OS-level UI). No popup is shown; the stored value
is preserved for when the site leaves the archive.

#### Scenario: Archive site requests camera

**Given** an open archive containing a site with `cameraAllowed == true`
**When** a page in that site requests the camera
**Then** the request is denied without any popup

### Requirement: CAM-007 — Decision never rides the settings QR

`cameraAllowed` SHALL be in `SiteSettingsQrCodec.excludedKeys`: a
remembered permission grant is trust the user gave one device's popup,
not shareable configuration.

#### Scenario: QR share strips the decision

**Given** a site with any non-null `cameraAllowed`
**When** the user shares the site's settings QR
**Then** the payload does not contain `cameraAllowed`

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
- Tracking Protection does not force-deny camera (unlike protected
  content, ETP-023): capture starts only after an explicit per-site
  Allow, so it is not a silent tracking vector.
