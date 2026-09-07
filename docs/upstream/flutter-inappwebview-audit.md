# Upstream audit: flutter_inappwebview

We ship a fork of `flutter_inappwebview` pinned by `dependency_overrides` in
[pubspec.yaml](../../pubspec.yaml), so upstream releases never reach us on their
own and upstream's issue tracker is not a feed we can ignore: a defect filed
there is a defect in code we compile, and a fix landed there is a fix we do not
have until someone rebases the fork.

This file is the record of reading that tracker. One section per audit, dated,
appended, never rewritten. Each entry says what the fork ref was at the time, so
a later reader can tell whether a verdict still holds.

**What belongs here:** the per-issue verdict and the evidence for it, including
the verdicts of NO. "We checked #2555 and we do not take that path" is the
expensive half of the work and the half that gets redone if nobody writes it
down.

**What does not:** the behaviour we decided to require as a result. That goes in
the owning OpenSpec capability, and a bug whose symptom recurs across code paths
goes in [docs/bugs/](../bugs/). This file links out to both. Work that lands in
the fork rather than here has its own standalone brief:
[fork-work-brief.md](fork-work-brief.md).

## Method

1. Resolve the baseline: `git merge-base` between the pinned fork ref and
   `upstream/master`. Everything upstream has that we do not is backlog we
   carry; everything we have on top is fork surface only we can break.
2. Harvest the open issues. The GitHub HTML listing truncates each page, so
   sort both ascending and descending by created and by updated, and take the
   union rather than trusting a single pass.
3. Batch by category and triage each issue against **both** trees: the app, and
   the fork at the pinned ref. A verdict without a `path:line` in at least one
   of them is a guess.
4. Verdicts are AFFECTS / MAYBE / NO. NO needs a reason of the form "we never
   call it", "it is guarded at our ref", or "that platform is not shipped", not
   "it looks unrelated".

Platforms shipped: Android, iOS, macOS, Linux. Windows and web are not shipped
(`web/` exists only for the design gallery, where no WebView runs), so issues
confined to them are NO by construction.

## Audit 2026-09-06

**Fork ref:** `v6.2.0-beta.3-privacy-v6`
**Baseline:** `merge-base(fork, upstream/master)` = `17527cae`, which *is*
upstream master HEAD. The fork is upstream master plus 19 commits, all additive
(containers, `proxySettings`, three Android settings, cookie flush/memo fixes).

That baseline is the single most useful fact in this audit: **we carry no
upstream backlog.** Every issue of the form "fixed on master but never
released" is already fixed for us, which disposes of #2886 and #2709 outright.

**Coverage:** 131 of 144 open issues read. The 13 unread are most likely
Windows/web given how the remainder distributed, but they are unread, not
cleared.

### Affects us

