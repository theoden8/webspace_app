## 1. Specify

- [x] 1.1 Write `openspec/changes/real-microphone-mode/specs/web-microphone-access/spec.md`
  (MIC-001, 002, 003, 004, 009, 011, 012 modified; MIC-014, MIC-015 added).
- [x] 1.2 Modify PERMBADGE-001 to carry the `realMicrophone` badge, based on
  the `web-screen-sharing` version of the requirement.
- [ ] 1.3 Confirm the Linux WPE fork's audio path before writing any Linux
  behaviour into the spec: does a `WebKitUserMediaPermissionRequest` for audio
  map to `MICROPHONE`, and is GRANT honoured the way the camera's is? Until
  confirmed, MIC-015 keeps Linux at today's behaviour and the UI does not offer
  the real option there.
- [ ] 1.4 Update the `web-microphone-access` one-liner in the `CLAUDE.md`
  OpenSpec table once implemented, and mark the slug *(change)* until archived.

## 2. Model and state

- [ ] 2.1 `lib/settings/microphone.dart`: add `MicrophoneAccessMode.real`;
  `microphoneAccessModeFromJson` parses it; update the enum doc comment, which
  currently states there is deliberately no real mode.
- [ ] 2.2 `MicrophoneDecision.toBridgeJson`: `real` passes through; `ask` keeps
  degrading to `block`.
- [ ] 2.3 `lib/settings/site_permission_state.dart`:
  `microphonePermissionState` maps `real` to `SitePermissionState.allowed`;
  delete the doc comment asserting it never returns `allowed`.
- [ ] 2.4 `WebViewModel`: `effectiveMicrophoneMode` needs no change (the
  archive fold already forces `block`); confirm with a test rather than by
  reading.

## 3. Shim

- [ ] 3.1 `lib/services/microphone_stream_shim.dart`: a `real` decision calls
  through to the platform `getUserMedia` for the audio half instead of
  synthesising, and registers the resulting tracks in the shared device-track
  registry (task 3.3).
- [ ] 3.2 `enumerateDevices` masking applies only in `virtual` mode; `real`
  returns the platform list unmodified, like `block`.
- [ ] 3.3 Extract the device-track registry and the `__wsStopRealCapture` hook
  out of `camera_stream_shim.dart` into a shared installer over
  `globalThis.__wsRealTracks`, installed once, iterating both shims' tracks and
  skipping `__wsSyntheticTracks`. A second installation must not displace the
  first (MIC-012).
- [ ] 3.4 Combined-request matrix (MIC-004): `real`/`virtual` issues a platform
  audio-only request and combines it with the camera shim's video track;
  `real`/`real` issues the combined request unchanged; a failing video half
  stops the device audio track it already obtained.
- [ ] 3.5 Re-dump fixtures (`fvm dart run tool/dump_shim_js.dart`) and run
  `fvm flutter test test/js_fixtures_drift_test.dart`.

## 4. Native

- [ ] 4.1 `android/app/src/main/AndroidManifest.xml`: add `RECORD_AUDIO`.
- [ ] 4.2 `MicrophonePermissionPlugin.kt` beside `CameraPermissionPlugin.kt`,
  channel `org.codeberg.theoden8.webspace/microphone_permission`, registered
  where the camera one is.
- [ ] 4.3 `lib/services/microphone_permission_service.dart`: a
  `CameraPermissionService` twin, re-checking on every request and caching
  nothing (MIC-015).
- [ ] 4.4 `ios/Runner/Info.plist`: `NSMicrophoneUsageDescription`.
- [ ] 4.5 `macos/Runner/Info.plist`: `NSMicrophoneUsageDescription`;
  `macos/Runner/{DebugProfile,Release}.entitlements`:
  `com.apple.security.device.audio-input`.

## 5. Wiring

- [ ] 5.1 `lib/services/webview.dart` `onPermissionRequest`: replace the
  unconditional `MICROPHONE` deny with the MIC-003 decision (grant only for an
  active `real` site holding the app-level permission), keep `DENY` rather than
  `PROMPT` on every other path, and handle `CAMERA_AND_MICROPHONE` only when
  both modes are `real`. Rewrite the comment block above it, which currently
  documents the opposite guarantee.
- [ ] 5.2 `lib/web_view_model.dart`: rename `stopRealCameraCapture` to
  `stopRealCapture`, update its doc comment and both call sites in `main.dart`.
- [ ] 5.3 `main.dart` and `InAppWebViewScreen`: the popup gains an Allow
  button; nothing else in the decision funnel changes.

## 6. UI

- [ ] 6.1 `lib/screens/site_permissions.dart`: the microphone capability's
  `SitePermissionState.allowed` option becomes enabled, drops
  `unavailableReason`, and stores `real`.
- [ ] 6.2 `lib/widgets/site_permission_badges.dart`: add
  `SitePermissionBadge.realMicrophone`, include it in `opensRealDevice`, icon
  `Icons.mic`, and place it before `virtualMicrophone` in the order.
- [ ] 6.3 ARB: add the Allow label and the hint text explaining what a real
  grant means and when it ends; delete `permissionMicrophoneNeverReal`.
  Code plus `app_en.arb` in one commit, the other 66 locales in the next,
  pushed together.

## 7. Tests

- [ ] 7.1 `test/microphone_test.dart`: replace "there is no mode that opens the
  real device" and the `'real'` parses-to-`ask` assertion with the new parsing
  and serialization, including the downgrade direction.
- [ ] 7.2 `test/capture_request_wiring_test.dart`: `real` is denied for a
  backgrounded site and for an archive-tier site, granted for an active one.
- [ ] 7.3 `test/js/os_capability_declarations.test.js`: flip the three
  microphone absence assertions to presence, rewrite the header comment, leave
  every other set untouched.
- [ ] 7.4 `test/js/camera_capture_stop_funnel.test.js`: follow the rename and
  extend to the microphone shim's registration, so a shim that hands over a
  device track without registering it fails.
- [ ] 7.5 `test/js/microphone_stream_shim.test.js`: `real` passes through,
  `enumerateDevices` is unmasked in `real`, the combined-request matrix.
- [ ] 7.6 `test/site_permission_badges_test.dart`,
  `test/site_permission_state_test.dart`,
  `test/site_permissions_screen_test.dart`: the new badge, state and enabled
  option.
- [ ] 7.7 A test for the MIC-014 derived clause: granting site B ends site A's
  device track, so at most one capture is live.
- [ ] 7.8 `test/browser/microphone_stream_real_engine.test.js`: the existing
  tier asserts the page's `microphone` permission state never moves. That
  assertion is now mode-scoped, not global; keep it for `virtual` and `block`.

## 8. Release

- [ ] 8.1 Play data-safety and permission disclosure for `RECORD_AUDIO`.
- [ ] 8.2 App Store purpose string and privacy-manifest entry.
- [ ] 8.3 F-Droid: the new permission is surfaced to users; mention it in the
  changelog under the fastlane byte caps.
- [ ] 8.4 Re-run the ARCH-006 per-site feature audit, as MIC-014 requires when
  a feature gains a real device mode.
