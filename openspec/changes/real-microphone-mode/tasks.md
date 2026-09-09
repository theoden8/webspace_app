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
- [x] 1.4 Update the `web-microphone-access` one-liner in the `CLAUDE.md`
  OpenSpec table once implemented, and mark the slug *(change)* until archived.

## 2. Model and state

- [x] 2.1 `lib/settings/microphone.dart`: add `MicrophoneAccessMode.real`;
  `microphoneAccessModeFromJson` parses it; update the enum doc comment, which
  currently states there is deliberately no real mode.
- [x] 2.2 `MicrophoneDecision.toBridgeJson`: `real` passes through; `ask` keeps
  degrading to `block`.
- [x] 2.3 `lib/settings/site_permission_state.dart`:
  `microphonePermissionState` maps `real` to `SitePermissionState.allowed`;
  delete the doc comment asserting it never returns `allowed`.
- [x] 2.4 `WebViewModel`: `effectiveMicrophoneMode` needs no change (the
  archive fold already forces `block`); confirm with a test rather than by
  reading.

## 3. Shim

- [x] 3.1 `lib/services/microphone_stream_shim.dart`: a `real` decision calls
  through to the platform `getUserMedia` for the audio half instead of
  synthesising, and registers the resulting tracks in the shared device-track
  registry (task 3.3).
- [x] 3.2 `enumerateDevices` masking applies only in `virtual` mode; `real`
  returns the platform list unmodified, like `block`.
- [x] 3.3 Extract the device-track registry and the `__wsStopRealCapture` hook
  out of `camera_stream_shim.dart` into a shared installer over
  a closed-over registry, installed once, iterating both shims' tracks and
  skipping substituted ones. A second installation must not displace the
  first (MIC-012).
- [x] 3.4 Combined-request matrix (MIC-004): `real` issues a platform
  audio-only request in every camera pairing and combines it with whatever the
  camera shim serves, so the platform's combined resource never arises from a
  shimmed page; a failing video half stops the device audio track it already
  obtained.
- [x] 3.5 Re-dump fixtures (`fvm dart run tool/dump_shim_js.dart`) and run
  `fvm flutter test test/js_fixtures_drift_test.dart`.

## 4. Native

- [x] 4.1 `android/app/src/main/AndroidManifest.xml`: add `RECORD_AUDIO`.
- [x] 4.2 Generalise `CameraPermissionPlugin.kt` into `CapturePermissionPlugin.kt`,
  parameterised by (channel, method, permission, request code) with `camera()`
  and `microphone()` factories, and register both in `MainActivity`. A second
  copy of the plugin would have been the copy the repo's "code flows new →
  stable" rule forbids; separate request codes keep the two prompts from
  resolving each other's waiters.
- [x] 4.3 Generalise `camera_permission_service.dart` into
  `CapturePermissionService`, with `CameraPermissionService` and
  `MicrophonePermissionService` as named entry points over it. Re-checks on
  every request and caches nothing (MIC-015). No new file: the camera path and
  its tests reach for the old name.
- [x] 4.4 `ios/Runner/Info.plist`: `NSMicrophoneUsageDescription`.
- [x] 4.5 `macos/Runner/Info.plist`: `NSMicrophoneUsageDescription`;
  `macos/Runner/{DebugProfile,Release}.entitlements`:
  `com.apple.security.device.audio-input`.

## 5. Wiring

- [x] 5.1 `lib/services/webview.dart` `onPermissionRequest`: replace the
  unconditional `MICROPHONE` deny with the MIC-003 decision (grant only for an
  active `real` site holding the app-level permission), keep `DENY` rather than
  `PROMPT` on every other path, and handle `CAMERA_AND_MICROPHONE` only when
  both modes are `real`. Rewrite the comment block above it, which currently
  documents the opposite guarantee.
- [x] 5.2 `lib/web_view_model.dart`: rename `stopRealCameraCapture` to
  `stopRealCapture`, update its doc comment and both call sites in `main.dart`.