| # | Title | Verdict | Evidence | Disposition |
|---|---|---|---|---|
| 2763 | iOS `onCreateWindow` return value ignored | AFFECTS, high | fork iOS `InAppWebView.swift:2762-2766` calls `self?.loadUrl(navigationAction.request)` in `defaultBehaviour`; Android `InAppWebViewChromeClient.java:675-679` only drops the pending message; our handler returns `false` on every path but the captcha popup (`lib/services/webview.dart:4054-4141`) | NESTED-011, EXT-009 |
| 2834 | Suppress/customize `Sec-CH-UA` | AFFECTS, medium (residual) | `lib/services/user_agent_metadata_builder.dart:49-62` ships `platform`/`mobile` with a null `brandVersionList`; fork `InAppWebView.java:2370-2372` then skips `setBrandVersionList`, leaving the real brands | UAID-005 |
| 2878 | Soft keyboard dead app-wide after HTML5 fullscreen | AFFECTS, high | fork `InAppWebViewChromeClient.java:151-179` `onHideCustomView` restores system UI and orientation, never the IME; zero `InputMethodManager` references in the file | fork patch, no spec |
| 2718 | ANR in `MyCookieManager.deleteAllCookies` | AFFECTS, medium | fork `MyCookieManager.java:445-460` flushes on the platform thread, and our own `flushContainerCookieManagers()` (`:535-556`) fans that out across every profile; callers `lib/main.dart:6315`, `:9548`, `lib/services/cookie_isolation.dart:155` | BUG-007 gap 5 |
| 2703 | 16 KB page size | AFFECTS, medium (release) | no `max-page-size` flag anywhere in the repo; alignment is incidental, from `CARGO_NDK_VERSION: "4.1.2"` (`.github/workflows/build-and-test.yml:25`) against NDK r26d, and CI builds only `--flavor fdroid` (`:367-369`) | tasks 5.x |
| 2863 | Android native WebView background color | AFFECTS, low-medium | fork `InAppWebView.java:397-398` sets `Color.TRANSPARENT` only when `transparentBackground` is set, which we never set outside `lib/widgets/virtual_source_preview.dart:97` | [BUG-001](../bugs/001-white-screen.md) |
| 2850 | iOS `console.log` coerces objects | AFFECTS, low-medium | fork's `ConsoleLogJS` concatenation is identical on iOS, macOS and Linux; consumed raw at `lib/services/webview.dart:4405-4406` | ETP-025 (the fingerprinting half) |
| 2873 | Restrict FileProvider paths | AFFECTS, low-medium | our `android/app/src/main/res/xml/flutter_inappwebview_android_provider_paths.xml` carries five roots against upstream's one | tasks 6.x |
| 2791 | `shouldOverrideUrlLoading` always returns true | AFFECTS, medium | `lib/services/webview.dart:3531` sets `useShouldOverrideUrlLoading` unconditionally; fork `InAppWebViewClient.java:105` returns `request.isForMainFrame()` even on ALLOW, reissuing at `:145` | NESTED-012, documentation only |
| 2780 | `webkit_web_view_get_theme_color` on WebKit < 2.50 | AFFECTS, build | one unguarded call at fork `flutter_inappwebview_linux/linux/in_app_webview/in_app_webview.cc:6268`; no `WEBKIT_CHECK_VERSION` anywhere in the Linux plugin | CONT-009; fixed by PR #2781 |
| 2861 | Linux white screen under `DISABLE_GL=1` | AFFECTS, users only | env var read at `custom_platform_view.cc:18`, never consulted by the buffer path; CI uses llvmpipe instead (`.github/workflows/build-and-test.yml:811`) | [BUG-001](../bugs/001-white-screen.md) |
| 2862 | Cannot build on Ubuntu | AFFECTS, docs | fork `flutter_inappwebview_linux/linux/CMakeLists.txt:47-63` probes 2.0/1.1/1.0 and never version-checks | CONT-009 |
| 2883 | Flutter 3.47 UI separation | AFFECTS on next upgrade | `.fvmrc` pins 3.38.6 | fork rebase, blocks the bump |
| 2880, 2882 | iOS 27 SDK deprecations | AFFECTS on next upgrade, low | fork `InAppBrowserNavigationController.swift:14`, `InAppBrowserManager.swift:131`, both in native `InAppBrowser` we never instantiate | compile-time only |
| 2728 | Android 15 nav/status bar color APIs | AFFECTS now, cosmetic | fork `InAppBrowserActivity.java:122`; `targetSdk 36` makes the setter a no-op but Play's static scan reads the artifact | fork patch to silence |

### Watch list

Reachable in principle, no evidence we hit it, no action taken.

- **#2867 + #2600**, the `windowId` KVO crash. One mechanism, two reporters:
  `observeValue` to `initializeWindowIdJS` to a JS eval on a window webview
  whose `plugin`/`channelDelegate` are swapped in mid-flight, against an
  unsynchronised `windowWebViews` dictionary. We are unusually exposed because
  every captcha opens a `windowId` popup (`lib/services/webview.dart:1852`) and
  the iOS universal-link bypass reissues every gesture navigation. Same shape as
  [BUG-007](../bugs/007-native-shared-state-races.md) on the Swift side.
- **#2727, #2713**, iOS 26 dead touch after a dialog or drawer closes. Our whole
  settings UX is dialogs over a live webview and the drawer is primary
  navigation, so if these are real we would see them everywhere on iOS 26.
  Needs a device.
- **#2491**, renderer crash navigating back. Worst case for us is a rebuild,
  which [BUG-002](../bugs/002-black-screen.md) already absorbs.
- **#2695**, `ERR_NAME_NOT_RESOLVED` after a long background. Our
  `onReceivedError` suppression branch loads `about:blank`
  (`lib/services/webview.dart:4471-4478`), which is the reporter's symptom.
