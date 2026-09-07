# Fork work brief: what to change in `theoden8/flutter_inappwebview`

Everything here happens in the **fork**, not in this repo. It is written to be
pasted into a session opened on the fork with no other context, so it repeats
what that session needs to know. The evidence behind each item is in
[flutter-inappwebview-audit.md](flutter-inappwebview-audit.md); the WebSpace-side
follow-ups are in
[openspec/changes/upstream-webview-defects/tasks.md](../../openspec/changes/upstream-webview-defects/tasks.md).

Keep the two halves in step. Landing a fork patch means re-tagging the fork and
bumping all six `dependency_overrides` refs in this repo's `pubspec.yaml`
together; they must always name one ref.

---

## Ground rules for that session

**Baseline.** `merge-base(v6.2.0-beta.3-privacy-v6, upstream/master)` is
`17527cae`, which is upstream master HEAD. The fork is upstream master plus 19
commits, all additive: containers, `proxySettings`, three Android settings, and
two cookie flush/memo fixes. There is no upstream backlog to catch up on, so
every open upstream PR is genuinely unmerged and no maintainer has reviewed any
of them. Nothing here can be obtained by waiting.

**Attribution.** Taking someone else's commit keeps their `--author` verbatim.
Write your own message for what the change does here, and cite the origin with
one `Cherry-picked-from: <sha> (pichillilorenzo/flutter_inappwebview)`. Never
`--reset-author`, never `git commit -s`, never `--signoff`, never re-pick
without `-x`. One `Co-Authored-By:` per identity at most, no `Signed-off-by:`
at all. Non-ASCII author names stay verbatim. Where a PR spans two author
emails plus a merge commit, pick the individual commits, each keeping its own
author.

**Marking.** Anything we originate, or any upstream patch we modify, carries a
`[WebSpace fork patch]` comment at the change site. That marker is how this
repo finds the fork's surface area later.

---

## A. Original patches (nobody upstream is fixing these)

### A1. A declined `onCreateWindow` must not navigate the parent

The highest-severity item in the whole audit, and the reason this brief exists.

On iOS (`flutter_inappwebview_ios/.../InAppWebView/InAppWebView.swift:2762-2766`)
and macOS (the twin around `:1947-1951`), `callback.defaultBehaviour` removes the
pending transport and then calls
`self?.loadUrl(urlRequest: navigationAction.request, allowingReadAccessTo: nil)`
on the **parent** webview. Android's equivalent
(`InAppWebViewChromeClient.java:675-679`) only drops the pending message. Since
`nonNullSuccess = { !handledByClient }`, returning `false` from Dart is exactly
what triggers it.

WebSpace returns `false` on every `onCreateWindow` path except the captcha
popup, so on iOS and macOS a blocked cross-domain `window.open()` loads anyway,
a declined `intent://` is handed to the parent raw, and an allowed one is loaded
twice, the second time unrewritten.

Bring iOS and macOS to Android parity: `defaultBehaviour` drops the transport
and does nothing else. Then offer it upstream on issue #2763 as a
cross-platform contract violation, not a WebSpace need.

### A2. Android soft keyboard dies app-wide after HTML5 fullscreen

`InAppWebViewChromeClient.onHideCustomView` (`:151-179`) restores system UI and
orientation but never touches the IME; the file has zero `InputMethodManager`
references. After exiting a fullscreen video the keyboard is dead for the whole
app, including the host app's own text fields. Upstream issue #2878, whose
predecessor #1176 is unresolved, so this will not arrive on its own.

### A3. Android native WebView background color

`InAppWebView.java:397-398` sets `Color.TRANSPARENT` only when
`transparentBackground` is set, so the native view otherwise keeps its default
white beneath the compositor. Add a `backgroundColor` **setting** applied in
`prepare()` beside `transparentBackground`.

Do **not** take upstream PR #2864 for this: it adds a runtime controller method,
and a runtime call cannot fire before the platform view's first paint, which is
the flash being complained about.

### A4. Address-keyed statics in `WKUserContentController`

`Types/WKUserContentController.swift:18-53` (and the macOS twin) keep
`contentWorlds`, `userOnlyScripts` and `pluginScripts` in process-global static
dictionaries keyed by `String(format: "%p", unsafeBitCast(self, to: Int.self))`,
with no synchronization. `getContentWorlds` already carries a comment about
`EXC_BREAKPOINT` when the collection mutates mid-loop, mitigated with a copy
rather than a lock.

