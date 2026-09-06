## 1. Record the audit

- [x] 1.1 Write `docs/upstream/flutter-inappwebview-audit.md`: the method, the
  baseline (`merge-base` against upstream master), and a verdict per issue with
  `path:line` evidence in the app tree, the fork tree, or both.
- [x] 1.2 Record the cleared issues with their reasons, not just the ones that
  affect us. The reads that ended in NO are the expensive half and the half
  that gets redone.
- [x] 1.3 Add the `upstream-webview-defects` row to the OpenSpec table in
  `CLAUDE.md`, marked *(change)* until archived.

## 2. Declined window requests (NESTED-011, EXT-009)

- [ ] 2.1 Patch the fork's iOS and macOS `onCreateWindow` `defaultBehaviour` to
  Android parity: drop the pending window transport, do not load the request
  into the parent. Mark it `[WebSpace fork patch]`.
- [ ] 2.2 Re-tag the fork and bump the six `dependency_overrides` refs in
  `pubspec.yaml` together.
- [ ] 2.3 Verify each of our four `onCreateWindow` return-`false` paths on iOS:
  blocked cross-domain, resolved intent, suppressed intent, unresolvable
  intent. Each must produce exactly the navigations the handler asked for and
  no others.
- [ ] 2.4 Add a structural gate asserting no platform's decline path calls
  `loadUrl`, so a fork rebase that reintroduces it fails at test time.

## 3. UA Client Hints fail closed (UAID-005)

- [ ] 3.1 Decide between synthesizing a WebKit/Safari brand list and suppressing
  the override, and apply the same rule to every UA that matches no known brand
  token.
- [ ] 3.2 Implement it in `lib/services/user_agent_metadata_builder.dart` so a
  null brand list can never coexist with a spoofed `platform`/`mobile`.
- [ ] 3.3 Extend the builder's tests with the shipped WebKit-shaped presets and
  a user-typed UA, asserting the two fields move together.
- [ ] 3.4 Check the `WebViewFeature.USER_AGENT_METADATA` unsupported path: the
  JS shim must not claim agreement with headers that were never overridden.

## 4. Keep the latch disarmed (#2888, #2580)

- [ ] 4.1 Add a structural gate asserting `useShouldInterceptRequest` stays
  false, `resourceCustomSchemes` stays unset, and no `WebViewAssetLoader` is
  configured. Each of those arms an unbounded native latch on chromium IO
  threads; today all four arm sites are disarmed by accident of configuration,
  not by anything that would notice a change.

## 5. 16 KB alignment (#2703)

- [ ] 5.1 Add an ELF alignment check for `libwebspace_adblock.so` beside
  `scripts/check_no_gms.sh` and `scripts/check_jni_intact.sh`, run on the built
  APK rather than on the source tree.
- [ ] 5.2 Pass `-Wl,-z,max-page-size=16384` explicitly in `scripts/build_rust.sh`
  instead of inheriting it from whichever `cargo ndk` is on `$PATH`. CI pins
  4.1.2; the signed Play build does not.
- [ ] 5.3 Update the stale NDK hint in `android/app/build.gradle` that still
  recommends r26.

## 6. Smaller hardening

- [ ] 6.1 Narrow `flutter_inappwebview_android_provider_paths.xml` from five
  roots to the external-files subdirectories the camera-capture path actually
  uses.
- [ ] 6.2 Pin `allowUniversalAccessFromFileURLs` and
  `allowFileAccessFromFileURLs` to false explicitly rather than inheriting the
  plugin defaults. We run untrusted imported HTML at a `file://` origin, so an
  upstream default flip would be immediately exploitable.
- [ ] 6.3 Register the five `console` methods into the masking funnel (ETP-025).
- [ ] 6.4 Correct the Linux row of the Platform Support Matrix in
  `openspec/specs/per-site-containers/spec.md` per CONT-009, and give
  `linux/CMakeLists.txt` a configure-time version check.

## 7. Upstream

- [ ] 7.1 File or comment on #2763 with the Android-parity patch: it is a
  cross-platform contract violation, not a WebSpace-specific need.
- [ ] 7.2 Cherry-pick the reporter's #2859 `contentInset` fix into the fork,
  keeping their `--author` and citing `Cherry-picked-from:`.
- [ ] 7.3 Patch #2878 (IME dead after HTML5 fullscreen) in the fork and offer it
  upstream. Its predecessor #1176 is unresolved, so upstream will not fix it
  for us.
- [ ] 7.4 Add a `backgroundColor` setting for the Android native WebView
  (#2863), which is the white half of BUG-001 that the repaint funnel cannot
  reach.