- **#2697, #2721**, multi-window and display-size changes. We suppress activity
  recreate via `configChanges` (`android/app/src/main/AndroidManifest.xml:32`),
  so we sit on the non-adapting path by construction.
- **#2493, #2135**, bottom-of-page inputs not scrolled into view. One item, not
  two. Likely the same root as #2859 on iOS; retest after that lands.
- **#2826**, macOS fractional-width frame drift. Would read as
  [BUG-008](../bugs/008-viewport-scale.md) if a user hit it. None has.

### Cleared, with the reason

Recording these is the point of the file: each one cost a read of both trees.

| # | Reason |
|---|---|
| 2888 | The unbounded latch is real (fork `Util.java:99-109`) but all four arm sites are disarmed for us: `useShouldInterceptRequest = false` (`lib/services/webview.dart:3537`), no `resourceCustomSchemes`, no `WebViewAssetLoader`, `setServiceWorkerClient(null)` (`lib/main.dart:646`). Gated by task 4.1 so it stays that way. |
| 2580 | Same gate. Our subresource interception is native (`WebInterceptPlugin.kt`) and never crosses to Dart, so the reported deadlock cannot occur. |
| 2886, 2709 | Fixed at our ref (`webview_asset_loader.dart:242` already spreads `super.toMap()`), and we use `HtmlCacheService`, not `WebViewAssetLoader`. |
| 2848 | Both file-URL flags default `false` (fork `InAppWebViewSettings.java:74-75`) and we never set them. Latent, not live: we do run untrusted HTML at a `file://` origin with `allowFileAccess = true` (`lib/services/webview.dart:3547`), so an upstream default flip would be immediately exploitable. Task 6.2 pins them. |
| 2745 | The `eval()` is in `flutter_inappwebview_web` (not shipped) and in an Android path reached only when `contentWorld != PAGE`, which we never pass. |
| 2712 | We already built it: `FastSubresourceInterceptor` blocks by hostname before the fetch. |
| 2673, 2594 | Guarded by try/catch at our ref, and we never set `forceDark`. |
| 2555 | The IME proxy hack is gated on `!useHybridComposition`; we leave hybrid composition on. |
| 2868 | Needs a custom `contextMenu`, which we never pass. |
| 2819 | We subscribe to neither `onEnterFullscreen` nor `onExitFullscreen`. |
| 2753 | We discard subframe errors anyway (`lib/services/webview.dart:4432`). |
| 2707, 2855, 2730, 2619, 2570 | Native `InAppBrowser`, `ContextMenu`, `targetFrame`, `callAsyncJavaScript`, autofill: none referenced in `lib/`. Our `lib/screens/inappbrowser.dart` is a Flutter route, not the plugin's native browser. |
| 2723, 2795, 2598, 2340, 2821 | Require a scroll ancestor, a `Slider`, a `Draggable` or a `BackdropFilter` over a live webview. We have none. |
| 2859 | **Corrected 2026-09-07.** Listed as AFFECTS in the first pass; it is not. `keyboardWillShow` only takes the negative-inset branch when `scrollView.adjustedContentInset != .zero`, and `contentInsetAdjustmentBehavior` defaults to `NEVER` (`in_app_webview_settings.dart:3561-3562`) with no override in `lib/`, so adjusted equals `contentInset`, which starts `.zero`. The branch is never entered and `keyboardWillHide` clears a flag that was never set. Becomes live the moment we set `contentInsetAdjustmentBehavior` or `resizeToAvoidBottomInset: false`. |
| 2415, 2762 | Fixed in Flutter 3.38.6, which `.fvmrc` already pins. |
| 2654 | Reported against 5.8/6.0; `dispose()` at our ref removes every observer symmetrically. |
| 2887, 2830 | Our AGP (8.13.1) and iOS deployment target (15.0) are past the reporters' boundaries. |
| 2687, 2685, 2641, 1627, 2178, 2796, 2757 | Warnings with no `-Werror`, a `compileSdk` we already exceed, a package we do not depend on, or `pana`, which we never run (`publish_to: 'none'`). |
| 2807, 2615, 460, 2798 | System WPE, Windows, a 2020 meta-issue, and `keepAlive`, which we never use. |
| ~40 Windows/web issues | Not shipped. |