Two failure modes. The crash, and the quieter one: a controller freed without
`dispose()` leaves its entry behind, and the next controller allocated at that
address inherits it, so `containsPluginScript` reports scripts that were never
added and `sync()` skips them. For WebSpace that is a site whose per-site
privacy shims silently never inject.

Replace the address keying with object-identity storage
(`objc_setAssociatedObject`, or an `NSMapTable` with weak keys) behind one
serial queue or lock, on both iOS and macOS. Take A5 first, then do this.

---

## B. Cherry-picks, in the order they pay off

### B1. PR #2781, Linux WebKit version guard

`#if WEBKIT_CHECK_VERSION(2,50,0)` around `webkit_web_view_get_theme_color`
(`flutter_inappwebview_linux/linux/in_app_webview/in_app_webview.cc:6268`), the
only unguarded 2.50 symbol in the plugin. Guards the 2.50-only `WebKitColor`
type as well as the call, so it is complete. Applies clean.

This is the single thing pinning WebSpace's Linux CI to `debian:sid-slim`.
Nothing calls `getMetaThemeColor` from Dart there, so returning nothing below
2.50 costs that app nothing, and it makes Debian trixie and ParrotOS buildable.

### B2. PR #2767, macOS `upgradeKnownHostsToHTTPS` selector guard

`responds(to: "setUpgradeKnownHostsToHTTPS:")` instead of
`#available(macOS 11.3, *)`, which is what actually fails: Apple's header
back-annotates a selector Big Sur lacks. The setting defaults to `true` and the
assignment is on the path every macOS webview creation takes, so an affected
user crashes on first load. Stale and written against the pre-SPM layout, but
git rename-detects onto the current path; confirm the hunk lands in
`flutter_inappwebview_macos/macos/.../InAppWebView.swift` and that no stale
`macos/Classes/` file is created.

### B3. PR #2851, console argument serialization

Fixes objects arriving as `[object Object]` and `Error` losing message and
stack. **Port it to all three copies in the same commit**: the PR is iOS-only,
and `flutter_inappwebview_macos/.../ConsoleLogJS.swift` plus
`flutter_inappwebview_linux/linux/plugin_scripts_js/console_log_js.h` carry the
byte-identical bug. Its 2000-char cap is worth raising for HTML export, but
that is a deliberate deviation: say so in the message.

### B4. PR #2243, Android picker sandbox filter (CVE-2020-6563)

Rejects picker results canonicalizing under the app data dir. Two known gaps to
note in the commit message rather than fix here: `content://` is out of scope,
and the blanket `/data/` prefix could false-positive on ROMs where `/sdcard`
canonicalizes into `/data/media/0`.

### B5. PR #2881, Linux, two of five commits

Take `fc1bd5756` (the `skip_pixel_readback_` gate: `OnWpePlatformBufferRendered`
currently sets `buffer_handled = true` on any DMA-BUF import even in software
mode, so the pixel buffer is never filled and the texture stays blank, which is
issue #2861) and `0c9963cc1` (raster-thread use-after-free on recycled textures
reaching destroyed webviews). `in_app_webview.h` needs a trivial merge against
the fork's member block. Leave the other three for now.

### B6. PR #2870, macOS availability helper

Constrains `ASWebAuthenticationPresentationContextProviding` to
`@available(macOS 10.15)`. WebSpace never uses `WebAuthenticationSession`, but
it compiles into the macOS plugin and CI builds macOS, so this is a build break
waiting for the next Xcode.

### B7. PR #2776, `windowId` evaluateJavaScript crash

Routes around the faulting `evaluateJavaScript(_:frame:contentWorld:)` overload
on `windowId` webviews. Three changes needed: mirror it into the macOS twin,
which the PR does not touch; drop its `callAsyncJavaScript` half, which silently
collapses custom-world isolation; and normalise the `result as Any` box, which
turns a nil result into `Optional<Any>.none` rather than a plain nil.

It fixes the crash and not the cause. A4 is the cause.

### B8. PR #2866, `ALLOW_WITHOUT_TRYING_APP_LINK`

Adds `NavigationActionPolicy.ALLOW_WITHOUT_TRYING_APP_LINK` (= 3), decoded on
iOS and macOS as `WKNavigationActionPolicy(rawValue: .allow.rawValue + 2)`.

Take it **with the fork's decode fixed**: our `WebViewChannelDelegate.swift`
currently maps unknown policy ints to `.cancel`, so the Dart enum alone changes
nothing. Regenerate the hand-edited `.g.dart`.

