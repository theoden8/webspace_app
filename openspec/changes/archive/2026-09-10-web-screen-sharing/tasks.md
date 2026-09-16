## 1. Specify

- [x] 1.1 Write `openspec/changes/web-screen-sharing/specs/web-screen-sharing/spec.md`
  with SHARE-001..015.
- [x] 1.2 Modify PERMBADGE-001 to carry the `virtualScreenShare` badge and to
  say why no real-screen badge exists.
- [x] 1.3 Add the `web-screen-sharing` row to the OpenSpec table in `CLAUDE.md`,
  marked *(change)* until the change is archived.

## 2. Model and engine

- [x] 2.1 Extract `VirtualVisualSource` (`lib/settings/virtual_visual_source.dart`)
  and re-base `VirtualCameraSource` on it — same JSON, same API, no call-site
  changes.
- [x] 2.2 Add `lib/settings/screen_share.dart`: `ScreenShareMode`,
  `screenShareModeFromJson`, `VirtualScreenSource`, `ScreenShareDecision`.
- [x] 2.3 Extract `VirtualVisualMediaPicker` (extension list, MIME map, cap)
  into `virtual_media_picker.dart`; re-base `VirtualCameraService` on it and add
  `VirtualScreenService`.
- [x] 2.4 Add `ScreenShareDecisionEngine` on the shared `MediaGrantEngine`.

## 3. Shim

- [x] 3.1 Add `lib/services/screen_share_shim.dart`: override
  `MediaDevices.prototype.getDisplayMedia`, top-frame guard before the bridge,
  fail closed, canvas-backed surface served whole, display-shaped track
  overrides on `MediaStreamTrack.prototype`, never an audio track.
- [x] 3.2 Register the fixture in `tool/dump_shim_js.dart` and dump it.

## 4. Wiring

- [x] 4.1 `WebViewModel`: fields, `effectiveScreenShareMode`,
  `resolveScreenShareRequest`, `toJson`/`fromJson`, `getWebView` config, both
  `launchUrlFunc` call sites.
- [x] 4.2 `WebViewConfig.onScreenShareDecision`, the `webScreenShareRequest`
  handler registered with the frame-aware signature, and the shim injected
  `forMainFrameOnly: true`.
- [x] 4.3 Document in `onPermissionRequest` why no native display path exists
  and what to do if one appears.
- [x] 4.4 `main.dart`: the Block / Use-a-media-file popup, the picker, the
  `launchUrl` signature.
- [x] 4.5 `InAppWebViewScreen`: ctor fields, in-memory decision, engine.

## 5. UI

- [x] 5.1 `screenSharePermissionState` projection.
- [x] 5.2 A capability descriptor on the permissions screen, with the greyed-out
  "Allowed" option.
- [x] 5.3 The permissions-row summary entry and the dirty-snapshot / apply path
  in `settings.dart`.
- [x] 5.4 The `virtualScreenShare` drawer badge.
- [x] 5.5 Generalise `VirtualCameraPreview` into `VirtualSourcePreview`
  (aspect ratio + fit), so a surface previews whole rather than 4:3-cropped.
- [x] 5.6 `SiteSettingsQrCodec.excludedKeys`.
- [x] 5.7 Thirteen ARB keys across all 67 locales.

## 6. Tests

- [x] 6.1 `test/screen_share_test.dart`, `test/screen_share_decision_engine_test.dart`.
- [x] 6.2 Extend `test/capture_request_wiring_test.dart`.
- [x] 6.3 `test/screen_share_native_denial_test.dart` (SHARE-003).
- [x] 6.4 `test/js/screen_share_shim.test.js` (jsdom, subframe via a real iframe).
- [x] 6.5 `test/js/screen_share_top_frame_only.test.js` (SHARE-005 structural).
- [x] 6.6 Bump the call-site count in `test/js/capture_active_gate.test.js`.
- [x] 6.7 `test/browser/screen_share_real_engine.test.js` (Chromium).
