
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/services/block_decision.dart';
import 'package:webspace/services/html_snapshot.dart';
import 'package:webspace/services/pull_to_refresh_gate.dart';
import 'package:webspace/services/resume_reload_engine.dart';
import 'package:webspace/services/media_grant_engine.dart';
import 'package:webspace/services/passkey_engine.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/dns_level_mask_engine.dart';
import 'package:webspace/services/webview_host_hooks.dart';
import 'package:webspace/services/opensearch_engine.dart';
import 'package:webspace/services/site_icon_engine.dart';
import 'package:webspace/services/site_posture.dart';
import 'package:webspace/services/cookie_manager.dart';

class FindMatchesResult {
  int activeMatchOrdinal = 0;
  int numberOfMatches = 0;
}

enum WebViewTheme { light, dark, system }

class WebViewConfig {
  /// Unique key to force widget recreation when settings change.
  final Key? key;
  /// What every webview that runs as the site applies, resolved once by
  /// `WebViewModel.sitePosture`. A popup this webview spawns inherits it.
  final SitePosture posture;
  final String initialUrl;
  /// iOS/macOS only: enable WKWebView's native back/forward swipe gesture
  /// (`allowsBackForwardNavigationGestures`). Set only for the root site
  /// webview, which lives at the `MaterialApp` root route where no Flutter
  /// route-pop edge-swipe exists — so without this Apple has no reliable
  /// back-swipe in the main view (the `PopScope` handler only fires for
  /// pushable routes). Nested `InAppWebViewScreen`s leave this false: they
  /// are pushed routes whose own PopScope navigates webview-back and pops
  /// the route at history start (NAV-008), which the native gesture would
  /// otherwise hijack. No effect on Android.
  final bool backForwardGestures;
  /// Android only: build the webview with no initial load (neither
  /// `initialUrlRequest` nor cached-HTML `initialData`) so the
  /// controller-created handler can apply `restoreState` to a pristine
  /// back/forward list. Android's `WebView.restoreState` is dropped when the
  /// WebView has already navigated — its docs warn that calling it after the
  /// view "had a chance to build state (load pages, create a back/forward
  /// list, etc.) there may be undesirable side-effects". The handler reloads
  /// the restored top entry afterward, since Android does not restore display
  /// data. iOS/macOS replace state in place via `WKWebView.interactionState`,
  /// so they keep the initial load and leave this false.
  final bool deferInitialLoad;
  /// BGAUDIO-006: inject the media-session bridge shim + register the
  /// `wsMediaSession` handler so this site's playback drives the Android
  /// foreground media notification. Android-only effect. Set only by the
  /// site's own webview, from the slot's setting rather than the posture:
  /// the background-audio lifecycle belongs to the slot, whatever site a
  /// hosted tab runs as.
  final bool backgroundAudioEnabled;
  final Function(String url)? onUrlChanged;
  final Function(List<Cookie> cookies)? onCookiesChanged;
  final Function(int activeMatch, {required int totalMatches})? onFindResult;
  final Function(String url, {required bool hasGesture})?
      shouldOverrideUrlLoading;
  /// Fires when a main-frame navigation was cancelled because the app could
  /// not establish that it would go through this site's proxy (LEAK-010).
  /// Carries the destination that was not requested, so the host can render
  /// the interstitial that says so.
  final void Function(String url)? onUnproxiedNavigationBlocked;
  /// Fires when the page enters or exits a loading state. Driven by
  /// `onLoadStart` (true) and `onLoadStop` (false). The call site can
  /// use this to swap a Refresh button with a Stop button while a
  /// navigation is in flight.
  final Function({required bool loading})? onLoadingChanged;
  /// Fires when this webview reloads itself (the cached-HTML one-shot live
  /// refresh below). A reload discards the painted frame and recommits it
  /// later, so on Android the hybrid-composition surface sits blank in
  /// between with nothing to relayout it (BUG-001 / PAUSE-021). Host-driven
  /// reloads funnel through `WebViewModel.reloadAndRepaint`; this is the
  /// same signal for the ones the factory issues on its own.
  final VoidCallback? onReloadIssued;
  /// Fires on every main-frame load lifecycle transition (start / settle /
  /// failure). Feeds `ResumeReloadEngine`, which decides whether a load the
  /// OS stranded while the app was backgrounded has to be re-issued on the
  /// next resume (PAUSE-022). Distinct from [onLoadingChanged], which is
  /// UI state and carries neither the URL nor the failure.
  final void Function(MainFrameLoadSignal signal)? onMainFrameLoad;
  /// Fires as the main-frame load advances, with progress in 0-100.
  /// Driven by the platform's `onProgressChanged`. The call site can
  /// use this to render a determinate loading bar while a navigation
  /// is in flight ([onLoadingChanged] gates visibility).
  final Function(int progress)? onProgressChanged;
  /// Callback when page HTML should be cached. Called on page load with (url, html).
  final Function(String url, {required String html})? onHtmlLoaded;
  /// Optional pre-gate for the [onHtmlLoaded] path. Returning `false`
  /// makes `onLoadStop` skip the [htmlSnapshotScript] IPC entirely
  /// (not just the encrypt+write that follows). The IPC is the
  /// expensive, lifecycle-racing piece — the renderer has to walk and
  /// serialize the live DOM, and during a frame teardown that walk
  /// can hold a `raw_ptr` to a soon-to-be-freed Frame. Skipping the
  /// IPC outright is the only way to drop the renderer pressure.
  /// When unset, every `onLoadStop` fetches HTML (legacy behavior).
  final bool Function()? shouldFetchHtml;
  /// Optional cached HTML to display when offline. Sub-resources (CSS/JS/images)
  /// load from the browser's HTTP cache via LOAD_CACHE_ELSE_NETWORK mode.
  final String? initialHtml;
  /// Severity level every DNS check for this site runs at: 0 when the toggle
  /// is off, otherwise the resolved per-site level, which falls back to the
  /// app-wide one until its list is downloaded. One number so the toggle and
  /// the level can't disagree at a call site.
  int get effectiveDnsLevel => posture.blocking.dns
      ? DnsBlockService.instance.effectiveLevelFor(posture.blocking.dnsLevel)
      : kDnsLevelOff;
  BlockPolicy get blockPolicy => (
        dnsLevel: effectiveDnsLevel,
        contentBlock: posture.blocking.contentBlock,
      );
  final Function(String message, {required inapp.ConsoleMessageLevel level})?
      onConsoleMessage;
  /// The host's answers for every webview that runs as the site: prompts,
  /// popups, external schemes and the cookie readers.
  final WebViewHostHooks hooks;
  /// A long-press that landed on a link (`SRC_ANCHOR_TYPE`). The host opens
  /// its link menu, whose "Open in new tab" is how a child tab is created
  /// (TAB-006). Android and iOS only: the plugin backs this with
  /// `View.setOnLongClickListener` / `UILongPressGestureRecognizer`, and there
  /// is no macOS or Linux equivalent, so those platforms reach the same
  /// actions from the tab list instead.
  final void Function(String url)? onLinkLongPress;
  /// Pull-to-refresh, with the gate that keeps a pinch from firing it
  /// (NAV-006); the factory feeds it from a [Listener] around the webview.
  final PullToRefreshGate? pullToRefreshGate;
  /// Fires when the underlying renderer terminates unexpectedly. On Android
  /// this maps to `WebView.onRenderProcessGone` — the OS sometimes kills the
  /// renderer to reclaim memory after the app has been backgrounded for a
  /// while, leaving the WebView's surface in an unusable "black screen"
  /// state until it's destroyed and recreated. The host is expected to drop
  /// the controller and rebuild the widget. If unset, the WebView is left
  /// in its post-crash state (visible to the user as a black rectangle).
  final void Function({required bool didCrash})? onRendererGone;
  /// Android: the WebView has committed a frame that is visible for the first
  /// time on this navigation. The only signal in the app that fires *because
  /// pixels exist* — every other repaint trigger is a lifecycle event hoped to
  /// imply one, and BUG-001 gap #18 caught a load whose nudges had all drained
  /// twelve seconds before the renderer produced anything.
  final VoidCallback? onPageCommitVisible;
  /// Camera, microphone, screen-sharing and protected-content decisions for
  /// this webview's pages. Null installs none of the capture shims or their
  /// handlers, and leaves permission requests to the platform's default.
  final GrantStore? grants;
  /// Where the page's own icon goes (ICON-009). Set only for the site's root
  /// webview: a nested screen or popup shows another page, often on another
  /// host, and must not repaint the site's icon. Android is the only platform
  /// that reports icons; elsewhere the watcher runs and nothing arrives.
  final SiteIconTarget? siteIcon;
  /// Where the search the site's pages declare goes (LIR-035). Set only for
  /// the site's root webview, and only for a site that has to learn its
  /// search that way.
  final SiteSearchTarget? siteSearch;
  /// Passkeys for this webview's pages (PASSKEY-001). Null leaves WebAuthn
  /// off, which is the WebView's default: no shim, no handler, and the
  /// engine's own `navigator.credentials` refuses a `publicKey` request.
  final PasskeyAccess? passkeys;

