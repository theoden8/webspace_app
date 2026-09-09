Implemented on `claude/site-exploit-shims-passwords-yl5bqm`; every box below is
done and verified locally (Dart suite, JS tier, real-Chromium browser tier,
`kotlinc` + JUnit for the relay, `design:check`, `openspec validate --all`).

## 1. Capture stop out of the page's reach (CAM-012)

- [x] 1.1 `capture_track_registry.dart`: install `__wsStopRealCapture` once, `writable: false, configurable: false`, over a device-track list and substituted-track set that live in the installing closure — no `__wsRealTracks` / `__wsSyntheticTracks` globals.
- [x] 1.2 Expose `remember` / `markSynthetic` as non-enumerable properties on the hook so the sibling shims still share one registry; `markSynthetic` refuses a track already registered as device-backed.
- [x] 1.3 Carry registration onto `MediaStreamTrack.clone` and `MediaStream.clone` (the latter matched by `kind`).
- [x] 1.4 Relay the stop down `globalThis.frames` and run the local stop on receipt, so a subframe's capture is reached.
- [x] 1.5 Route `camera_stream_shim`, `microphone_stream_shim` and `screen_share_shim` through the shared block; drop `screen_share_shim`'s own copy of the set.
- [x] 1.6 Capture every primitive the hook calls (`WeakRef`, `MediaStreamTrack.prototype.stop`, its `readyState` getter, `MediaStream.prototype.getTracks`) inside the install block and invoke with `.call()` — resolved at call time, each was a writable global that neutered the stop from outside without touching the hook.
- [x] 1.7 Walk relay children by index instead of `frames`/`length` (both `[Replaceable]`), and deliver by both a direct hook call and `postMessage`.
- [x] 1.8 `test/js/capture_stop_tamper.test.js`: each bypass, both clone paths, both halves of the relay, all four primitive tampers, and the three frame-hiding tampers. Every case verified to fail against the pre-hardening registry.
- [x] 1.9 Rewrite the composition/shim tests that asserted membership of the removed globals onto the behaviour they stood for.

## 2. Frame-scoped camera and microphone grants (CAM-014 / MIC-016)

- [x] 2.1 `MediaGrantEngine.decide` takes `isTopFrame`: gate `persist`/`save` on it, and key `_inFlight` by prompt origin.
- [x] 2.2 `CameraDecisionEngine` / `MicrophoneDecisionEngine`: `real` short-circuits only for the top document; `block` and `virtual` still do.
- [x] 2.3 Hold a subframe answer for a 30s per-origin grace window so the platform's follow-up permission request does not re-prompt.
- [x] 2.4 `ScreenShareDecisionEngine` passes `isTopFrame: true` (SHARE-005 denies subframes outright).
- [x] 2.5 Thread the flag through `WebViewModel.resolveCameraRequest` / `resolveMicrophoneRequest`, `getWebView`, and the nested `InAppWebViewScreen`.
- [x] 2.6 `WebViewConfig.onCameraDecision` / `onMicrophoneDecision` take `(origin, isTopFrame)`; the two handlers move to the frame-aware callback; `_promptOrigin` names a subframe's own origin.
- [x] 2.7 Native `onPermissionRequest`: derive the frame from `request.origin` vs the live top-level origin (`_sameOrigin`).
- [x] 2.8 Engine tests for inheritance, non-persistence, the grace window and its per-origin isolation; structural gate in `page_bridge_authority.test.js`.

## 3. Media-session ownership (BGAUDIO-008)

- [x] 3.1 `MediaSessionService.report` takes `isMainFrame` and records `_ownerIsMainFrame`; a subframe claim is refused while a main frame holds the notification.
- [x] 3.2 `wsMediaSession` moves to the frame-aware callback.
- [x] 3.3 Re-check ownership after the artwork fetch: the guard runs before a network round trip on a frame-supplied URL, so a report parked there could publish after a main frame took the notification.
- [x] 3.4 Tests for the refusal, the embedded-player case that must still work, and the parked-report case (fails without the re-check).

## 4. Per-script privileged bridge (US-DR-005 / US-DR-006)

- [x] 4.1 `UserScriptConfig.bypassSitePolicy`, in `toJson`, with the absent-key default derived from `url`/`urlSource`.
- [x] 4.2 `UserScriptService.hasPrivilegedBridge` gates the shim and all three handler registrations.
- [x] 4.3 Delete the `window.fetch` patch from the shim; keep `__wsFetch` as the documented route.
- [x] 4.4 Editor switch + `HintButton` saying the weakening applies to the whole page; `userScriptsBypassSitePolicyLabel` / `...Hint` in `app_en.arb`, then the 66 translations in their own commit.
- [x] 4.5 Invert the browser tier's SOP and `connect-src` proof-of-vulnerability tests into proofs that both hold, and add one that a library still reaches `__wsFetch` by name.
- [x] 4.6 Dart tests for the bridge being absent without the flag, present with it, and unarmed by a disabled script.

## 5. Relay peer ownership (PROXY-013, in `android-auth-proxy-relay`)

- [x] 5.1 `ProxyRelay.peerVerdict` — pure parse of `/proc/net/tcp{,6}` returning OWN / FOREIGN / UNKNOWN, discriminating on the row's UID (field 7) against this process's own. The port pair alone is the row *any* caller creates, so matching it and stopping classified everyone as OWN.
- [x] 5.5 Correct the class doc and PROXY-013: `/proc/net` is denied outright from API 29, not filtered per-UID, so the check covers API 24-28 and is inert above it. No supported replacement exists.
- [x] 5.2 Gate each accepted connection before any upstream connect; log UNKNOWN once per relay, not per connection.
- [x] 5.3 Injectable `peerCheck` so a JVM test can arrange the foreign case.
- [x] 5.4 JVM tests for all three verdicts, the IPv6 table, a refused foreign peer, and a same-process peer served through the real check.

## 6. Incidental

- [x] 6.1 `content_blocker_shim.dart`: emit filter-list text with `jsonEncode` instead of the hand-rolled escaper, which missed newlines.
- [x] 6.2 Teach the nested-webview parity gate to read a `final` field whose type wraps onto a second line, and classify the two fields that surfaced.
