## Why

`web-microphone-access` welds two decisions together and presents the pair as
one guarantee. The app declines to **hold** the recording capability (no
`RECORD_AUDIO`, no `NSMicrophoneUsageDescription`, no
`com.apple.security.device.audio-input`), and therefore no site can ever be
handed it. Only the second decision is the app's to make. The first belongs to
the user, and the OS already asks them.

The asymmetry with the camera is the tell. `cameraMode` has `real` because a QR
scan sometimes genuinely needs the lens. A voice message, a dictation field, a
browser-based call sometimes genuinely need the microphone, and today they
dead-end with nothing the user can do about it: the "Allowed" row on the
permissions screen is rendered greyed out with `permissionMicrophoneNeverReal`
under it. The spec's stated reason, that no recording permission is worth the
exposure, is a judgment made on the user's behalf and made permanently.

Compare the screen share, where the refusal really is structural: a display
capture is whole-surface, so granting one hands site A a live view of every
other site in the webspace, and no per-site UI can narrow what the stream
contains. Audio has no such property. A microphone stream is scoped to the
requesting page by construction, exactly like the camera. What site A hears is
the room, and the room contains nothing about site B.

The cost of holding the capability is real and this change names it rather than
eliding it. [`test/js/os_capability_declarations.test.js`](../../../test/js/os_capability_declarations.test.js)
states it as the reason for the gate: widening a permission set means "a
capability that was previously impossible becomes merely gated". Today a bug in
the shim or in the `onPermissionRequest` branch leaks nothing, because the OS
refuses before any app code runs. After this change such a bug could open a
microphone. That trade is accepted here, and it is paid for by MIC-014: an
explicit containment contract whose parts already exist, built for the camera,
and are reused rather than reinvented.

## What Changes

- **`MicrophoneAccessMode` gains `real`**, and the permissions screen's greyed
  "Allowed" row becomes selectable. Parsing changes with it: `real` is today
  mapped to `ask` defensively, which stays the correct behaviour for an older
  build reading newer JSON (a downgrade degrades a grant to a prompt) but stops
  being correct for this one.
- **A containment contract (MIC-014)** the real mode holds by construction:
  one site at a time, only the site on screen, capture ends the moment the site
  leaves the screen, a badge while it is held, never for an archive-tier site,
  never inherited by a nested webview, and the OS permission re-checked on
  every request so a revocation in system settings takes effect immediately.
- **The native layer stops denying unconditionally.** `onPermissionRequest`
  grants `MICROPHONE` only for an active site whose effective mode is `real`,
  and still answers `DENY` (never `PROMPT`) in every other case, so iOS and
  macOS never render WebKit's own per-site prompt on any path.
- **The app declares the capability**, deliberately and in one place per
  platform: `RECORD_AUDIO`, `NSMicrophoneUsageDescription`, the macOS
  `audio-input` entitlement, plus a `MicrophonePermissionService` for the
  Android runtime permission. That service and its Kotlin plugin are the
  camera's, generalised over (channel, method, permission, request code)
  rather than copied. The `os_capability_declarations` allowlists widen by
  explicit edit, and the test's header comment stops using the microphone as
  its worked example of a capability the app does not hold.
- **MIC-012 inverts.** It currently records that an audio
  `__wsStopRealCapture()` "would have an empty job". It now has one, which
  surfaces a hazard the current code is one shim away from: the hook is defined
  on `globalThis` by the camera shim alone
  ([camera_stream_shim.dart:327](../../../lib/services/camera_stream_shim.dart)),
  so a microphone shim defining its own would clobber it depending on injection
  order. The device-track registry becomes shared, mirroring the existing
  `__wsSyntheticTracks` set, and `WebViewModel.stopRealCameraCapture` is
  renamed to `stopRealCapture`.
- **Combined audio+video is split in every mode pairing**, `real` included:
  the audio half goes to the platform audio-only even when the page asked for
  video too, and the video half is re-issued through the live `getUserMedia`
  for the camera shim to answer. So the one resource that cannot be
  half-granted, the single `CAMERA_AND_MICROPHONE` iOS and macOS report for a
  combined capture, never arises from a page the shim reached. The native rule
  for it (grant only when both modes are `real`) stays as the backstop for a
  frame the shim missed or a build without it.