  WebViewConfig({
    this.key,
    required this.posture,
    required this.hooks,
    required this.initialUrl,
    this.backForwardGestures = false,
    this.deferInitialLoad = false,
    this.backgroundAudioEnabled = false,
    this.onUrlChanged,
    this.onLoadingChanged,
    this.onReloadIssued,
    this.onMainFrameLoad,
    this.onProgressChanged,
    this.onCookiesChanged,
    this.onFindResult,
    this.shouldOverrideUrlLoading,
    this.onUnproxiedNavigationBlocked,
    this.onHtmlLoaded,
    this.shouldFetchHtml,
    this.initialHtml,
    this.onConsoleMessage,
    this.onLinkLongPress,
    this.pullToRefreshGate,
    this.onRendererGone,
    this.onPageCommitVisible,
    this.grants,
    this.siteIcon,
    this.siteSearch,
    this.passkeys,
  });
}

/// Android and Linux apply the proxy as a process-global override from Dart
/// after the platform view exists (`WebViewModel.setController`). A site whose
/// effective proxy is non-DEFAULT must therefore carry no initial load, or its
/// first request leaves before the override lands; the same holds for a
/// DEFAULT site while the override still names another site's proxy.
/// `setController` issues the first load once the override is in (LEAK-003).
///
/// Every platform that binds a proxy per container defers too when the
/// container still carries a proxy its site no longer names: the clear goes
/// out from `setController` as well (PROXY-029).
bool deferInitialLoadForProxy({
  required bool proxyIsGlobal,
  required bool effectiveNonDefault,
  required bool overrideActive,
  required bool releasesContainerProxy,
}) =>
    releasesContainerProxy ||
    (proxyIsGlobal && (effectiveNonDefault || overrideActive));

/// Whether the root site webview must defer its initial load so the
/// controller-created handler can apply `restoreState` to a pristine
/// back/forward list. True only on Android: `WebView.restoreState` no-ops
/// when the WebView has already navigated (an `initialUrlRequest` would build
/// a 1-entry history first), so the back/forward stack restore is silently
/// dropped. iOS/macOS `WKWebView.interactionState` replaces the stack in
/// place even after a load started, so they keep the initial load.
///
/// Excludes file:// imports: their URL is a synthetic handle with no
/// fetchable form, so the post-restore reload would surface
/// ERR_FILE_NOT_FOUND — and back/forward history is meaningless for a static
/// local page anyway, so they keep rendering their cached `initialData`.
/// Only meaningful when nav-state bytes are actually pending for this build.
bool deferInitialLoadForRestore({
  required bool hasPendingRestoreState,
  required bool isAndroid,
  required bool isFileImport,
}) =>
    hasPendingRestoreState && isAndroid && !isFileImport;
