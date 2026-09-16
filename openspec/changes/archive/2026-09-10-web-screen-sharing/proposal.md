## Why

The app mediates every other capture surface per site — the camera serves a
picked image or video (`web-camera-access`), the microphone loops a picked clip
and never opens a device (`web-microphone-access`). `getDisplayMedia` was the
one left unmediated, and it is the surface with the worst failure mode.

A display capture is whole-surface by construction. It is not "this site's
window": on Android the only route is `MediaProjection`, which mirrors the
entire device, and on every platform this app's own window holds the drawer,
the tab strip and whichever *other* site the user switches to. A site granted a
real screen would therefore be watching every other site in the webspace —
their pages, their notifications, their logged-in state. That is precisely what
per-site cookie isolation and per-site containers exist to prevent, and no
amount of permission UI makes it acceptable.

Today nothing happens on the shipped platforms, and that is luck rather than
design: Android WebView implements no screen capture, WKWebView routes only
camera/microphone through the plugin, and the Linux WPE plugin denies a
display-device request natively because it maps to an empty resource list. A
fork bump that adds a display resource type would silently start routing such a
request into `onPermissionRequest`, where the fallback returns PROMPT — which
iOS and macOS render as WebKit's own screen picker.

Meanwhile a site that needs a share (an interview platform, a support desk, a
presentation tool) simply dead-ends, with no way for the user to satisfy it.

## What Changes

- **A per-site `screenShareMode`** — `ask` / `virtual` / `block`, with **no
  real-screen mode at all**, mirroring the microphone's asymmetry and for a
  stronger reason. `virtual` serves a `MediaStream` shaped like a shared screen
  but rendered from a user-picked image or looped video.
- **A `getDisplayMedia` shim** (`lib/services/screen_share_shim.dart`) injected
  at DOCUMENT_START and, unlike the camera and microphone shims,
  **`forMainFrameOnly: true`**. It overrides `MediaDevices.prototype.getDisplayMedia`
  whether or not the engine has one: where it does, overriding is what keeps
  the platform picker unreachable; where it does not, defining it is what lets
  a share flow proceed on a file the user chose.
- **A subframe never gets the surface, and never gets to ask.** Three
  mechanisms carry it: the injection flag, the shim's own top-frame test, and a
  Dart-side deny on `!isMainFrame` — the last of which is the only one outside
  the page's realm.
- **No audio track, ever.** `getDisplayMedia({audio: true})` resolves
  video-only, which the spec permits, so system-audio capture is impossible by
  construction rather than by refusal.
- **The existing per-site contracts apply unchanged**: the decision rides the
  shared `MediaGrantEngine` funnel (one popup per burst), a backgrounded site
  is denied without prompting, archive-tier sites deny silently, the decision
  never rides the settings QR, the prompt names an origin read from the webview
  rather than from the page, and a nested `InAppWebViewScreen` prompts
  independently and remembers in memory only.
- **A drawer badge** for a site holding a simulated surface, and a Screen
  sharing row on the per-site permissions screen with the greyed-out "Allowed"
  option that makes the guarantee visible.
- **A regression gate on the native side.** `SHARE-003` is carried by
  `test/screen_share_native_denial_test.dart`, which fails if the plugin ever
  gains a display-capture `PermissionResourceType` — so the explicit deny gets
  written before the capability arrives, not after.

Refactors that fall out, both shared with the camera rather than copied:

- `VirtualVisualSource` (`lib/settings/virtual_visual_source.dart`) — the
  picked-image-or-video value type, previously duplicated on
  `VirtualCameraSource`.
- `VirtualVisualMediaPicker` — the image/video pick, extension list and MIME
  map, previously inside `VirtualCameraService`.
- `VirtualSourcePreview` (renamed from `VirtualCameraPreview`) —
  parameterised by aspect ratio and fit, because the camera cover-fits into
  4:3 while a shared surface is shown entire.

## Impact

- Affected specs: **web-screen-sharing** (new), **site-permission-badges**
  (one badge added to the set).
- Affected code: `lib/settings/screen_share.dart`,
  `lib/settings/virtual_visual_source.dart`,
  `lib/services/screen_share_shim.dart`,
  `lib/services/screen_share_decision_engine.dart`,
  `lib/services/virtual_screen_service.dart`,
  `lib/services/virtual_media_picker.dart`, `lib/services/webview.dart`,
  `lib/web_view_model.dart`, `lib/main.dart`, `lib/screens/inappbrowser.dart`,
  `lib/screens/settings.dart`, `lib/screens/site_permissions.dart`,
  `lib/settings/site_permission_state.dart`,
  `lib/widgets/site_permission_badges.dart`,
  `lib/widgets/virtual_source_preview.dart`,
  `lib/services/site_settings_qr_codec.dart`, `lib/l10n/app_*.arb`.
- No native code is added on any platform, and no new manifest permission,
  entitlement or usage description exists to add.
