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
- [ ] 7.2 Patch #2878 (IME dead after HTML5 fullscreen) in the fork and offer it
  upstream. Its predecessor #1176 is unresolved, so upstream will not fix it
  for us.
- [ ] 7.3 Add a `backgroundColor` **setting** for the Android native WebView
  (#2863), applied in `prepare()` beside `transparentBackground`. Not upstream
  PR #2864, which adds a runtime controller method that cannot fire before the
  first paint, and the first paint is the flash.

## 8. Cherry-picks from open upstream PRs

No maintainer has reviewed any of these, so each is a fork patch we carry, not
something to wait for. Keep each contributor's `--author` and cite
`Cherry-picked-from: <sha> (pichillilorenzo/flutter_inappwebview)`.

- [ ] 8.1 #2781, the `WEBKIT_CHECK_VERSION(2,50,0)` guard. Then flip the Linux
  CI container off `debian:sid-slim` and confirm the whole job stays green,
  including the Xvfb integration loop. The build is the only proof no other 2.50
  symbol lurks. Fix the stale comment at `build-and-test.yml:562-566` while
  there: `webkit_navigation_action_is_for_main_frame` is not in the fork.
- [ ] 8.2 #2767, the `responds(to:)` guard for `upgradeKnownHostsToHTTPS`. If we
  would rather not keep a Big Sur VM to verify it, the honest alternative is to
  raise `macos/Podfile` and `MACOSX_DEPLOYMENT_TARGET` to 12.0 and skip it.
- [ ] 8.3 #2851, console argument serialization, ported in the same commit to
  the macOS and Linux copies. Add a structural gate asserting all three
  `ConsoleLogJS` copies carry `_stringify`, so a rebase cannot silently drop two.
- [ ] 8.4 #2243, the picker sandbox filter (CVE-2020-6563). Land it with task
  6.1: it covers `file://` only, and our `content://` provider surface is the
  half that reaches `HtmlCacheService`.
- [ ] 8.5 #2881, the two Linux commits that matter: the `skip_pixel_readback_`
  gate (issue #2861) and the raster-thread use-after-free on recycled textures.
  Record the second in BUG-007, it is the same class on a new platform.
- [ ] 8.6 #2870, the macOS availability helper, before the next Xcode bump
  breaks the macOS build.
- [ ] 8.7 #2776, the `windowId` eval crash, mirrored into macOS and with its
  `callAsyncJavaScript` half dropped. It fixes the crash and not the cause, so
  file the remaining work (address-keyed statics in
  `Types/WKUserContentController.swift`) as a BUG-007 gap in the same change.

## 9. Retire the universal-link hack (#2866)

- [ ] 9.1 Cherry-pick `ALLOW_WITHOUT_TRYING_APP_LINK` and patch the fork's
  policy decode, which currently maps unknown ints to `.cancel`.
- [ ] 9.2 Verify on a device with an AASA app installed that the app is not
  backgrounded and that `Referer` and `Sec-Fetch-Site: cross-site` survive.
  The failure mode is silent: a rejected raw value degrades to a plain allow.
- [ ] 9.3 Keep `IosUniversalLinkBypass` behind a flag for one release, then
  delete it along with its eligibility predicate, 2s memo and GET/HEAD carve-out.
- [ ] 9.4 Update IOS-UL-001 and NESTED-012: the iOS half of the provenance loss
  is recovered, the Android half is not.

## 10. Guard against a harmful rebase

- [ ] 10.1 Record `preWKWebViewConfiguration` as a permanent hand-resolved
  conflict site. If #2671 ever merges, keep our block and drop theirs: its
  unconditional `nonPersistent()` assignment would silently drop both the
  container binding and the per-site proxy, with no build break.
- [ ] 10.2 Give Linux `ContainerController.isClassSupported` a real runtime
  probe rather than a static platform-name list, so a backend without
  `WebKitNetworkSession` (PR #2832's WebKitGTK, say) reports false and we fall
  back deliberately instead of reporting containers active over one shared jar.

## 11. The popup transport leak (ours)

`windowWebViews` entries are removed in exactly three places: `defaultBehaviour`
on decline, a windowId webview's own `dispose()`, and manager teardown. Our
captcha handler returns `true`, which skips the first, and
`createPopupWebView` can then bail to `SizedBox.shrink()` without ever building
an `InAppWebView(windowId:)`, which skips the second. The native popup WKWebView
stays pinned for the process lifetime on the parent's configuration and jar.

- [ ] 11.1 Decide the contract: either `onCreateWindow` must not return `true`
  on a path where `createPopupWebView` can bail, or the bail must tell the
  native side to drop the transport. Prefer the first, it needs no fork change.
- [ ] 11.2 Move both bail conditions (no recorded parent config,
  `proxyUnavailable`) ahead of the return value in
  `lib/services/webview.dart:4063-4077`, so the decision is made once.
- [ ] 11.3 Structural gate under `test/js/`: `onCreateWindow` must not return
  `true` on any path that reaches a `createPopupWebView` early return.
- [ ] 11.4 Note the ordering hazard in the fix: `_popupParentConfigs[windowId]`
  is cleared in a `finally` when `onWindowRequested` resolves, so a late
  `createPopupWebView` finds no parent and takes bail one.
