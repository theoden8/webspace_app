## Why

Every JS bridge handler and every shim the app injects is reachable from page
script: the shims are injected `forMainFrameOnly: false`, and
`flutter_inappwebview.callHandler` is callable by anything sharing the
document. `page_bridge_authority.test.js` already encodes that premise and
pins what page script may decide. This change closes five places where it
decided more than it should, found by auditing the surface rather than by a
bug report:

- The deactivation stop that ends a real camera or microphone capture was a
  writable global over globals. Three one-line edits from page script
  (`__wsStopRealCapture = () => 0`, `__wsRealTracks = []`, or adding the device
  track to the skip set) each left the device capturing while the app reported
  the capture ended — the exact failure the MIC-014 containment contract exists
  to prevent. A cloned track was never registered at all, and a subframe's
  capture was never reached, since Dart evaluates in the main frame only.
- A settled `real` camera or microphone grant short-circuited for **any**
  frame. A third-party ad frame on a site the user had allowed got the device
  silently, with no popup, and the popup that had produced the grant named the
  top document, not the frame.
- BGAUDIO-008 guarded the pause path but not the play path, so any frame
  reporting `playing: true` took over the media notification — its title,
  artwork and transport controls.
- Enabling **any** user script installed the privileged bridge, so the site's
  CSP and same-origin policy stopped applying to the whole page. `window.fetch`
  was additionally wrapped to retry cross-origin failures through that bridge
  and answer with the body, which nothing asked for.
- The Android proxy relay answered any local connection with the user's
  upstream credentials attached — an open proxy on their account for as long as
  a credentialed site was loaded.

## What Changes

- **Capture stop is out of the page's reach.** The hook is installed
  non-writable and non-configurable over a closed-over registry; the skip list
  refuses a track already registered as device-backed; registration carries onto
  `MediaStreamTrack.clone` / `MediaStream.clone`; the stop relays down the frame
  tree.
- **Camera and microphone grants are frame-scoped.** A settled `real` mode
  short-circuits only for the top document. A subframe is asked separately under
  its own origin, its answer applies to that request rather than the site's
  stored mode, and coalescing is keyed by prompt origin. Device-free answers
  (`block`, `virtual`) are still inherited, so a QR scanner in a cross-origin
  frame keeps working unprompted. A short grace window keeps the platform's own
  follow-up permission request from asking twice.
- **Only a main frame takes the media notification off a main frame.**
- **BREAKING (behavioural): the privileged bridge is now a per-script grant.**
  `UserScriptConfig.bypassSitePolicy` gates the shim and all three handlers. A
  stored script inherits it only when library-backed, which is the DarkReader
  case the bridge was built for (US-DR-001); a plain script keeps the CSP it
  should never have been costing the user.
- **`window.fetch` is no longer patched.**
- **The proxy relay serves only this app's own sockets**, checked against
  `/proc/net/tcp`, with an unreadable table treated as unverifiable rather than
  hostile.
- Filter-list text is emitted as JSON rather than hand-escaped, so a pattern
  carrying a newline can no longer end the string literal and silence every
  shim concatenated after it.

## Capabilities

**New Capabilities**: none. Every fix tightens behaviour an existing spec
already owns.

**Modified Capabilities**:

- `user-scripts` — US-DR-005 (the bridge is granted per script) and US-DR-006
  (`window.fetch` is left alone) are added; the shim description is corrected.
- `web-camera-access` — CAM-012 gains the tamper-resistance, clone and
  subframe-relay contract; CAM-014 (a device grant does not travel to a
  subframe) is added.
- `background-audio` — BGAUDIO-008 gains the play-path rule.

The microphone and proxy halves of this work live with the in-flight changes
that introduce the behaviour they amend, rather than here, so that no two
changes modify the same requirement:

- **MIC-012** (the mic side of the capture-stop contract) and **MIC-016** (the
  mic half of CAM-014) go to `real-microphone-mode`, which already holds the
  MODIFIED MIC-012 and introduces the `real` mode they constrain.
- **PROXY-013** (relay peer ownership) goes to `android-auth-proxy-relay`,
  since the relay does not exist outside it.

Archiving any of the three in any order is therefore safe.

## Impact

- **Code**: `capture_track_registry.dart` and the three capture shims;
  `media_grant_engine.dart`, `camera_decision_engine.dart`,
  `microphone_decision_engine.dart`, `screen_share_decision_engine.dart`;
  `web_view_model.dart`, `webview.dart` (`WebViewConfig.onCameraDecision` /
  `onMicrophoneDecision` signatures, three handlers moved to the frame-aware
  callback), `inappbrowser.dart`; `media_session_service.dart`;
  `user_script.dart`, `user_script_service.dart`, `user_script_shim.dart`,
  `screens/user_scripts.dart`; `content_blocker_shim.dart`;
  `android/.../proxy/ProxyRelay.kt`.
- **Persistence**: `UserScriptConfig` gains `bypassSitePolicy`, which rides
  `toJson` and therefore settings backup (US-005). No migration flag: the
  absent-key default is derived from the script itself.
- **Localization**: two new keys, `userScriptsBypassSitePolicyLabel` and
  `userScriptsBypassSitePolicyHint`.
- **Tests**: a new `test/js/capture_stop_tamper.test.js`; the browser tier's
  proof-of-vulnerability tests for the SOP and `connect-src` bypass are
  inverted into proofs that both now hold; new structural gates in
  `page_bridge_authority.test.js`. The nested-webview parity gate could not see
  a `final` field whose type wrapped onto a second line — fixing its parser
  surfaced two fields that had never been classified.
- **Not addressed**: the shim marker globals (`__ws_*`) remain page-readable
  and identify the app and its enabled features; the `__wsFetch` confirmation
  asymmetry (US-006) and the DNS-rebinding half of the SSRF guard are unchanged
  and still pinned by their tests.