### Findings that are ours, not upstream's

Two of the threading findings came out of reading upstream's reports and then
looking at our own code. They are recorded where they belong rather than here:

- The adblock engine's write lock spans a full filter-list parse on the platform
  thread, and `checkUrl`'s read lock is unbounded:
  [BUG-007 gap 5](../bugs/007-native-shared-state-races.md).
- `DNS_READY_TIMEOUT_MS` is 15s (`WebInterceptPlugin.kt:846`), three times the
  ANR window: same gap.

## Audit 2026-09-07: open pull requests

Same baseline. The issue sweep found defects; this pass asks whether anyone has
already fixed them, and whether an unmerged PR would help or hurt us on the next
fork rebase. All **72** open PRs read, diffs fetched rather than rendered pages.

Two facts shape every verdict. Our fork sits on upstream master, so an open PR is
genuinely unmerged, not something we already carry. And **no maintainer has
reviewed any of these**, so "wait for upstream" is not a plan: anything we want,
we carry as a fork patch.

### Take

| # | What | Why it is worth carrying |
|---|---|---|
| 2781 | Linux: `#if WEBKIT_CHECK_VERSION(2,50,0)` around `webkit_web_view_get_theme_color` | The single thing pinning our Linux CI to `debian:sid-slim`. We never call `getMetaThemeColor` from Dart, so returning nothing below 2.50 costs us nothing, and it makes trixie and ParrotOS buildable. Guards the 2.50-only `WebKitColor` type as well as the call, so it is complete. |
| 2767 | macOS: `responds(to: "setUpgradeKnownHostsToHTTPS:")` instead of `#available(macOS 11.3)` | We advertise Big Sur (`macos/Podfile:1` targets 10.15), the setting defaults to `true`, and the assignment is on the path every macOS webview creation takes. An affected user crashes on first site load. The selector check is strictly stronger than the availability check, which is what fails here. |
| 2851 | iOS: serialize console arguments instead of string-concatenating them | Fixes #2850 on one of the three platforms where we are degraded. Port the same `_stringify` into the macOS and Linux copies in the same commit; they carry the byte-identical bug. |
| 2243 | Android: reject picker results that canonicalize under the app data dir | CVE-2020-6563's mitigation for the plugin's own file picker. We never set `useOnShowFileChooser`, so we take the unfiltered default path. Does **not** close our variant: it covers `file://` only, and our FileProvider maps five roots over the whole data dir with `grantUriPermissions="true"`, so a `content://` result still reaches `HtmlCacheService` blobs. Pick it and narrow the provider paths. |
| 2881 | Linux: re-import DMA-BUF per frame on Flutter's EGLDisplay | Two of its five commits matter. One is #2861's actual cause: `OnWpePlatformBufferRendered` sets `buffer_handled = true` on any DMA-BUF import even in software mode, so the pixel buffer is never filled and the texture stays blank. The other fixes a raster-thread use-after-free on recycled textures, which is BUG-007's shape on Linux. |
| 2870 | macOS: availability-annotated `ASWebAuthenticationPresentationContextProviding` helper | We never use `WebAuthenticationSession`, but it compiles into the macOS plugin and CI builds macOS on `macos-latest`. This is a build break waiting for the next Xcode. |

### Take, but verify on a device first

- **#2776**, `windowId` EXC_BAD_ACCESS. Routes around the faulting
  `evaluateJavaScript(_:frame:contentWorld:)` overload. Behaviour-neutral for us
  because our content world is always `.page`. Needs mirroring into the macOS
  twin, and its `callAsyncJavaScript` half dropped. It fixes the crash, not the
  cause: see "still owed" below.
- **#2866**, `NavigationActionPolicy.ALLOW_WITHOUT_TRYING_APP_LINK`. The right
  shape for `ios-universal-link-bypass`: it suppresses app-link matching on the
  original `WKNavigationAction` instead of cancelling and reissuing it, so
  `Referer`, `window.opener` and `Sec-Fetch-Site: cross-site` all survive. It
  would delete `lib/services/ios_universal_link_bypass.dart` outright and
  recover the iOS half of NESTED-012. Three caveats: iOS and macOS only, so the
  Android half of NESTED-012 stays open; our fork decodes unknown policy ints to
  `.cancel`, so the Dart enum alone is not enough; and the failure mode is
  silent, since a rejected raw value degrades to a plain allow and universal
  links resume with nothing in the logs. Keep the old path behind a flag for one
  release and prove the new policy on a device before deleting it.