- **`enumerateDevices` masking follows the mode.** `real` returns the
  platform's own device list, like `block` does today; only `virtual` publishes
  the synthetic `audioinput`.

Unchanged, and stated so a reader does not have to re-derive it:

- **MIC-007** keeps `microphoneMode` out of the settings QR. A remembered
  grant is trust given to one device's popup, and that reasoning does not
  weaken when the grant is real, it strengthens.
- **MIC-006 / ARCH-006** already force `block` for archive-tier sites through
  `effectiveMicrophoneMode`, which covers `real` without a new fold.
- **MIC-005** nested webviews still decide independently and remember in
  memory only.
- **MIC-010** still fails closed without the bridge.
- **Virtual mode is untouched** in behaviour, storage and shim, and stays the
  default answer offered by the popup.

## Impact

- Affected specs: **web-microphone-access** (MIC-001, MIC-002, MIC-003,
  MIC-004, MIC-009, MIC-011, MIC-012 modified; MIC-014, MIC-015 added),
  **site-permission-badges** (one badge added to the set).
- Affected code: `lib/settings/microphone.dart`,
  `lib/settings/site_permission_state.dart`,
  `lib/services/microphone_stream_shim.dart`,
  `lib/services/camera_stream_shim.dart`,
  `lib/services/capture_track_registry.dart` (new: the shared device-track
  registry and the one `__wsStopRealCapture` installer, lifted out of the
  camera shim), `lib/services/camera_permission_service.dart` (generalised
  into `CapturePermissionService`, keeping `CameraPermissionService` and
  adding `MicrophonePermissionService` as entry points),
  `lib/services/webview.dart`, `lib/web_view_model.dart` (`stopRealCameraCapture`
  renamed `stopRealCapture`), `lib/main.dart`,
  `lib/screens/site_permissions.dart`,
  `lib/widgets/site_permission_badges.dart`, `lib/l10n/app_*.arb`.
  `lib/screens/inappbrowser.dart` needs no edit: it delegates to main.dart's
  resolver, so the nested flow inherits the new answer.
- Affected native: `android/app/src/main/AndroidManifest.xml`,
  `CameraPermissionPlugin.kt` renamed and generalised to
  `CapturePermissionPlugin.kt` (one class, a factory per capability, distinct
  request codes) with both instances registered in `MainActivity.kt`,
  `ios/Runner/Info.plist`, `macos/Runner/{DebugProfile,Release}.entitlements`.
  macOS additionally needs `NSMicrophoneUsageDescription` in
  `macos/Runner/Info.plist`, which today declares only the camera one.
- Affected gates: `test/js/os_capability_declarations.test.js` (allowlists and
  header), `test/js/camera_capture_stop_funnel.test.js` (renamed hook, plus a
  check that the registry has exactly one installer),
  `test/microphone_test.dart`, `test/capture_request_wiring_test.dart`,
  `test/site_permission_*_test.dart`,
  `test/browser/microphone_stream_real_engine.test.js` (its no-OS-capture
  assertion scoped to the mode it drives).
- New gates, both covering ground that had none:
  `test/js/native_capture_grant_gate.test.js` (the `onPermissionRequest`
  microphone branch, unreachable from any unit test and previously an
  unconditional DENY) and `test/browser/capture_stop_mixed_stream.test.js`
  (the shared stop hook splitting a mixed stream, both injection orders).
  `test/browser/lie_detection.test.js` gains the three CreepJS probes for the
  microphone shim, which it only ever ran against the camera.
- Store posture: the microphone becomes a declared capability, so Play needs
  its disclosure, the App Store needs the purpose string and a privacy-manifest
  entry, and F-Droid will surface it. None of that blocks the change; all of it
  has to be done before a release carries it.
- **Linux (WPE) is an open question.** The fork maps a video-only
  `WebKitUserMediaPermissionRequest` to `CAMERA` and honours GRANT; whether it
  maps an audio request to `MICROPHONE` and honours a grant the same way has to
  be read out of the fork before this ships there. Until it is confirmed, Linux
  keeps today's behaviour and the option is not offered on that platform.