Then flag the risk clearly for the app side: if Swift's `init?(rawValue:)`
rejects 3 on an imported NS_ENUM, the PR's `?? .allow` fallback degrades to a
plain allow and universal links resume firing **with nothing in the logs**. It
needs a device check before anything is deleted on the app side.

---

## C. Never take these, including silently in a rebase

Write these into the fork's own notes, because the danger is a future rebase
swallowing them without a build break.

- **PR #2671**, WKWebView proxy for iOS 17+. Assigns
  `WKWebsiteDataStore.nonPersistent()` unconditionally at the end of the same
  `preWKWebViewConfiguration` block the container binding and per-site proxy
  live in (`flutter_inappwebview_ios/.../InAppWebView.swift:745-772`). Landing
  after ours, it drops both: every iOS site on one ephemeral jar with the global
  proxy. Treat `preWKWebViewConfiguration` as a permanent hand-resolved conflict
  site; if #2671 ever merges, keep our block and drop theirs.
- **PR #2832**, WebKitGTK backend. Targets `webkit2gtk-4.1`, a generation with
  no `WebKitNetworkSession`, which the entire Linux container layer is built on,
  and its CMake `return()` stops the WPE sources compiling at all. It would buy
  Ubuntu support by deleting the feature the app exists for.
- **PR #2771**, "iPad crash when frame is nil". `frame: nil` is how the plugin's
  own callers say "main frame"; the patch disables all content-world JS on iOS.
- **PR #1952** (shadows a loop binding, returns empty credentials) and
  **PR #2694** (comments out the iOS Apple Pay guard). Regressions presented as
  fixes.
- **PR #2729** as-is: adds `Build.VERSION.SDK_INT` to `TrustedWebActivity.java`
  without `import android.os.Build`, which is absent. It does not compile. Take
  it only with the import added.
- **PR #2844** as-is: defers Android plugin-script registration but not
  user-only scripts, inverting DOCUMENT_START order so app shims would run
  before the bridge, and both its catch blocks log and continue, which is
  fail-open injection. If adopted, defer both and make the catch fail closed.

---

## D. Verification, honestly

Most of this is not reachable from any automated tier.

- **B1** is proved by the build: run `fvm flutter build linux --release` in
  `debian:trixie-slim` (WPE 2.48) with the CI apt set. Before the patch it fails
  at `in_app_webview.cc:6268`; after, it builds. Then flip WebSpace's Linux CI
  container and confirm the whole job stays green including the Xvfb loop. That
  full run is the only proof no other 2.50 symbol lurks, because the comment
  claiming a second one names `webkit_navigation_action_is_for_main_frame`,
  which does not appear anywhere in the fork.
- **B5** needs the Linux integration tier run a second time with
  `FLUTTER_INAPPWEBVIEW_LINUX_DISABLE_GL=1`, asserting a non-blank surface.
- **A1** is gateable from the app side: a structural test asserting no
  platform's decline path calls `loadUrl`. Add it there, not here.
- **B2, B7, B8, A2** are device-only. B2 needs a Big Sur VM; if that is not
  worth keeping, the honest alternative is raising the macOS deployment target
  to 12.0 and skipping B2 entirely.
- **A4**'s quiet half is observable: open and close a `windowId` popup
  repeatedly and assert the popup still reports the parent's per-site shim
  values. That belongs in the app's macOS integration tier.

---

## E. Blocked on WebKit, not on us

`OnDecidePolicy` (`flutter_inappwebview_linux/linux/in_app_webview/in_app_webview.cc:3966-3972`)
infers main-frame status from `webkit_navigation_action_get_frame_name()` being
empty, which is also true of every unnamed iframe, and defaults to `true`.
`create_window_action.cc:41` simply hardcodes `isForMainFrame(true)`.

The real API is coming from us:
[WebKit PR 65415](https://github.com/WebKit/WebKit/pull/65415) adds
`webkit_navigation_action_is_for_main_frame()` for WPE and GTK. It is open and
merging-blocked on test failures, and the symbol exists in **no** WebKit release:
verified absent from `WebKitNavigationAction.h.in` on `main` and on the
`webkitglib/2.50`, `2.52` and `2.54` branches. There is nothing to gate on yet.

When it lands and a WPE release carries it, replace both sites with the real
call behind a `WEBKIT_CHECK_VERSION` guard, the same shape as B1, so the fork
still builds against older WPE. Until then the app compensates (NESTED-013), so
this is not urgent for the fork; do not paper over it with a second heuristic.