- [x] 5.3 `main.dart`: `_resolveMicrophoneDecision` gains an Allow button,
  reusing the existing `homeAllowAction` key. `InAppWebViewScreen` needed no
  edit — it delegates to this resolver, so the nested flow got the button for
  free.

## 6. UI

- [x] 6.1 `lib/screens/site_permissions.dart`: the microphone capability's
  `SitePermissionState.allowed` option becomes enabled, drops
  `unavailableReason`, and stores `real`.
- [x] 6.2 `lib/widgets/site_permission_badges.dart`: add
  `SitePermissionBadge.realMicrophone`, include it in `opensRealDevice`, icon
  `Icons.mic`, and place it before `virtualMicrophone` in the order.
- [x] 6.3 ARB: add the Allow label and the hint text explaining what a real
  grant means and when it ends; delete `permissionMicrophoneNeverReal`.
  Code plus `app_en.arb` in one commit, the other 66 locales in the next,
  pushed together.

## 7. Tests

- [x] 7.1 `test/microphone_test.dart`: replace "there is no mode that opens the
  real device" and the `'real'` parses-to-`ask` assertion with the new parsing
  and serialization, including the downgrade direction.
- [x] 7.2 `test/capture_request_wiring_test.dart`: `real` is denied for a
  backgrounded site and for an archive-tier site, granted for an active one.
- [x] 7.3 `test/js/os_capability_declarations.test.js`: flip the three
  microphone absence assertions to presence, rewrite the header comment, leave
  every other set untouched.
- [x] 7.4 `test/js/camera_capture_stop_funnel.test.js`: follow the rename and
  extend to the microphone shim's registration, so a shim that hands over a
  device track without registering it fails.
- [x] 7.5 `test/js/microphone_stream_shim.test.js`: `real` passes through,
  `enumerateDevices` is unmasked in `real`, the combined-request matrix.
- [x] 7.6 `test/site_permission_badges_test.dart`,
  `test/site_permission_state_test.dart`,
  `test/site_permissions_screen_test.dart`: the new badge, state and enabled
  option.
- [x] 7.7 `test/browser/capture_stop_mixed_stream.test.js`: under real
  Chromium, both shims in one realm and both injection orders, the stop ends
  the device audio half of a mixed stream and spares the simulated video half.
  This is the *mechanism* behind the MIC-014 derived clause.
- [ ] 7.7a The derived clause itself ("at most one site is capturing") is not
  proven end to end: no test drives two sites and asserts that granting B ended
  A's track. It needs the integration tier, since it spans a site switch.
- [x] 7.8 `test/browser/microphone_stream_real_engine.test.js`: the existing
  tier asserts the page's `microphone` permission state never moves. Scoped to
  the mode it actually drives, since it is no longer true of the feature.
- [x] 7.9 `test/js/native_capture_grant_gate.test.js`: the `onPermissionRequest`
  microphone branch is a closure no unit test can reach, and it went from an
  unconditional DENY to a grant. Structural gate over its clauses, mutation
  tested against four ways to widen it.
- [x] 7.10 `test/browser/lie_detection.test.js`: the tier probed the camera
  shim only. MIC-009 makes the same undetectability claims for audio, so the
  same three probes now run against the microphone shim.
- [ ] 7.11 Exercise the `AudioContext` resume-on-gesture path (MIC-008) for
  real: start the context suspended, assert the shim resumes it, and assert the
  gesture retry when the first resume is refused. jsdom stubs `resume()` to a
  resolved promise and the browser harness calls it itself, so today an engine
  that suspends would hand the page a silent track with both tiers green.
  Pre-existing, not introduced by this change.

## 8. Release

- [ ] 8.1 Play data-safety and permission disclosure for `RECORD_AUDIO`.
- [ ] 8.2 App Store purpose string and privacy-manifest entry.
- [ ] 8.3 F-Droid: the new permission is surfaced to users; mention it in the
  changelog under the fastlane byte caps.
- [ ] 8.4 Re-run the ARCH-006 per-site feature audit, as MIC-014 requires when
  a feature gains a real device mode.