### Never take

- **#2671**, WKWebView proxy for iOS 17+. Assigns
  `WKWebsiteDataStore.nonPersistent()` unconditionally at the end of the same
  `preWKWebViewConfiguration` block our container binding and per-site proxy live
  in (`flutter_inappwebview_ios/.../InAppWebView.swift:745-772`). If it landed
  and we rebased naively, its assignment would run after ours and silently drop
  both: every iOS site sharing one ephemeral jar on the global proxy. That is a
  per-site-containers failure and an `ip-leakage` failure at once, and neither
  shows up as a build break. Treat `preWKWebViewConfiguration` as a permanent
  hand-resolved conflict site.
- **#2832**, WebKitGTK backend for Linux. It would make us build on Ubuntu, and
  it would cost us Linux isolation silently. It targets `webkit2gtk-4.1`, a
  generation with no `WebKitNetworkSession` at all, which is the type our whole
  Linux container layer is built on. Worse, `ContainerController.isClassSupported`
  is a static platform-name list with no runtime probe, so `_useContainers` would
  stay `true`, `containerId` would be accepted and ignored, and every site would
  share one cookie jar while the UI reported containers active.
- **#2771** (disables all content-world JS: `frame: nil` is how the plugin says
  "main frame"), **#1952** (shadows a loop binding, returns empty credentials),
  **#2694** (comments out the iOS Apple Pay guard). All three are regressions
  presented as fixes.

### Wrong remedy for a real problem

- **#2864** adds a runtime `setBackgroundColor` controller method for #2863. A
  runtime call cannot fire before the platform view's first paint, and the first
  paint *is* the flash. The fix belongs in `prepare()` beside
  `transparentBackground`, as a setting.
- **#2729** adds `Build.VERSION.SDK_INT` to `TrustedWebActivity.java` without
  adding `import android.os.Build`, which is absent at our ref. It does not
  compile. Pick it only with the import added.

### Watch

- **#2844** defers Android JS bridge registrations off platform-view attach,
  fixing a real cold-start race. Not as-is: it defers plugin scripts but not
  user-only scripts, inverting DOCUMENT_START order so our shims would run
  before the bridge, and both its catch blocks log and continue, which is
  fail-open injection. If we take it, defer both and make the catch fail closed.
- **#2829** (system nlohmann) would break our Linux job until
  `nlohmann-json3-dev` joins the apt set. **#2817** (Java deprecations) collides
  with our two cookie flush/memo commits in `MyCookieManager.java`.

### Still owed after all of the above

#2776 fixes the eval call, not the state behind it. The fork keeps
`contentWorlds`, `userOnlyScripts` and `pluginScripts` in process-global static
dictionaries keyed by the object's pointer formatted as a string
(`Types/WKUserContentController.swift:18-53`, and the macOS twin), unsynchronised.
`getContentWorlds` already carries a scar comment about `EXC_BREAKPOINT` when the
set mutates mid-loop, mitigated with a copy rather than a lock: BUG-007 exactly.
The quiet consequence is worse than the crash. A controller freed without
`dispose()` leaves its entry behind, and the next controller at that address
inherits it, so `containsPluginScript` reports scripts that were never added and
`sync()` skips them. That is a site whose per-site shims silently never inject.

Separately, ours to fix: `windowWebViews` entries are removed in only three
places (`InAppWebView.swift:2764` on decline, `:3656` on a windowId webview's own
dispose, `:128` on manager teardown). Our captcha handler returns `true`, so the
first never runs, and `createPopupWebView` can still bail to `SizedBox.shrink()`
(`lib/services/webview.dart:1858-1865`) without building an
`InAppWebView(windowId:)`, so the second never runs either. The native popup
WKWebView stays pinned for the process lifetime on the parent's configuration and
cookie jar.

### Correction to the 2026-09-06 audit

**#2859 does not affect us** and its row has moved to the cleared table. The
negative-inset branch is guarded by `adjustedContentInset != .zero`, and
`contentInsetAdjustmentBehavior` defaults to `NEVER` with no override in `lib/`.

