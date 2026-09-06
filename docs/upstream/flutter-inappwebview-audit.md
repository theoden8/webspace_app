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
goes in [docs/bugs/](../bugs/). This file links out to both.

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
| 2859 | iOS 17.2+ scroll stuck after keyboard dismiss | AFFECTS, medium | fork iOS `InAppWebView.swift:189-193` applies a negative `contentInset`; `:201-203` `keyboardWillHide` only clears `_scrollViewContentInsetAdjusted` | cherry-pick reporter's PR |
| 2718 | ANR in `MyCookieManager.deleteAllCookies` | AFFECTS, medium | fork `MyCookieManager.java:445-460` flushes on the platform thread, and our own `flushContainerCookieManagers()` (`:535-556`) fans that out across every profile; callers `lib/main.dart:6315`, `:9548`, `lib/services/cookie_isolation.dart:155` | BUG-007 gap 5 |
| 2703 | 16 KB page size | AFFECTS, medium (release) | no `max-page-size` flag anywhere in the repo; alignment is incidental, from `CARGO_NDK_VERSION: "4.1.2"` (`.github/workflows/build-and-test.yml:25`) against NDK r26d, and CI builds only `--flavor fdroid` (`:367-369`) | tasks 5.x |
| 2863 | Android native WebView background color | AFFECTS, low-medium | fork `InAppWebView.java:397-398` sets `Color.TRANSPARENT` only when `transparentBackground` is set, which we never set outside `lib/widgets/virtual_source_preview.dart:97` | [BUG-001](../bugs/001-white-screen.md) |
| 2850 | iOS `console.log` coerces objects | AFFECTS, low-medium | fork's `ConsoleLogJS` concatenation is identical on iOS, macOS and Linux; consumed raw at `lib/services/webview.dart:4405-4406` | ETP-025 (the fingerprinting half) |
| 2873 | Restrict FileProvider paths | AFFECTS, low-medium | our `android/app/src/main/res/xml/flutter_inappwebview_android_provider_paths.xml` carries five roots against upstream's one | tasks 6.x |
| 2791 | `shouldOverrideUrlLoading` always returns true | AFFECTS, medium | `lib/services/webview.dart:3531` sets `useShouldOverrideUrlLoading` unconditionally; fork `InAppWebViewClient.java:105` returns `request.isForMainFrame()` even on ALLOW, reissuing at `:145` | NESTED-012, documentation only |
| 2780 | `webkit_web_view_get_theme_color` on WebKit < 2.50 | AFFECTS, build | one unguarded call at fork `flutter_inappwebview_linux/linux/in_app_webview/in_app_webview.cc:6268`; no `WEBKIT_CHECK_VERSION` anywhere in the Linux plugin | CONT-009 |
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
