## Why

We pin `flutter_inappwebview` to a fork ref, so upstream's issue tracker
describes code we compile. Nobody had read it end to end. A sweep of the 144
open issues at ref `v6.2.0-beta.3-privacy-v6`
([docs/upstream/flutter-inappwebview-audit.md](../../../docs/upstream/flutter-inappwebview-audit.md))
turned up four defects that defeat a privacy control we already claim to
enforce, plus one factual error in our own compatibility matrix.

The one that matters most is #2763. On iOS and macOS the plugin treats a `false`
return from `onCreateWindow` as "the host declined, so I will load it myself":
`defaultBehaviour` calls `loadUrl(navigationAction.request)` on the *parent*
webview (`InAppWebView.swift:2762-2766`). Android's equivalent only drops the
pending window message. Our handler returns `false` on every path except the
captcha popup, so on two of four shipped platforms:

- a cross-domain or gesture-less `window.open()` that NESTED-004 exists to block
  gets loaded anyway,
- an `intent://` we deliberately declined or suppressed under EXT-003/EXT-007
  gets handed to the parent raw, and
- on the allow path we load the rewritten URL and the platform loads the
  original on top, so a ClearURLs-stripped navigation is followed by an
  unstripped one.

None of this is visible from Dart. The handler returns, the block is logged, and
the navigation happens regardless.

The second is quieter. `buildUserAgentMetadata` returns metadata carrying
`platform` and `mobile` while leaving `brandVersionList` null whenever the UA
matches neither `Firefox/` nor `Chrome/`, and the fork's converter then skips
`setBrandVersionList` entirely. A Firefox-for-iOS preset (a `FxiOS/` UA, so
neither token matches) therefore ships `Sec-CH-UA-Platform: "iOS"` and
`Sec-CH-UA-Mobile: ?1` alongside the device's *real* `Sec-CH-UA`, naming
Chromium's true version and the literal string "Android WebView", while the
shimmed `navigator.userAgentData` says WebKit. That is worse than not spoofing:
it discloses the real engine version and manufactures exactly the header-vs-JS
contradiction [BUG-009](../../../docs/bugs/009-shim-realm-escape.md) is about.
Every custom UA a user types hits the same path, as does every device whose
WebView lacks `WebViewFeature.USER_AGENT_METADATA`.

## What Changes

- **The platform may not override a declined window request** (NESTED-011). A
  `false` from `onCreateWindow` means "do not open it", on every platform. Fork
  patch bringing iOS and macOS `defaultBehaviour` to Android parity, plus the
  regression scenarios that say so. EXT-009 states the external-scheme half:
  declining an `intent://` must not leave the parent to load it.
- **UA Client Hints fail closed** (UAID-005). If we cannot build a brand list
  consistent with the UA we are presenting, we do not ship a half-spoof: either
  synthesize a brand list matching the engine the UA claims, or suppress the
  metadata override entirely. Never leave the real brand list standing under a
  spoofed platform.
- **The console shim is masked like every other wrapper** (ETP-025). The
  plugin's `ConsoleLogJS` installs five non-native `console` methods at document
  start. We mask every other injected wrapper as `[native code]`; these were
  missed, so `console.log.toString()` is a free "this is flutter_inappwebview"
  tell that survives Tracking Protection.
- **The Linux build floor is stated where the wrong number lives** (CONT-009).
  The container primitive needs WPE 2.40, but the plugin as a whole does not
  compile below 2.50 because of one unguarded `webkit_web_view_get_theme_color`.
  The Platform Support Matrix currently claims 2.40 and names Debian trixie and
  Ubuntu, neither of which can build us.
- **Documented, not changed:** NESTED-012 records the provenance loss that
  `useShouldOverrideUrlLoading` already causes on Android (cancel-and-reissue
  drops `Referer` and `window.opener` and downgrades `Sec-Fetch-Site` to
  `none`). We accept this on iOS under IOS-UL-001; Android inherits it silently.
  Writing it down makes it a stated property instead of an accident.

## What this change does not do

Fix the iOS `windowId` KVO crash (#2867/#2600), chase the iOS 26 touch reports
(#2727/#2713), or rebase the fork for Flutter 3.47 (#2883). Those are on the
audit's watch list with the evidence gathered so far. The two threading findings
that turned out to be ours rather than upstream's are recorded as
[BUG-007](../../../docs/bugs/007-native-shared-state-races.md) gap 5.