Also stale, and worth fixing while we are here: the comment at
`.github/workflows/build-and-test.yml:562-566` justifies the sid pin with two
WebKit 2.50 symbols, but `webkit_navigation_action_is_for_main_frame` does not
appear anywhere in the fork. `webkit_web_view_get_theme_color` is the only one,
which is why #2781 alone should free the pin. The Linux build is the proof, not
the comment.

## Upstream beyond the plugin: WebKit

The plugin is not the only upstream we depend on. On Linux the fork binds to WPE
WebKit's GLib API, so a missing WebKit API is our problem too.

### WebKit PR 65415, main-frame status on `WebKitNavigationAction`

<https://github.com/WebKit/WebKit/pull/65415> (ours, open, currently
merging-blocked) adds `webkit_navigation_action_is_for_main_frame()` to the
WPE/GTK GLib bindings, mirroring `WKNavigationAction.targetFrame.isMainFrame` on
Cocoa. Without it the `decide-policy` signal cannot distinguish a main-frame
navigation from a subframe one: `webkit_navigation_action_get_frame_name()`
returns NULL for an ordinary unnamed iframe, which is indistinguishable from the
main frame.

The fork implements exactly the heuristic the PR describes as forced
(`flutter_inappwebview_linux/linux/in_app_webview/in_app_webview.cc:3966-3972`):

```c
// Best-effort main frame detection: frame name is usually null/empty for main frame.
bool is_for_main_frame = true;
const gchar* frame_name = webkit_navigation_action_get_frame_name(nav_action);
if (frame_name != nullptr && frame_name[0] != '\0') is_for_main_frame = false;
```

It defaults to `true`, which is the unsafe direction, and an unnamed cross-origin
iframe hits that default.

**None of that is a new discovery.** [PR #356](https://github.com/theoden8/webspace_app/pull/356)
(open since 2026-05-17, currently conflicted) already documents it in the
`nested-url-blocking` spec: "the Linux plugin can't reliably mark iframe
navigations as non-main-frame (`webkit_navigation_action_get_frame_name()` is
the *target* frame name, not the source, so iframes whose own URL navigates show
up with `isForMainFrame=true`). The result is that those iframes can open a
nested webview. Per-site `blockAutoRedirects = false` is the escape hatch."
`lib/services/webview.dart:3920-3923` carries the same observation as a comment.

What that write-up does not name is the **second** consequence, which is worse
than the nested webview and has no escape hatch. Past the main-frame gate sit the
ClearURLs rewrite and the ABP `$removeparam` rewrite, and both respond to a match
by calling `controller.loadUrl(cleanedUrl)` on the **top** frame and cancelling
the original load. So an iframe whose URL merely carries a stripped tracking
parameter navigates the whole page to that iframe's URL. The comment at
`:3930-3933` states the intent this violates: "a cross-origin subframe navigation
must never be able to steer the top document." There is no `Platform.isLinux`
guard anywhere in `webview.dart`, and `blockAutoRedirects = false` does not
disable the rewrites.

Two tracks, and they are independent:

- **Root fix:** land PR 65415, then replace the heuristic in the fork's
  `OnDecidePolicy` with the real API. That also retires the guessing in
  `create_window_action.cc:41`, which hardcodes `isForMainFrame(true)`.
- **Until then:** the app must not steer the top document on a main-frame signal
  it cannot trust. NESTED-013 states that; it is a WebSpace-side fix that needs
  no WebKit change and should not wait for one. It supersedes PR #356's
  "disable the feature per site" escape hatch for the rewrite half, which that
  hatch never covered.

PR #356 itself is worth rescuing separately: it is a two-line fix plus spec text
for a different signal on the same handler (`hasGesture`, not `isForMainFrame`),
it has been conflicted since August, and NESTED-013 touches the same spec
section, so land one before writing the other.

Note for whoever revisits the Linux CI comment: the claim at
`.github/workflows/build-and-test.yml:562-566` that the plugin calls
`webkit_navigation_action_is_for_main_frame` describes the *intended* end state,
not the present one. The symbol does not exist in shipped WebKit yet, which is
what PR 65415 is for, and nothing in the fork calls it. Only
`webkit_web_view_get_theme_color` actually forces the 2.50 floor today.
