import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'package:webspace/platform/host_platform.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/services/block_decision.dart';
import 'package:webspace/services/clearurl_service.dart';
import 'package:webspace/services/html_snapshot.dart';
import 'package:webspace/services/https_upgrade_engine.dart';
import 'package:webspace/services/letterbox.dart';
import 'package:webspace/services/page_shim.dart';
import 'package:webspace/services/proxy_binding_engine.dart';
import 'package:webspace/services/proxy_coverage_engine.dart';
import 'package:webspace/services/resume_reload_engine.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/camera_permission_service.dart';
import 'package:webspace/services/capture_permission_engine.dart';
import 'package:webspace/services/passkey_engine.dart';
import 'package:webspace/services/passkey_native.dart';
import 'package:webspace/services/user_agent_metadata_builder.dart';
import 'package:webspace/services/block_stats_engine.dart';
import 'package:webspace/services/block_stats_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/icon_service.dart'
    show fetchPageIconBytes, fetchPageLinkedBytes;
import 'package:webspace/services/download_url_revert_engine.dart';
import 'package:webspace/services/external_url_engine.dart';
import 'package:webspace/services/ios_universal_link_bypass.dart';
import 'package:webspace/services/web_intercept_native.dart';
import 'package:webspace/services/icon_link_watcher_shim.dart';
import 'package:webspace/services/opensearch_engine.dart';
import 'package:webspace/services/search_link_watcher_shim.dart';
import 'package:webspace/services/site_icon_engine.dart';
import 'package:webspace/services/site_posture.dart';
import 'package:webspace/services/site_icon_fetcher.dart';
import 'package:webspace/services/site_icon_native.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/settings/site_permission_state.dart';
import 'package:webspace/widgets/surface_nudge_scope.dart';
import 'package:webspace/services/webview_config.dart';
import 'package:webspace/services/webview_proxy.dart';
import 'package:webspace/services/http_auth_challenge.dart';
import 'package:webspace/services/webview_blocking.dart';
import 'package:webspace/services/webview_controller.dart';
import 'package:webspace/services/file_import_document.dart';
import 'package:webspace/services/webview_tls.dart';
import 'package:webspace/services/webview_downloads.dart';
import 'package:webspace/services/page_scripts.dart';
import 'package:webspace/services/page_handlers.dart';
import 'package:webspace/services/popup_webview.dart';
import 'package:webspace/services/page_js.dart';

/// The container and proxy a WebView is built with ([WebViewFactory.storeBinding]).
///
/// [releasesContainerProxy]: the container still carries a proxy this
/// process gave it and the site no longer names one, so it has to be
/// cleared ([ProxyManager.releaseContainerProxy]) before the first load.
typedef StoreBinding = ({
  String? containerId,
  inapp.ProxySettings? proxy,
  bool proxyUnavailable,
  bool proxyConfigured,
  bool releasesContainerProxy,
});

class WebViewFactory {
  /// How Android draws a webview (PAUSE-032). True, the default, is hybrid
  /// composition: the WebView sits in the Android view hierarchy and Flutter
  /// draws into image views around it, where a surface can reattach without a
  /// paint and stay blank white (BUG-001). False is texture layer hybrid
  /// composition, where the page renders into a texture Flutter composites in
  /// its own frame; it is an experimental feature (DEVTOOLS-011).
  ///
  /// Set once at startup and never after, so every webview in a process runs
  /// the same mode. The fork's `setSettings` replaces the native settings
  /// wholesale and the Dart settings class defaults this field to true, so
  /// every `InAppWebViewSettings` the app builds must carry it or a settings
  /// update flips a texture webview's native input and selection code to
  /// hybrid behaviour.
  static bool hybridComposition = true;

  /// One per process, shared by root and nested webviews: a host that answered
  /// an upgrade with a failure in one must not be probed again by the other
  /// (HTTPS-002).
  static final HttpsUpgradeEngine httpsUpgrade = HttpsUpgradeEngine();

  /// System font scale → webview text zoom percent. Tracks the OS-level
  /// "font size" accessibility setting so web content matches the size
  /// users see in their system browser.
  static int systemTextZoomPercent() {
    final scale = WidgetsBinding.instance.platformDispatcher.textScaleFactor;
    return (scale * 100).round();
  }

  /// The view's CSS-pixel width in each orientation, `(portrait,
  /// landscape)`. The page-zoom shim pins the layout viewport against
  /// these because everything reachable from the page is either spoofed
  /// (`screen.*`, by the anti-fingerprinting shim) or already moved by the
  /// zoom itself (`innerWidth`). Zero when no view is attached.
  static (double, double) viewExtents() {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView ??
        (WidgetsBinding.instance.platformDispatcher.views.isEmpty
            ? null
            : WidgetsBinding.instance.platformDispatcher.views.first);
    if (view == null || view.devicePixelRatio <= 0) return (0, 0);
    final w = view.physicalSize.width / view.devicePixelRatio;
    final h = view.physicalSize.height / view.devicePixelRatio;
    if (w <= 0 || h <= 0) return (0, 0);
    return (math.min(w, h), math.max(w, h));
  }

  static bool _hasUserGesture(inapp.NavigationAction action) {
    if (hostIsAndroid) {
      return action.hasGesture ?? true;
    }
    if (hostIsIOS || hostIsMacOS) {
      return action.navigationType == inapp.NavigationType.LINK_ACTIVATED ||
             action.navigationType == inapp.NavigationType.FORM_SUBMITTED;
    }
    return true;
  }

  static bool _shouldBlockUrl(String url) {
    // Allow about:blank and about:srcdoc - required for Cloudflare Turnstile
    if (url.startsWith('about:') && url != 'about:blank' && url != 'about:srcdoc') return true;
    if (url.contains('/sw_iframe.html') || url.contains('/blank.html') || url.contains('/service_worker/')) return true;
    return false;
  }

  static const _captchaDomains = [
    'challenges.cloudflare.com',
    'hcaptcha.com',
  ];

  /// Domains that legitimately serve reCAPTCHA at /recaptcha/ paths.
  static const _recaptchaDomains = [
    'google.com',
    'gstatic.com',
    'recaptcha.net',
    'googleapis.com',
  ];

  static bool _matchesDomain(String host, {required String domain}) =>
      host == domain || host.endsWith('.$domain');

  /// Whether [host] is the site at [siteUrl] or one of its subdomains, or
  /// the site is a subdomain of it.
  static bool _sameSite(String host, {required String? siteUrl}) {
    final siteHost = siteUrl == null ? '' : (Uri.tryParse(siteUrl)?.host ?? '');
    if (siteHost.isEmpty) return false;
    return _matchesDomain(host, domain: siteHost) ||
        _matchesDomain(siteHost, domain: host);
  }

  /// A captcha URL loads in place and may open the verification popup, so
  /// the Cloudflare path markers, which any origin can put in a path, count
  /// only on the site's own domain ([siteUrl]); Cloudflare serves the
  /// interstitial from the protected origin itself (CAPTCHA-010).
  @visibleForTesting
  static bool isCaptchaChallenge(String url, {String? siteUrl}) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host;
    if (host.isEmpty) return false;
    // Exact captcha domains (hcaptcha, Cloudflare challenges, which is also
    // where the Turnstile widget iframe is served from).
    if (_captchaDomains.any((d) => _matchesDomain(host, domain: d))) {
      return true;
    }
    // Match the PATH only: a substring test on the whole URL let any origin
    // claim a challenge with an attacker-chosen query or fragment
    // (`https://evil.example/x?cf-turnstile`).
    if ((uri.path.contains('/cdn-cgi/challenge-platform') ||
            uri.path.contains('cf-turnstile')) &&
        _sameSite(host, siteUrl: siteUrl)) {
      return true;
    }
    if (uri.path.contains('/recaptcha/') &&
        _recaptchaDomains.any((d) => _matchesDomain(host, domain: d))) {
      return true;
    }
    return false;
  }

  /// The per-site store + proxy binding a WebView must carry, derived from
  /// [config]'s posture alone so a popup binds to the same container and
  /// proxy as the site that opened it.
  static StoreBinding bindingFor(WebViewConfig config) =>
      storeBinding(config.posture);

  /// [bindingFor] from the posture, for a caller that has to act on the
  /// binding before the WebView's config exists.
  static StoreBinding storeBinding(SitePosture posture) {
    final siteId = posture.siteId;
    // Container API binding. Stock flutter_inappwebview's `prepare()`
    // does session-bound ops (addJavascriptInterface,
    // addDocumentStartJavaScript, setAcceptThirdPartyCookies) BEFORE
    // `onWebViewCreated` fires, which locks the WebView to the default
    // store and made our earlier post-hoc-bind approach silently leak
    // across sites. The WebSpace fork's `containerId` field on
    // `InAppWebViewSettings` is read by `prepare()` /
    // `preWKWebViewConfiguration` and binds the WebView to the named
    // container before any session-bound op runs. `cachedSupported` is
    // already platform-aware (Windows / web fall through to the stub
    // which returns false); no extra Platform gate needed.
    // Archive-tier sites (ARCH-007) pass an opaque
    // [archiveContainerId] derived from `HMAC(archiveKey, "container:" +
    // siteId)`, so directory listings under the native container roots
    // expose neither the cleartext archive siteId nor a count delta
    // that correlates 1:1 with archive contents.
    // iOS/macOS/Linux ignore containerId under incognito: the fork
    // short-circuits to an ephemeral store, so binding nothing is right
    // there. Android has no ephemeral profile at all; the fork's
    // setIncognito only wipes the default jar and disables the cache, and
    // the androidx default Profile is persistent on disk. An unbound
    // incognito or archive-tier site there would share `app_webview/Default`
    // with every other such site and leave its storage behind after the
    // archive closes (ARCH-006/ARCH-007). So Android always binds a named
    // profile and relies on the existing teardown: incognito ids are deleted
    // at startup and archive container ids at close.
    final containerId = containerIdFor(
      siteId: siteId,
      archiveContainerId: posture.container.archiveContainerId,
      incognito: posture.container.incognito,
    );

    // Per-site proxy delivery, on the platforms that bind it to the
    // WebView's own network store rather than process-wide:
    //
    //   iOS 17+ / macOS 14+ — the fork's `preWKWebViewConfiguration` writes
    //     it onto `WKWebsiteDataStore.proxyConfigurations`.
    //   Linux (WPE) — the fork pins it to the container's own
    //     `WebKitNetworkSession` via
    //     `webkit_network_session_set_proxy_settings`. Proxies are per
    //     session there, so two containers hold two different proxies at
    //     once.
    //
    // A Linux site with no container has no session to pin, so it stays on
    // the process-wide override path below.
    //
    // On Android the global `inapp.ProxyController` path runs from
    // `WebViewModel._applyProxySettings` instead, so leave `proxySettings`
    // null and avoid sending a no-op object to the native side.
    // The named binding (PROXY-027) answers the process-level half: Apple
    // carries a proxy on the store, everything else on one process rule.
    // Linux adds a per-SITE condition on top that no process-level value
    // can express -- a container owns a `WebKitNetworkSession` and a site
    // without one has no session to pin -- so that half stays a test here.
    final bindsProxyPerSite = ProxyManager.binding == ProxyBinding.perSite ||
        (hostIsLinux && containerId != null);
    // What this site claims, resolved once: a per-site DEFAULT falls through
    // to the app-global outbound proxy, so a site the user has not customized
    // still inherits a global Tor / corporate proxy (PROXY-011).
    final claimedProxy =
        resolveEffectiveProxy(posture.container.proxy, siteId: siteId);
    final effectiveProxy = bindsProxyPerSite ? claimedProxy : null;
    // Router mode wins over the site's own rule: under it every store points
    // at the relay and the per-site choice is made there. Not gated on the
    // site having a proxy, because a store that is not pointed at the relay
    // cannot answer the PROXY-015 probe.
    //
    // Null on Apple unless a parity test opted in: the relay is Android's
    // answer to having one process-wide rule, and an Apple store binds its
    // real upstream itself. See ProxyRouterService.appleRelayEnabled.
    final relayProxy = PlatformInfo.isProxySupported
        ? routerRelayProxyFor(
            siteId: siteId, ownsContainer: containerId != null)
        : null;
    final inappProxy = relayProxy ??
        (effectiveProxy != null && PlatformInfo.isProxySupported
            ? userProxyToInappProxy(effectiveProxy)
            : null);
    // Fail closed: on iOS/macOS/Linux the per-site proxy is bound here via
    // `proxySettings`. If the site expects a non-DEFAULT proxy but the
    // address is malformed (e.g. a hand-edited backup that bypassed UI
    // validation), or the OS is below the `proxyConfigurations` floor,
    // `inappProxy` is null and the webview would otherwise load over the
    // device IP. Blank the initial load instead of leaking.
    final proxyUnavailable = effectiveProxy != null &&
        effectiveProxy.type != ProxyType.DEFAULT &&
        inappProxy == null;
    // The fork keeps a container's proxy until it is cleared by name: a
    // WebView built naming none leaves the previous one in force (PROXY-029).
    final releasesContainerProxy = ProxyManager.containerProxies.mustRelease(
      bindsProxyPerSite: bindsProxyPerSite,
      containerId: containerId,
      siteNamesProxy: effectiveProxy != null,
      boundProxy: inappProxy != null,
      proxyUnavailable: proxyUnavailable,
    );
    return (
      containerId: containerId,
      proxy: inappProxy,
      proxyUnavailable: proxyUnavailable,
      proxyConfigured: claimedProxy.type != ProxyType.DEFAULT,
      releasesContainerProxy: releasesContainerProxy,
    );
  }

  /// One passkey ceremony at a time across every webview (PASSKEY-006).
  static final PasskeyCeremonyGate passkeyGate = PasskeyCeremonyGate();

  /// Numbers each passkey request for the log, which names no origin.
  static int passkeyRequests = 0;

  /// The prefix of every gate key this webview's ceremonies hold.
  static String passkeyWebviewKey(inapp.InAppWebViewController controller) =>
      'wv${identityHashCode(controller)}';

  /// The native settings that follow from the site's posture, shared by the
  /// site's webview and the popups it spawns, so a popup is held to the same
  /// identity and Tracking Protection settings as its opener.
  static inapp.InAppWebViewSettings siteSettings(
    StoreBinding binding, {
    required SitePosture posture,
    required int textZoom,
    required bool desktopMode,
  }) {
    final tp = posture.fingerprint.trackingProtection;
    return inapp.InAppWebViewSettings(
      containerId: binding.containerId,
      proxySettings: binding.proxy,
    )
      ..javaScriptEnabled = posture.page.javascript
      ..userAgent = posture.page.userAgent
      // Sec-CH-UA*/navigator.userAgentData on Android come from a separate
      // metadata object — not the UA string. Without this override the
      // wire-level UA-CH headers contradict the spoofed UA. Silently
      // ignored on iOS/macOS/Linux (no equivalent native API).
      ..userAgentMetadata = buildUserAgentMetadata(posture.page.userAgent)
      // Folded under the Tracking Protection umbrella (Android only; the
      // fork ignores both on iOS/macOS/Linux). When ETP is on: an empty
      // allow-list suppresses the `X-Requested-With: <package>` header for
      // every origin, and Attribution Reporting registration is disabled.
      // When ETP is off, leave the native defaults untouched (null). For the
      // Media Integrity API we keep it enabled-without-app-identity rather than
      // fully disabling it: that preserves legitimate anti-fraud attestation
      // while stripping the app package/signing identity that any origin
      // (including non-DRM trackers) could otherwise read.
      ..requestedWithHeaderOriginAllowList = tp ? const <String>{} : null
      ..attributionRegistrationBehavior =
          tp ? inapp.AttributionBehavior.DISABLED : null
      ..webViewMediaIntegrityApiStatus = tp
          ? inapp.WebViewMediaIntegrityApiStatus.ENABLED_WITHOUT_APP_IDENTITY
          : null
      // No-op on platforms and providers without the feature.
      ..backForwardCacheEnabled = AppPref.backForwardCacheEnabled.value
      ..thirdPartyCookiesEnabled = posture.container.thirdPartyCookies
      ..incognito = posture.container.incognito
      ..textZoom = textZoom
      ..supportZoom = true
      ..useShouldOverrideUrlLoading = true
      // Required for Cloudflare Turnstile and other challenge systems
      ..domStorageEnabled = true
      ..databaseEnabled = true
      ..javaScriptCanOpenWindowsAutomatically = true
      // Enable browser-level resource caching for offline sub-resource loading
      ..cacheEnabled = true
      // Desktop content mode mirrors the per-site UA: a desktop-shaped UA
      // turns on the plugin's `setDesktopMode(true)` path, which flips
      // useWideViewPort + loadWithOverviewMode + zoom on Android and
      // WKWebpagePreferences.preferredContentMode = .desktop on iOS.
      ..preferredContentMode = desktopMode
          ? inapp.UserPreferredContentMode.DESKTOP
          : inapp.UserPreferredContentMode.RECOMMENDED
      ..isInspectable = kDebugMode
      ..useHybridComposition = WebViewFactory.hybridComposition;
  }

  /// The navigation rule of a webview that is the site but not the site's
  /// own tab: a popup ([PopupWebView.createPopupWebView]) or a background check
  /// ([HeadlessSiteChecks.openHeadlessCheck]). Every document passes the site's DNS and
  /// content-blocker checks, and the top document stays on the site's own
  /// domain, or on a captcha host when [allowCaptcha].
  static inapp.NavigationActionPolicy onSiteNavigationPolicy(
    WebViewConfig config, {
    required inapp.NavigationAction navigationAction,
    required bool allowCaptcha,
    bool refusePlainHttp = false,
  }) {
    final url = navigationAction.request.url?.toString() ?? '';
    if (_shouldBlockUrl(url)) return inapp.NavigationActionPolicy.CANCEL;
    if (url.startsWith('about:')) return inapp.NavigationActionPolicy.ALLOW;
    final verdict = judgeAndRecord(
      config,
      query:
          UrlQuery(url, sourceUrl: config.initialUrl, requestType: 'document'),
    );
    if (verdict is! Allowed) return inapp.NavigationActionPolicy.CANCEL;
    if (navigationAction.isForMainFrame == false) {
      return inapp.NavigationActionPolicy.ALLOW;
    }
    if (refusePlainHttp && url.startsWith('http://')) {
      return inapp.NavigationActionPolicy.CANCEL;
    }
    final host = Uri.tryParse(url)?.host ?? '';
    if (url.startsWith('http') &&
        ((allowCaptcha && isCaptchaChallenge(url, siteUrl: config.initialUrl)) ||
            _sameSite(host, siteUrl: config.initialUrl))) {
      return inapp.NavigationActionPolicy.ALLOW;
    }
    return inapp.NavigationActionPolicy.CANCEL;
  }

  /// DNT and Sec-GPC on every navigation the app issues, and the site's
  /// language when it has one.
  static Map<String, String> navigationHeaders(WebViewConfig config) => {
        'DNT': '1',
        'Sec-GPC': '1',
        if (config.posture.page.language case final language?)
          'Accept-Language': '$language, *;q=0.5',
      };

  static Widget createWebView({
    required WebViewConfig config,
    required Function(WebViewController) onControllerCreated,
  }) {
    // DNT/Sec-GPC are always-on per
    // the privacy posture of this app — every outbound nav advertises
    // the user's no-tracking preference.
    final headers = navigationHeaders(config);

    // Declare this site's protection-report scope before any block event can
    // be recorded for it. Keyed by siteId, so a nested webview built for the
    // same site re-asserts the same answer rather than flipping it.
    BlockStatsService.instance.setSiteContributes(config.posture.siteId,
        contributes: config.posture.blocking.contributesStats);
    // Cached-HTML render: when the call site supplies
    // `config.initialHtml`, feed it to chromium via
    // `InAppWebViewInitialData(data, baseUrl: initialUrl)` for instant
    // first paint. Once the cached parse settles (`onLoadStop` for the
    // initialData), fire a one-shot `controller.reload()` to fetch the
    // live URL — which is `baseUrl`, so chromium re-loads the same
    // origin without losing the cached visual state during the
    // network round-trip.
    //
    // file:// imports are the exception — their initialUrl is a
    // synthetic `file://<filename>` handle with no fetchable form, so
    // we render the cache and never reload to live.
    //
    // The reload-to-live swap is what triggers the chromium
    // `partition_alloc_support.cc:770` dangling-raw_ptr SIGTRAP.
    // That FATAL is gated by the
    // `PartitionAllocUnretainedDanglingPtr` chromium feature flag —
    // enabled on AOSP userdebug builds, disabled in production Stable WebView.
    // Production users get the speed-up of cached first paint without
    // the dev-only crash.
    final binding = bindingFor(config);
    final containerId = binding.containerId;
    final inappProxy = binding.proxy;
    final proxyUnavailable = binding.proxyUnavailable;
    ProxyManager.noteStoreProxy(containerId, proxy: inappProxy);
    final fileImport = FileImportDocument.of(
      initialUrl: config.initialUrl,
      initialHtml: config.initialHtml,
    );
    final isFileImport = fileImport != null;
    // Android restore: suppress every initial-load form (URL + cached HTML)
    // so `restoreState` can apply to a pristine history. With this set, the
    // cached-HTML reload-to-live machinery below also stays off — the
    // onControllerCreated restore handler owns the first navigation instead.
    final suppressInitialLoad = config.deferInitialLoad;
    // A cached snapshot rendered against a live baseUrl fetches its
    // subresources; never do that for a site whose proxy is not bound
    // (SEC-009).
    final renderInitialData = (config.initialHtml != null || isFileImport) &&
        !suppressInitialLoad &&
        !proxyUnavailable;
    final usesCachedHtml =
        config.initialHtml != null && !suppressInitialLoad && !proxyUnavailable;
    // One-shot: when the cached HTML's first onLoadStop fires, do
    // exactly one controller.reload() to get a live page. Subsequent
    // onLoadStop events (post-reload, or for SPA navigations) leave
    // it false. Skip entirely for file:// imports and for builds
    // where we KNOW we're offline at construction (no live to fetch).
    var pendingLiveReload = usesCachedHtml && !isFileImport;

    final page = PageScripts.buildPageScripts(config);
    final httpAuth = httpAuthSessionFor(config);
    final textZoom = page.textZoom;
    final userScripts = page.userScripts;
    // Added here rather than in _buildPageScripts so a popup, which shares
    // that builder, never reports into the site's icon.
    final siteIcon = config.siteIcon;
    final iconEngine =
        siteIcon == null ? null : SiteIconEngine(siteIcon.siteUrl);
    final iconSource = pageIconSource;
    if (iconEngine != null) {
      userScripts.add(pageShim('icon_link_watcher',
          js: buildIconLinkWatcherShim(), frames: ShimFrames.top));
      if (iconSource == PageIconSource.webview) {
        unawaited(SiteIconNative.ensureEnabled());
      }
    }
    final siteSearch = config.siteSearch;
    if (siteSearch != null) {
      userScripts.add(pageShim(
          'search_link_watcher', js: buildSearchLinkWatcherShim(),
          frames: ShimFrames.top));
    }
    final iconFetcher =
        iconEngine == null || iconSource != PageIconSource.declaredLinks
            ? null
            : SiteIconFetcher(
                fetch: (url, {required documentUrl}) => fetchPageIconBytes(
                  url,
                  documentHost: Uri.tryParse(documentUrl)?.host ?? '',
                  proxy: config.posture.container.proxy,
                  allowed: (target) => pageIconRequestAllowed(config,
                      target: target, documentUrl: documentUrl),
                ),
              );
    final zoomPlan = page.zoomPlan;
    final desktopMode = page.desktopMode;
    final userScriptService = page.userScriptService;

    // Track last URL that triggered onLoadStart, used to distinguish
    // SPA navigations (pushState) from real page loads in onUpdateVisitedHistory.
    String? lastLoadStartUrl;

    // Track the last URL that actually finished loading as a renderable
    // page. Updated via DownloadUrlRevertEngine.updateStable in
    // onLoadStop; consumed by the onDownloadStartRequest revert so the
    // URL bar and persisted currentUrl roll back to the referring page.
    // Initial-load fallback is handled inside the engine.
    String? lastStableUrl;

    // URL of the main-frame navigation that just failed for a network
    // reason; cleared when the next navigation starts. A failed load still
    // commits the engine's own error page and still fires `onLoadStop`, so
    // without this the HtmlCache save below serialises "connection
    // refused" over the site's last-good snapshot — which is precisely
    // what the offline path renders on the next cold start. Only the
    // ordinary-failure branch of `onReceivedError` sets it; the external
    // scheme paths there leave whatever the page managed to render intact
    // and cacheable. Compared for null rather than against `onLoadStop`'s
    // URL: platforms disagree on whether the settle reports the failing
    // URL or the error-page URL, and skipping one save costs nothing (the
    // next successful load writes the snapshot) while a missed match costs
    // the snapshot itself.
    String? failedNavUrl;

    // Monotonic counter bumped on every `shouldOverrideUrlLoading`
    // entry — i.e. every time chromium asks us about a new navigation,
    // including the synthetic invocations chromium fires for
    // server-side 3xx redirects. `onLoadStart` captures this value at
    // entry; if a later `shouldOverrideUrlLoading` bumps the counter
    // before we finish issuing IPCs against the previous frame, we bail
    // out of the remaining work. The previous frame is being torn down
    // and any further `evaluateJavascript` we post against it is bound
    // with `Unretained` lifetimes that the chromium IO thread later
    // dereferences after the frame is freed — exactly the
    // dangling-raw_ptr SIGTRAP at `partition_alloc_support.cc:770`.
    var navigationGen = 0;

    // One gate per mounted WebView, because the mounting navigation it tracks
    // is a property of the platform view and not of the site (LEAK-010).
    // Rebuilt in `onWebViewCreated` rather than only here: a remount that
    // reuses this Widget (the renderer-gone `KeyedSubtree` bump) builds a
    // fresh WKWebView, which gets a fresh mounting navigation, and a gate
    // still holding the old view's spent slot would refuse it.
    var coverageGate = ProxyCoverageGate(
      binding: ProxyManager.binding,
      proxyConfigured: binding.proxyConfigured,
      mountUrl: config.initialUrl,
    );

    // iOS Universal Link bypass state (per-WebView). Tracks URLs we
    // just cancelled-and-reissued so the second-pass shouldOverrideUrlLoading
    // call (the reissued programmatic load landing here again) doesn't
    // loop. See lib/services/ios_universal_link_bypass.dart.
    final iosUlBypass = IosUniversalLinkBypass();

    LogTag.dnsBlock.debug(
        'Creating webview: siteId=${config.posture.siteId} dnsLevel=${config.effectiveDnsLevel} hasBlocklist=${DnsBlockService.instance.hasBlocklist} isAndroid=${hostIsAndroid} url=${config.initialUrl} containerId=$containerId proxySettings=${inappProxy != null}',
        sensitive: true);

    final settings = siteSettings(
      binding,
      posture: config.posture,
      textZoom: textZoom,
      desktopMode: desktopMode,
    )
      // Keep the Dart shouldInterceptRequest callback disabled on Android:
      // the native FastSubresourceInterceptor handles DNS blocking and
      // LocalCDN replacement for every sub-resource, whereas the Dart
      // callback only fires for main-document navigations on modern
      // Chromium WebView.
      ..useShouldInterceptRequest = false
      ..useShouldInterceptAjaxRequest = false
      ..useShouldInterceptFetchRequest = false
      ..useOnLoadResource = false
      ..supportMultipleWindows = true
      // Android: allow file and content access for Cloudflare Turnstile
      ..allowFileAccess = true
      ..allowContentAccess = true
      // When cached HTML is used, set cache-first mode from the start so
      // sub-resources (CSS/JS/images) resolve from browser cache immediately
      ..cacheMode = usesCachedHtml ? inapp.CacheMode.LOAD_CACHE_ELSE_NETWORK : null
      // iOS: play videos inline instead of auto-fullscreen
      ..allowsInlineMediaPlayback = true
      // Allow media to start without a direct tap. Android WebView defaults
      // this to true, which blocks ALL autoplay — including a getUserMedia
      // MediaStream assigned to a `<video autoplay>` (real OR the virtual
      // camera), so a QR-scan page just shows a grey frame. Every real
      // browser plays a camera stream without a gesture; match that. This is
      // Android-WebView-specific: the setting doesn't exist in the Chromium
      // that the desktop test tier drives, which is why the browser test
      // couldn't catch it.
      ..mediaPlaybackRequiresUserGesture = false
      // iOS/macOS: native Safari-style horizontal swipe for back/forward.
      // Only the root site webview opts in (see WebViewConfig.backForwardGestures).
      ..allowsBackForwardNavigationGestures = config.backForwardGestures
      // Required for onDownloadStartRequest to fire when the webview
      // navigates to a downloadable response (Content-Disposition:
      // attachment, or an unrecognized MIME type). Without this, the
      // webview silently drops the navigation and the user sees nothing.
      ..useOnDownloadStart = true;

    // Android honours the viewport meta's layout width (and thus the page
    // zoom) only when useWideViewPort is on: with it off, Chromium's
    // AdjustForAndroidWebViewQuirks clamps the layout back to device width
    // and resets the scale to 1 below 100%. The shim pairs with this by
    // spelling the width out, which keeps the same quirk's wide-viewport
    // branch (the 980px UA fallback, i.e. every site's desktop layout) out
    // of the path. loadWithOverviewMode must stay off so the WebView
    // respects our `initial-scale` rather than fitting the page to width.
    // Desktop-mode already flips these via preferredContentMode = DESKTOP.
    if (zoomPlan.needsWideViewPort) {
      settings.useWideViewPort = true;
      settings.loadWithOverviewMode = false;
    }

    // Shared between this webview's controller (which issues the pause) and
    // its `onJsAlert` (which has to recognise the pause's own alert).
    final pauseHack = PauseTimersHackState();
    final grants = config.grants;
    PlatformWebViewController? view;

    final webViewWidget = inapp.InAppWebView(
      initialUrlRequest: (renderInitialData || suppressInitialLoad) ? null : inapp.URLRequest(
        url: inapp.WebUri(proxyUnavailable ? 'about:blank' : config.initialUrl),
        headers: proxyUnavailable || headers.isEmpty ? null : headers,
      ),
      initialData: renderInitialData ? inapp.InAppWebViewInitialData(
        data: fileImport?.html ?? config.initialHtml!,
        mimeType: 'text/html',
        encoding: 'utf-8',
        baseUrl: inapp.WebUri(config.initialUrl),
      ) : null,
      pullToRefreshController: config.pullToRefreshGate?.controller,
      initialUserScripts: UnmodifiableListView(userScripts),
      initialSettings: settings,
      // Web permission requests. Two per-site flows route through here:
      //
      // - Protected media (Android only): granting `PROTECTED_MEDIA_ID`
      //   lets the origin run EME license requests (e.g. the Spotify web
      //   player).
      // - Camera: a camera-only request (getUserMedia video, e.g. a banking
      //   site's QR scanner). In `virtual` mode the camera-stream shim
      //   intercepts getUserMedia in JS and this native request never fires,
      //   so reaching here means the shim decided `real` (or is absent) and
      //   called through to the platform. We resolve the decision and grant
      //   only for `real`, additionally ensuring the app-level CAMERA
      //   runtime permission on Android. Requests that bundle the microphone
      //   (iOS/macOS report the single resource CAMERA_AND_MICROPHONE,
      //   Android CAMERA+MICROPHONE) never reach the camera flow.
      // - Microphone: resolved the same way, and granted only for a site the
      //   user allowed that is also the one on screen. Everything else is an
      //   explicit DENY rather than the PROMPT fallback, which iOS/macOS
      //   render as WebKit's own prompt (Android/Linux would deny anyway).
      //   The combined camera+microphone resource cannot be half-granted, so
      //   it needs both decisions to be `real`; the shims normally split such
      //   a request before it reaches here.
      //
      // Screen sharing never reaches here on any platform this app ships, and
      // that is a property to preserve rather than an omission: Android
      // WebView's WebChromeClient has no display-capture resource, WKWebView
      // (iOS/macOS) routes only WKMediaCaptureType camera/microphone through
      // the plugin, and the Linux WPE plugin maps a display-device user-media
      // request to an EMPTY resource list, which it denies natively before
      // Dart is consulted. There is likewise no PermissionResourceType that
      // names a display, so nothing here could single one out even if it
      // arrived; the fallback below would deny it on Android and Linux and
      // hand it to WebKit's own prompt on iOS/macOS. If a fork bump ever adds
      // such a resource type, it must be denied explicitly right here — that
      // is what `test/screen_share_native_denial_test.dart` fails over
      // (SHARE-003).
      //
      // The fallback returns PROMPT for everything else: Android and Linux
      // WPE map any non-GRANT action to deny (their no-handler default),
      // iOS 15+/macOS 12+ show WebKit's own per-site prompt.
      onPermissionRequest: grants == null
          ? null
          : (controller, request) async {
              final wantsProtectedMedia = hostIsAndroid &&
                  request.resources.contains(
                      inapp.PermissionResourceType.PROTECTED_MEDIA_ID);
              if (wantsProtectedMedia) {
                final granted =
                    await grants.protectedContent(request.origin.toString());
                return inapp.PermissionResponse(
                  resources: [
                    inapp.PermissionResourceType.PROTECTED_MEDIA_ID
                  ],
                  action: granted
                      ? inapp.PermissionResponseAction.GRANT
                      : inapp.PermissionResponseAction.DENY,
                );
              }
              // Asked lazily: a request the app leaves to the platform needs
              // no origin.
              late final where = () async {
                final top = await PageHandlers.promptOrigin(controller, config: config);
                final from = request.origin.toString();
                final isTopFrame = PageHandlers.sameOrigin(top, b: from);
                return (origin: isTopFrame ? top : from, isTopFrame: isTopFrame);
              }();
              final cameraAndMicrophone =
                  inapp.PermissionResourceType.CAMERA_AND_MICROPHONE;
              final resources = request.resources;
              final answer = await CapturePermissionEngine.answer((
                camera: resources.contains(inapp.PermissionResourceType.CAMERA) ||
                    resources.contains(cameraAndMicrophone),
                microphone:
                    resources.contains(inapp.PermissionResourceType.MICROPHONE) ||
                        resources.contains(cameraAndMicrophone),
                other: resources.any((r) =>
                    r != inapp.PermissionResourceType.CAMERA &&
                    r != inapp.PermissionResourceType.MICROPHONE &&
                    r != cameraAndMicrophone),
              ), host: (
                opensDevice: (kind) async {
                  final (:origin, :isTopFrame) = await where;
                  final grant = await grants.capture(kind, origin: origin,
                      isTopFrame: isTopFrame);
                  return opensRealDevice(grant.mode.state);
                },
                cameraPermission: CameraPermissionService.ensurePermission,
                microphonePermission:
                    MicrophonePermissionService.ensurePermission,
              ));
              return inapp.PermissionResponse(
                resources: resources,
                action: switch (answer) {
                  DeviceAnswer.grant => inapp.PermissionResponseAction.GRANT,
                  DeviceAnswer.deny => inapp.PermissionResponseAction.DENY,
                  DeviceAnswer.prompt => inapp.PermissionResponseAction.PROMPT,
                },
              );
            },
      // Android's WebChromeClient asks the app before the WebView reaches the
      // OS location service. Always deny: no mode needs this path. `off`,
      // `spoof` and a coordinate-less site are refused by the shim, and `live`
      // is served through the `getRealLocation` bridge, which applies the
      // site's granularity snapping before the fix leaves Dart. Granting here
      // would hand a live site the raw platform fix and silently bypass the
      // approximate/GSM tiers.
      //
      // The plugin already denies when this is unset, but that is its default
      // rather than our contract; wiring it makes a dependency bump unable to
      // turn pass-through back on. Android-only, ignored elsewhere.
      onGeolocationPermissionsShowPrompt: (controller, origin) async =>
          inapp.GeolocationPermissionShowPromptResponse(
            origin: origin,
            allow: false,
            retain: false,
          ),
      // A messageless alert on a webview that has been through the iOS/macOS
      // per-instance pause is that pause's own `alert()`, arriving after
      // `resumeTimers()` stopped withholding it — never something the page
      // asked for (PAUSE-030). Answer it so WebKit drops it instead of
      // presenting an empty system dialog over the app; everything else
      // returns null and keeps the plugin's default dialog.
      onJsAlert: (controller, request) async {
        if (!isEscapedPauseTimersAlert(
          pauseWasIssued: pauseHack.pauseWasIssued,
          message: request.message,
          isMainFrame: request.isMainFrame,
        )) {
          return null;
        }
        LogTag.webView.debug(
            'Swallowed escaped pauseTimers() alert for siteId=${config.posture.siteId}',
            sensitive: true);
        return inapp.JsAlertResponse(handledByClient: true);
      },
      onWebViewCreated: (controller) async {
        coverageGate = ProxyCoverageGate(
          binding: ProxyManager.binding,
          proxyConfigured: binding.proxyConfigured,
          mountUrl: config.initialUrl,
        );
        final wrappedController = view = PlatformWebViewController(
          controller,
          pauseHack: pauseHack,
          settings: settings,
          fileImport: fileImport,
        );
        onControllerCreated(wrappedController);
        PageHandlers.registerPageHandlers(
          controller,
          config: config,
          userScriptService: userScriptService,
          sourceUrl: () => lastLoadStartUrl,
        );
        if (iconEngine != null) {
          // Frame-aware, all three: Blink and WebKit take icons from the top
          // document only, so a subframe has nothing to say about them.
          controller.addJavaScriptHandler(
            handlerName: kIconLinksChangedHandler,
            callback: (inapp.JavaScriptHandlerFunctionData call) {
              if (call.isMainFrame) iconEngine.onIconLinksChanged();
              return null;
            },
          );
          if (iconFetcher != null) {
            // Never beside onReceivedIcon: on Android the report reaches
            // Dart through a posted Java message, which onReceivedIcon can
            // overtake, so it cannot tell which document that icon came
            // from. The link report rides the same bridge, in order.
            controller.addJavaScriptHandler(
              handlerName: kIconDocumentLoadedHandler,
              callback: (inapp.JavaScriptHandlerFunctionData call) {
                if (call.isMainFrame) {
                  iconEngine
                      .onDocumentLoaded(call.requestUrl.toString())
                      .forEach(siteIcon!.onIcon);
                }
                logSiteIcon('documentLoaded main=${call.isMainFrame} '
                    '${iconEngine.stateForLog}');
                return null;
              },
            );
            controller.addJavaScriptHandler(
              handlerName: kIconLinksHandler,
              callback: (inapp.JavaScriptHandlerFunctionData call) {
                if (!call.isMainFrame) return null;
                final documentUrl = call.requestUrl.toString();
                final document = iconEngine.claimIconLinks(documentUrl);
                logSiteIcon('links claim=$document ${iconEngine.stateForLog}');
                if (document == null) return null;
                final links = SiteIconLink.listFrom(
                    call.args.isEmpty ? null : call.args.first);
                final urls =
                    siteIconCandidates(links, documentUrl: documentUrl);
                unawaited(iconFetcher
                    .best(urls, documentUrl: documentUrl)
                    .then((icon) {
                  if (icon == null) {
                    logSiteIcon('linked doc=$document none');
                    return;
                  }
                  final accepted =
                      iconEngine.onLinkedIcon(document, png: icon.png);
                  logSiteIcon('linked doc=$document ${icon.edge}px '
                      'taken=${accepted != null} ${iconEngine.stateForLog}');
                  if (accepted != null) siteIcon!.onIcon(accepted);
                }).catchError((Object e) {
                  LogTag.icon
                      .warning('Page icon fetch failed: $e', sensitive: true);
                }));
                return null;
              },
            );
          }
        }
        if (siteSearch != null) {
          // Every page of a SearXNG instance links the same description; one
          // read per webview is enough.
          final readDescriptions = <String>{};
          controller.addJavaScriptHandler(
            handlerName: kSearchLinksHandler,
            callback: (inapp.JavaScriptHandlerFunctionData call) {
              if (!call.isMainFrame) return null;
              final report = PageSearchReport.from(
                  call.args.isEmpty ? null : call.args.first);
              if (report == null) return null;
              final documentUrl = call.requestUrl.toString();
              unawaited(discoverPageSearch(
                report,
                documentUrl: documentUrl,
                siteUrl: siteSearch.siteUrl,
                fetch: (description) async {
                  if (!readDescriptions.add(description.toString())) {
                    return null;
                  }
                  return fetchPageLinkedBytes(
                    description.toString(),
                    documentHost: call.requestUrl.host,
                    proxy: config.posture.container.proxy,
                    maxBytes: kMaxOpenSearchBytes,
                    allowed: (target) => pageIconRequestAllowed(
                        config, target: target, documentUrl: documentUrl,
                        requestType: 'other'),
                  );
                },
              ).then((found) {
                if (found != null) siteSearch.onSearch(found);
              }));
              return null;
            },
          );
        }
        // Cached-HTML → live-URL swap is wired up in onLoadStop below.
        // Don't fire loadUrl here — `onWebViewCreated` runs while chromium
        // is still parsing the initialData, and a synchronous loadUrl in
        // that window aborts the in-flight parse (load-while-loading),
        // which on Android System WebView trips a dangling-raw_ptr in the
        // renderer process at `partition_alloc_support.cc:770`.
        //
        // Container API bind happens natively inside the WebSpace fork's
        // `InAppWebView.prepare()`, driven by the `containerId` we set on
        // `InAppWebViewSettings` above. By the time `onWebViewCreated`
        // fires, the WebView is already bound to its per-site container
        // and every cookie / IDB / ServiceWorker / cache write that
        // follows is partitioned to that container.
        //
        // The WebView's own WebAuthn (PASSKEY-010), the comparison path to
        // the bridge: the engine asserts the page origin itself. Set once the
        // view is in the hierarchy, since that is where the plugin finds it.
        if (hostIsAndroid &&
            config.passkeys?.backend == PasskeyBackend.webView) {
          Future.microtask(() async {
            try {
              final kept = await PasskeyNative.setWebViewSupport('browser');
              LogTag.passkey.debug('WebView support: $kept');
            } catch (e) {
              LogTag.passkey.warning('WebView support failed: $e');
            }
          });
        }
        // Attach native interceptor (DNS blocking + LocalCDN serving) once
        // the view is in the hierarchy. Always attach on Android — the
        // handler no-ops cheaply when neither blocklist nor CDN cache are
        // populated, and the references are shared with the plugin so
        // subsequent updates are picked up without re-attaching.
        if (hostIsAndroid) {
          // Track attach attempts so we can correlate with the
          // native-side "attachToAllWebViews" log. Helps
          // debug the case where Android sub-resources aren't blocked
          // — first thing to check is whether attach is even running.
          LogTag.webView.debug(
              'requesting native interceptor attach: siteId=${config.posture.siteId} '
              'initialUrl=${config.initialUrl}', sensitive: true);
          Future.microtask(() => WebInterceptNative.attachToWebViews(
              siteId: config.posture.siteId,
              dnsLevel: config.effectiveDnsLevel,
              localCdn: config.posture.blocking.localCdn));
        }
      },
      shouldOverrideUrlLoading: (controller, navigationAction) async {
        // Bump the navigation generation FIRST. Any in-flight `onLoadStart`
        // handler from the previous navigation that's about to fire an
        // `evaluateJavascript` IPC will see the advance and skip the call,
        // so the IPC isn't bound to a frame chromium is in the middle of
        // tearing down.
        navigationGen++;
        final url = navigationAction.request.url.toString();
        if (_shouldBlockUrl(url)) return inapp.NavigationActionPolicy.CANCEL;
        // External app schemes (intent://, tel:, mailto:, market:, custom
        // app schemes) can't be rendered in a webview — flutter_inappwebview
        // returns ERR_UNKNOWN_URL_SCHEME. Cancel and hand the URL to the
        // host UI, which confirms with the user before calling url_launcher.
        // Don't call controller.stopLoading() here — chromium has crashed
        // with a dangling raw_ptr when stopLoading runs concurrently with
        // a synchronous CANCEL path. The CANCEL alone aborts the
        // navigation; if Android still paints ERR_UNKNOWN_URL_SCHEME,
        // onReceivedError handles recovery.
        final externalInfo = ExternalUrlParser.parse(url);
        if (externalInfo != null) {
          LogTag.webView.debug(
              'External scheme intercepted: scheme=${externalInfo.scheme} '
              'package=${externalInfo.package} fallback=${externalInfo.fallbackUrl} url=$url',
              sensitive: true);
          // External scheme with a resolvable web URL (intent:// fallback,
          // x-safari-http(s) force-open): route it through the standard
          // same-domain / cross-domain path, no confirmation prompt. We
          // are the browser; handing the user off to a different app for
          // a URL they clicked inside us is hostile behavior (Google Maps
          // fires intents constantly, x.com bounces every in-app-browser
          // visit to Safari). Same base domain → load in this webview;
          // cross-domain → nested via shouldOverrideUrlLoading. Schemes
          // *without* a web equivalent (zxing scanner, custom-app deep
          // links, tel:) still hit the confirmation dialog.
          final resolved = ExternalUrlParser.toWebUrl(externalInfo);
          if (resolved != null) {
            // The reissued load below lands on the top-frame controller, so
            // a subframe must not reach it (NESTED-013): an ad iframe would
            // otherwise steer the top document with the session attached.
            if (navigationAction.isForMainFrame == false) {
              return inapp.NavigationActionPolicy.CANCEL;
            }
            final hasGesture = _hasUserGesture(navigationAction);
            // Loop guard (EXT-007): x.com re-fires its Safari bounce on
            // every page render — resolving it again would reload the
            // fallback forever. A script-driven re-fire inside the
            // suppression window is dropped; a user-gesture nav is the
            // user deliberately clicking, so it always routes.
            if (!hasGesture &&
                ExternalUrlSuppressor.isSuppressedInfo(externalInfo)) {
              LogTag.webView.debug(
                  'silent route suppressed (recently routed): $url',
                  sensitive: true);
              return inapp.NavigationActionPolicy.CANCEL;
            }
            ExternalUrlSuppressor.mark(externalInfo);
            LogTag.webView.debug(
                'external scheme resolved → $resolved (from $url)',
                sensitive: true);
            bool allow = true;
            if (config.shouldOverrideUrlLoading != null) {
              allow = config.shouldOverrideUrlLoading!(resolved,
                  hasGesture: hasGesture);
            }
            if (allow) {
              controller.loadUrl(urlRequest: inapp.URLRequest(url: inapp.WebUri(resolved)));
            }
            return inapp.NavigationActionPolicy.CANCEL;
          }
          config.hooks.externalScheme(externalInfo, loadIn: view);
          return inapp.NavigationActionPolicy.CANCEL;
        }
        // Counted even with no list loaded, so the per-site log reflects
        // the visit. The source is the page that started the navigation.
        final verdict = judgeAndRecord(
          config,
          query: UrlQuery(url,
              sourceUrl: lastLoadStartUrl ?? '', requestType: 'document'),
        );
        if (verdict is! Allowed) return inapp.NavigationActionPolicy.CANCEL;
        // Cross-domain → nested-webview routing applies to MAIN-FRAME
        // navigations only. On Android API 24+ chromium fires
        // shouldOverrideUrlLoading for child-frame (iframe) navigations
        // as well, with `isForMainFrame == false` distinguishing them.
        // If we forwarded those into the engine we'd open every
        // embedded iframe (Google One Tap GSI, Cloudflare challenge
        // iframe, third-party SSO popups) as a separate top-level
        // webview — wrong, intrusive, and on Android can race the
        // chromium frame-lifecycle code path that the
        // `partition_alloc_support.cc:770` dangle ride sits on top
        // of. Allow iframe navigations to load in-place; the engine
        // sees only main-frame navigations.
        final isMainFrame = navigationAction.isForMainFrame;
        // Diagnostic: log the raw isForMainFrame so we can tell
        // when a platform reports true vs. false. WebKit2GTK
        // on Linux has been observed to return true for navigations
        // that originate from inside an iframe; Android API 24+
        // returns false for child-frame navigations consistently.
        LogTag.webView.debug(
            'shouldOverrideUrlLoading: isForMainFrame=${navigationAction.isForMainFrame}');
        if (!isMainFrame) {
          return inapp.NavigationActionPolicy.ALLOW;
        }
        // URL rewrites (ClearURLs, $removeparam) drive a load on the TOP
        // frame, so they live below the main-frame gate: a cross-origin
        // subframe navigation must never be able to steer the top document.
        // The rewrite target is likewise re-checked before it is loaded — a
        // ClearURLs redirection rule yields whatever the matched URL carried
        // in its capture group, and `loadUrl` on Android takes any scheme.
        if (config.posture.blocking.clearUrls && ClearUrlService.instance.hasRules) {
          final cleanedUrl = ClearUrlService.instance.cleanUrl(url);
          if (cleanedUrl.isEmpty) return inapp.NavigationActionPolicy.CANCEL;
          if (cleanedUrl != url &&
              ExternalUrlParser.isLoadableWebUrl(cleanedUrl)) {
            BlockStatsService.instance.record(
              config.posture.siteId,
              category: BlockCategory.trackingParam,
              label:
                  ClearUrlService.strippedParamLabel(url, cleaned: cleanedUrl),
            );
            controller.loadUrl(urlRequest: inapp.URLRequest(url: inapp.WebUri(cleanedUrl)));
            return inapp.NavigationActionPolicy.CANCEL;
          }
        }
        // ABP $removeparam=: a rule-driven sibling of ClearURLs. EasyList
        // & co. ship $removeparam=utm_source (etc.); the Rust engine
        // strips matching keys. Runs AFTER ClearURLs so the static
        // rules go first and the filter list catches what they miss.
        // No-op when the engine is off or the URL has no query.
        if (config.posture.blocking.contentBlock &&
            ContentBlockerService.instance.usingRustEngine &&
            url.contains('?')) {
          // requestType: 'document' — adblock-rust restricts
          // \$removeparam= to document/subdocument/xhr by default,
          // and a main-frame nav IS a document fetch. Without this
          // the engine returns no rewrite even when a matching
          // filter is loaded.
          final rewritten = ContentBlockerService.instance
              .rewrittenUrl(url, requestType: 'document');
          if (rewritten != null &&
              rewritten != url &&
              ExternalUrlParser.isLoadableWebUrl(rewritten)) {
            LogTag.contentBlocker.debug(
                '\$removeparam= rewrote $url → $rewritten', sensitive: true);
            controller.loadUrl(
                urlRequest: inapp.URLRequest(url: inapp.WebUri(rewritten)));
            return inapp.NavigationActionPolicy.CANCEL;
          }
        }
        if (config.shouldOverrideUrlLoading != null) {
          final hasGesture = _hasUserGesture(navigationAction);
          final allow =
              config.shouldOverrideUrlLoading!(url, hasGesture: hasGesture);
          if (!allow) return inapp.NavigationActionPolicy.CANCEL;
        }
        // Fail closed where the platform cannot be shown to put this request
        // through the site's proxy (LEAK-010). Below the routing decision
        // above, because a navigation that decision hands to a nested webview
        // or the system browser is not a request this webview makes: the
        // nested one mounts on it, and a mounting navigation is the one the
        // store's proxy does cover. The rewrites above reach here on their
        // reissued pass, so a cleaned URL is judged on its own merits rather
        // than riding the original's decision.
        if (url.startsWith('http') &&
            coverageGate.evaluate(url) == ProxyCoverage.unprovable) {
          LogTag.proxy.warning(
              'Navigation blocked: proxy coverage not established for $url '
              '(siteId=${config.posture.siteId})', sensitive: true);
          config.onUnproxiedNavigationBlocked?.call(url);
          return inapp.NavigationActionPolicy.CANCEL;
        }
        // HTTPS upgrade, decided AFTER the routing decision above for the same
        // reason the captcha allow is (HTTPS-004): taken first, a scheme
        // rewrite re-enters the pipeline with the gesture requirement and the
        // cross-domain nested route already behind it.
        final upgrade = WebViewFactory.httpsUpgrade
            .onNavigation(url, enabled: config.posture.blocking.httpsUpgrade);
        if (upgrade.armDeadlineFor != null) {
          final armed = upgrade.armDeadlineFor!;
          final genAtUpgrade = navigationGen;
          Timer(WebViewFactory.httpsUpgrade.deadline, () {
            final out = WebViewFactory.httpsUpgrade.onDeadline(
              armed,
              generationAtArm: genAtUpgrade,
              currentGeneration: () => navigationGen,
            );
            if (out.load != null) {
              LogTag.webView.debug(
                  'https upgrade timed out, falling back to ${out.load}',
                  sensitive: true);
              controller.loadUrl(
                  urlRequest: inapp.URLRequest(url: inapp.WebUri(out.load!)));
            }
          });
        }
        if (upgrade.load != null) {
          LogTag.webView.debug(
              '  -> CANCEL (https upgrade) $url', sensitive: true);
          controller.loadUrl(
              urlRequest: inapp.URLRequest(url: inapp.WebUri(upgrade.load!)));
        }
        if (upgrade.cancel) return inapp.NavigationActionPolicy.CANCEL;
        // A captcha challenge loads in place. Decided AFTER the routing
        // decision above, never before it: taken first, "is this a captcha
        // URL?" becomes a way to navigate the parent webview to any origin
        // with the gesture requirement and the cross-domain nested route
        // skipped.
        if (isCaptchaChallenge(url, siteUrl: config.initialUrl)) {
          return inapp.NavigationActionPolicy.ALLOW;
        }
        // iOS Universal Link bypass. WKWebView auto-routes user-tap
        // navigations (and redirect chains rooted in a tap) to the
        // native app for URLs whose host matches an installed app's
        // AASA — even when the user explicitly added the site to
        // WebSpace. iOS exposes no public API to detect AASA matches,
        // so the bypass treats every tap-rooted main-frame http(s)
        // navigation as at-risk: cancel + reissue via `loadUrl`.
        // WebKit treats programmatic loads as navigation type
        // `.other` and skips AASA matching, keeping the page inside
        // the webview regardless of which apps are installed. The
        // reissued nav fires `shouldOverrideUrlLoading` again; the
        // per-URL memo passes that second pass through.
        //
        // Scoped to LINK_ACTIVATED plus bodyless (GET/HEAD)
        // FORM_SUBMITTED. A body-carrying form POST is passed through:
        // reissuing it via `loadUrl` (a GET) would drop the POST body
        // and break every credentialed form on the web (logins, search,
        // payments) — LinkedIn's `/checkpoint/lg/login-submit` was the
        // canonical 404 case. But WKWebView also tags the server
        // redirect that *follows* a form POST as FORM_SUBMITTED, and
        // that hop is re-fetched as a GET (302/303 → GET). That hop is
        // exactly the one that lets Google Maps'
        // `consent.google.com/save → maps.google.com` redirect escape
        // into the native app, so a GET/HEAD FORM_SUBMITTED is eligible.
        //
        // Pure programmatic navigations (initial nav, server
        // redirects without a tap origin, pushState) carry no user
        // gesture — they don't activate AASA in the first place and
        // are passed through here without interception.
        if (hostIsIOS &&
            IosUniversalLinkBypass.isEligibleNavigation(
              isMainFrame: isMainFrame,
              url: url,
              isLinkActivated: navigationAction.navigationType ==
                  inapp.NavigationType.LINK_ACTIVATED,
              isFormSubmitted: navigationAction.navigationType ==
                  inapp.NavigationType.FORM_SUBMITTED,
              httpMethod: navigationAction.request.method,
            )) {
          if (iosUlBypass.shouldCancelAndReissue(url)) {
            LogTag.webView.debug(
                '  -> CANCEL (iOS UL bypass: reissuing programmatically) $url',
                sensitive: true);
            final originalUrl = navigationAction.request.url;
            final originalHeaders = navigationAction.request.headers;
            controller.loadUrl(urlRequest: inapp.URLRequest(
              url: originalUrl,
              headers: originalHeaders,
            ));
            return inapp.NavigationActionPolicy.CANCEL;
          }
          LogTag.webView.debug(
              '  -> ALLOW (iOS UL bypass: reissued nav passing through)',
              sensitive: true);
        }
        return inapp.NavigationActionPolicy.ALLOW;
      },
      onLongPressHitTestResult: (controller, hitTestResult) {
        if (config.onLinkLongPress == null) return;
        // Only a link. An image or a phone number long-press has nothing to
        // open in a tab, and `extra` for those is not a URL.
        if (hitTestResult.type != inapp.InAppWebViewHitTestResultType.SRC_ANCHOR_TYPE &&
            hitTestResult.type !=
                inapp.InAppWebViewHitTestResultType.SRC_IMAGE_ANCHOR_TYPE) {
          return;
        }
        final extra = hitTestResult.extra;
        if (extra == null || extra.isEmpty) return;
        final uri = Uri.tryParse(extra);
        if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
          return;
        }
        config.onLinkLongPress!(extra);
      },
      onCreateWindow: (controller, createWindowAction) async {
        final url = createWindowAction.request.url?.toString() ?? '';
        final windowId = createWindowAction.windowId;
        LogTag.webView.debug(
            'onCreateWindow: url=$url windowId=$windowId', sensitive: true);

        if (isCaptchaChallenge(url, siteUrl: config.initialUrl)) {
          // The host builds the popup widget out of a BuildContext that has
          // no site attached; hand it this webview's posture by windowId so
          // createPopupWebView can inherit it. showPopup resolves when the
          // popup dialog closes, so the entry is short-lived.
          PopupWebView.popupParentConfigs[windowId] = config;
          try {
            await config.hooks.showPopup(windowId, url: url);
          } finally {
            PopupWebView.popupParentConfigs.remove(windowId);
          }
          return true;
        }

        // target="_blank" links can carry external app schemes too (e.g.
        // a `<a target="_blank" href="intent://...">`). Route them through
        // the same confirmation path as direct navigations.
        final externalInfo = ExternalUrlParser.parse(url);
        if (externalInfo != null) {
          LogTag.webView.debug('External scheme intercepted (onCreateWindow): '
              'scheme=${externalInfo.scheme} package=${externalInfo.package} url=$url',
              sensitive: true);
          final resolved = ExternalUrlParser.toWebUrl(externalInfo);
          if (resolved != null) {
            final hasGesture = _hasUserGesture(createWindowAction);
            // Same loop guard as shouldOverrideUrlLoading (EXT-007).
            if (!hasGesture &&
                ExternalUrlSuppressor.isSuppressedInfo(externalInfo)) {
              LogTag.webView.debug(
                  'silent route suppressed (onCreateWindow, recently routed): $url',
                  sensitive: true);
              return false;
            }
            ExternalUrlSuppressor.mark(externalInfo);
            LogTag.webView.debug(
                'external scheme resolved (onCreateWindow) → $resolved (from $url)',
                sensitive: true);
            bool allow = true;
            if (config.shouldOverrideUrlLoading != null) {
              allow = config.shouldOverrideUrlLoading!(resolved,
                  hasGesture: hasGesture);
            }
            // A window this webview did not ask for by gesture never loads
            // into it (NESTED-013); a real target="_blank" tap is rewritten
            // before it gets here (NESTED-008).
            if (allow && hasGesture) {
              controller.loadUrl(urlRequest: inapp.URLRequest(url: inapp.WebUri(resolved)));
            }
            return false;
          }
          config.hooks.externalScheme(externalInfo, loadIn: view);
          return false;
        }

        // For target="_blank" links (e.g., badge clicks on GitHub), delegate
        // to shouldOverrideUrlLoading which handles cross-domain navigation
        // by opening a nested webview. On iOS, target="_blank" links may
        // only trigger onCreateWindow without shouldOverrideUrlLoading.
        // Script-initiated window.open() (analytics, Stripe) have no user
        // gesture and are silently blocked by the auto-redirect check.
        if (url.startsWith('http') && config.shouldOverrideUrlLoading != null) {
          final hasGesture = _hasUserGesture(createWindowAction);
          final allow =
              config.shouldOverrideUrlLoading!(url, hasGesture: hasGesture);
          if (allow && hasGesture) {
            // Same-domain target="_blank": load in current webview
            controller.loadUrl(urlRequest: inapp.URLRequest(url: inapp.WebUri(url)));
          }
        }

        return false;
      },
      // Dart shouldInterceptRequest is intentionally unset — see the
      // useShouldInterceptRequest comment above. Sub-resource DNS blocking
      // and LocalCDN replacement are both handled by the native
      // FastSubresourceInterceptor attached via WebInterceptNative.
      onProgressChanged: config.onProgressChanged == null
          ? null
          : (controller, progress) {
              config.onProgressChanged!(progress);
            },
      onLoadStart: (controller, url) async {
        LogTag.webViewLifecycle.debug(
            'onLoadStart siteId=${config.posture.siteId} url=$url',
            sensitive: true);
        // A passkey ceremony belongs to the document that started it, and a
        // main-frame load replaces that document (PASSKEY-015).
        final pendingPasskey = passkeyGate.active;
        if (pendingPasskey != null &&
            pendingPasskey.startsWith('${passkeyWebviewKey(controller)}:')) {
          LogTag.passkey.debug('page left, request cancelled');
          unawaited(PasskeyNative.cancel(pendingPasskey));
        }
        if (iconEngine != null) {
          iconEngine.onLoadStarted(url?.toString()).forEach(siteIcon!.onIcon);
          logSiteIcon('loadStart ${iconEngine.stateForLog}');
        }
        // Taken before any await: see `navigationGen`.
        final myGen = navigationGen;
        bool stillCurrent() => navigationGen == myGen;

        // The server answered for an upgrade of ours, so the deadline stops
        // applying to it: a page that is slow to finish is not a connection
        // that never got going, and treating the two alike downgrades a
        // working https host on a bad link and records it http-only for the
        // rest of the session (HTTPS-002).
        if (url != null) {
          WebViewFactory.httpsUpgrade.onLoadStarted(url.toString());
        }
        config.onLoadingChanged?.call(loading: true);
        if (url != null) {
          config.onMainFrameLoad
              ?.call(MainFrameLoadSignal.started(url.toString()));
        }

        lastLoadStartUrl = url?.toString();
        failedNavUrl = null;
        // Counted here too, so the stats banner shows a cached-HTML load
        // that never reached shouldOverrideUrlLoading.
        if (url != null && url.toString().startsWith('http')) {
          final page = url.toString();
          judgeAndRecord(config,
              query: UrlQuery(page, sourceUrl: page, requestType: 'document'));
        }
        // One evaluateJavascript, not one per script: each IPC is a race
        // window against Chromium's frame teardown.
        final earlyScripts = <String>[];
        if (config.posture.blocking.contentBlock && url != null) {
          final cssScript =
              ContentBlockerService.instance.getEarlyCssScript(url.toString());
          if (cssScript != null) earlyScripts.add(cssScript);
        }
        if (config.posture.blocking.clearUrls) {
          earlyScripts.add(PageJs.clearUrlShare.script);
        }
        if (earlyScripts.isNotEmpty && stillCurrent()) {
          await view?.evaluateJavascript(earlyScripts.join('\n'));
        }
        if (stillCurrent()) {
          await userScriptService.reinjectOnLoadStart(controller);
        }
      },
      // The Android plugin dispatches only this callback; onFaviconChanged,
      // its replacement, is wired for Windows alone in the pinned fork.
      // ignore: deprecated_member_use
      onReceivedIcon: iconEngine == null || iconSource != PageIconSource.webview
          ? null
          : (controller, icon) {
              final accepted = iconEngine.onIcon(icon);
              logSiteIcon('webview ${pngDimensions(icon)?.width}px '
                  'taken=${accepted != null} ${iconEngine.stateForLog}');
              if (accepted != null) siteIcon!.onIcon(accepted);
            },
      onPageCommitVisible: (controller, url) {
        LogTag.webViewLifecycle.debug(
            'onPageCommitVisible siteId=${config.posture.siteId} url=$url',
            sensitive: true);
        config.onPageCommitVisible?.call();
      },
      onLoadStop: (controller, url) async {
        LogTag.webViewLifecycle.debug(
            'onLoadStop siteId=${config.posture.siteId} url=$url',
            sensitive: true);
        if (iconEngine != null) {
          iconEngine.onLoadFinished(url?.toString()).forEach(siteIcon!.onIcon);
          logSiteIcon('loadStop ${iconEngine.stateForLog}');
        }
        // An upgrade that loaded is no longer in flight. Without this the
        // engine's map grows by one per upgraded navigation, and a later
        // unrelated failure on the same URL string reads as a fallback to an
        // http load that finished long ago (HTTPS-002).
        if (url != null) {
          WebViewFactory.httpsUpgrade.onLoadFinished(url.toString());
        }
        config.pullToRefreshGate?.controller?.endRefreshing();
        // Whether or not `url` is renderable: the loading UI does not
        // depend on the snapshot logic below.
        config.onLoadingChanged?.call(loading: false);
        config.onMainFrameLoad?.call(const MainFrameLoadSignal.settled());
        if (url == null) return;
        final urlStr = url.toString();

        // Downloads, javascript: bookmarklets, and other non-renderable
        // schemes can reach here when controller.stopLoading() interrupts
        // an in-flight navigation (the download path does this to keep
        // the webview from rendering the attachment as a page). There's
        // no real page to snapshot — onHtmlLoaded would end up writing
        // either the previous page's HTML keyed under the download URL,
        // or empty content, clobbering a legitimate offline cache entry.
        // Skip all post-load work in that case; onDownloadStartRequest's
        // revert handles URL bar restoration.
        if (!DownloadUrlRevertEngine.isRenderable(urlStr)) return;

        // Cached-HTML one-shot live refresh. After the cached HTML
        // parse settles, fire a single `controller.reload()` to fetch
        // a fresh copy of the page over the network. The
        // `pendingLiveReload` flag is consumed on first use so the
        // subsequent (post-reload) onLoadStop doesn't recurse.
        //
        // Gated on `navigationGen == 0` — i.e. no shouldOverrideUrlLoading
        // has fired yet. If the user clicked anything during the cached
        // parse, gen > 0 and we skip the reload; their navigation is the
        // current intent. (`reload()` itself does not bump
        // navigationGen on Android WebView.)
        //
        // Offline, the cached page is the answer until the network comes
        // back: `awaitOnlineForLiveSwap` re-probes for a bounded window,
        // because a snapshot rendered on return from the background settles
        // before a per-app firewall lets the app back out, and a single
        // probe there stranded the snapshot for good.
        //
        // Each probe is a DNS lookup with up to a 3s timeout — long enough
        // for the user to tap a link or trigger a back/forward gesture.
        // `navigationGen` is re-checked after every probe so the
        // live-reload doesn't clobber a navigation that started meanwhile.
        final firedLiveReload = pendingLiveReload && navigationGen == 0;
        if (firedLiveReload) {
          pendingLiveReload = false;
          final genAtSchedule = navigationGen;
          awaitOnlineForLiveSwap(
            isOnline: ConnectivityService.instance.isOnline,
            stillWanted: () => navigationGen == genAtSchedule,
          ).then((online) async {
            if (!online) {
              LogTag.webView.debug(
                  'Cached snapshot kept: offline or navigated away');
              return;
            }
            config.onReloadIssued?.call();
            await view?.reload();
          });
        }

        lastStableUrl = DownloadUrlRevertEngine.updateStable(lastStableUrl,
            loadedUrl: urlStr);
        config.onUrlChanged?.call(urlStr);
        final onCookiesChanged = config.onCookiesChanged;
        if (onCookiesChanged != null) {
          // The container engine reads the bound container's jar through
          // the fork's `webViewController:`; the legacy one, the shared jar.
          final container = config.hooks.containerCookieManager;
          final pageUrl = Uri.parse(urlStr);
          onCookiesChanged(container != null
              ? await container.getCookies(
                  controller: PlatformWebViewController(controller,
                      pauseHack: pauseHack, settings: settings),
                  siteId: config.posture.siteId,
                  url: pageUrl,
                )
              : await config.hooks.cookieManager.getCookies(url: pageUrl));
        }
        // Inject full cosmetic script: MutationObserver + text-based hiding
        if (config.posture.blocking.contentBlock) {
          final script = ContentBlockerService.instance.getCosmeticScript(urlStr);
          if (script != null) await view?.evaluateJavascript(script);
        }
        await userScriptService.reinjectOnLoadStop(controller);
        // Cache HTML for offline viewing. Pre-gate the renderer IPC
        // via shouldFetchHtml so the per-onLoadStop storm is collapsed
        // before we ask chromium to serialize the DOM — the IPC, not
        // the encrypt+write afterward, is the lifecycle-racing piece.
        //
        // Skip when we just fired the cached-then-live reload above:
        // the reload IPC reaches the renderer before our snapshot
        // does, so the serialized DOM here is the partial mid-reload
        // markup (often a few-KB SPA shell) — and saving that clobbers
        // the previously-cached fully-rendered snapshot. On next launch
        // the corrupt shell loads as initialData and the SPA's hydration
        // throws (`Cannot read properties of null`) leaving a blank
        // page. The post-reload `onLoadStop` saves the live HTML
        // instead; `_lastSaveAt` isn't bumped here, so its debounce
        // stays open.
        if (config.onHtmlLoaded != null
            && !firedLiveReload
            && failedNavUrl == null
            && (config.shouldFetchHtml?.call() ?? true)) {
          final snapshot =
              await view?.evaluateJavascriptReturning(PageJs.htmlSnapshot.script);
          if (snapshot is String && snapshot.isNotEmpty) {
            // `urlStr` was captured at onLoadStop entry. The snapshot is
            // an async IPC into the renderer; if the user kicked off a
            // back/forward gesture or a link tap during that round trip,
            // the markup we got back belongs to the *new* page, not
            // `urlStr`. Saving (urlStr, html-of-new-page) under `siteId`
            // poisons the cache: next webview construction renders that
            // mismatched HTML at `baseUrl=currentUrl`, so the user sees
            // the wrong page when they swipe back into the cached entry.
            // Re-read the URL post-snapshot and skip the save on
            // mismatch — the next stable onLoadStop will write the
            // right pair.
            final liveUrl = (await view?.getUrl())?.toString();
            if (liveUrl == urlStr) {
              config.onHtmlLoaded!(urlStr, html: snapshot);
            } else {
              LogTag.webView.debug(
                  'Skipping cache save: URL changed during snapshot '
                  '($urlStr -> $liveUrl)', sensitive: true);
            }
          }
        }
      },
      onUpdateVisitedHistory: (controller, url, androidIsReload) {
        // Fires on every history change including back/forward gestures.
        // onLoadStop may not fire for BFCache restorations (iOS Safari back
        // gesture), so this ensures the URL bar stays in sync.
        if (url != null) {
          // External-scheme navs (x-safari-https://, intent://) can land a
          // history entry before the cancel takes effect. Persisting one as
          // the site's current URL makes the next launch start on a dead
          // URL that just re-fires the escape redirect.
          if (ExternalUrlParser.parse(url.toString()) != null) return;
          config.onUrlChanged?.call(url.toString());
          // SPA navigations (pushState/replaceState) don't trigger
          // onLoadStart/onLoadStop. Detect by checking if this URL had a
          // corresponding onLoadStart. If not, it's a SPA navigation —
          // re-run user scripts' source code (not the library).
          final urlStr = url.toString();
          if (urlStr != lastLoadStartUrl) {
            userScriptService.reinjectOnSpaNavigation(controller);
          }
          lastLoadStartUrl = null;
        }
      },
      onFindResultReceived: (controller, activeMatchOrdinal, numberOfMatches, isDoneCounting) {
        config.onFindResult
            ?.call(activeMatchOrdinal, totalMatches: numberOfMatches);
      },
      onConsoleMessage: (controller, consoleMessage) {
        config.onConsoleMessage
            ?.call(consoleMessage.message, level: consoleMessage.messageLevel);
      },
      onReceivedError: (controller, request, error) async {
        // An upgrade this engine issued that did not answer: load the original
        // http URL and stop upgrading that host for the rest of the process
        // (HTTPS-002). Ahead of every other recovery below, because those
        // treat the failing URL as the one the site asked for, and this one
        // is not — we substituted it.
        final upgradeFailure = WebViewFactory.httpsUpgrade.onLoadFailed(
            request.url.toString(),
            isMainFrame: request.isForMainFrame ?? true);
        if (upgradeFailure.load != null) {
          LogTag.webView.debug('https upgrade did not answer, falling back to '
              '${upgradeFailure.load}', sensitive: true);
          controller.loadUrl(urlRequest: inapp.URLRequest(
              url: inapp.WebUri(upgradeFailure.load!)));
          return;
        }
                LogTag.webViewLifecycle.warning(
                    'onReceivedError siteId=${config.posture.siteId} url=${request.url} '
                    'type=${error.type} desc=${error.description}',
                    sensitive: true);
        // For non-internal schemes (intent://, custom app schemes) Android
        // sometimes hands the URL straight to onReceivedError without
        // calling shouldOverrideUrlLoading first — observed every time on
        // Google Maps' window.location='intent://...' redirect. Without
        // routing through the dialog path here, the user never sees the
        // confirmation, suppression is never marked, and the previous
        // "reload lastStableUrl" recovery looped forever (every reload
        // re-renders the page that re-fires the same intent).
        //
        // Flow:
        //   * already suppressed → silent no-op (lets the page sit on
        //     whatever it managed to render before redirecting).
        //   * external scheme + host UI hooked up → fire the dialog
        //     callback; the helper guards against duplicate prompts and
        //     marks suppression on the user's choice.
        //   * external scheme + no host UI → best-effort reload.
        if (request.isForMainFrame != true) return;
        LogTag.webViewLifecycle.warning(
            'main-frame load error type=${error.type} ${ProxyManager.stateForLogs}');
        final reqUrl = request.url.toString();
        // iOS/macOS post-failure TLS path: `_handleServerTrust` deferred
        // to the OS and the OS rejected. Show the user prompt; on
        // approval pin the cached cert and reload.
        if (WebViewTls.isSslError(error.type)) {
          LogTag.tls.debug(
              'onReceivedError ssl: type=${error.type} url=$reqUrl description="${error.description}"',
              sensitive: true);
          final handled = await WebViewTls.handleSslLoadError(
            view: view,
            url: reqUrl,
            prompt: config.hooks.untrustedCertificate,
          );
          if (handled) return;
        }
        final externalInfo = ExternalUrlParser.parse(reqUrl);
        if (externalInfo == null) {
          // Ordinary load failure (no external scheme, TLS already handled
          // above). Report it so the host can re-issue the load on the next
          // resume when the cause was the OS cutting the network out from
          // under a backgrounded process — PAUSE-022.
          failedNavUrl = reqUrl;
          config.onMainFrameLoad?.call(MainFrameLoadSignal.failed(reqUrl,
              errorType: error.type.toValue()));
          return;
        }
        if (ExternalUrlSuppressor.isSuppressedInfo(externalInfo)) {
          if (!hostIsAndroid) {
            // WebKit reports a policy-cancelled external-scheme nav as
            // error 102 (frame load interrupted) but keeps the committed
            // page painted — loading about:blank here would wipe the page
            // the user is looking at (and clobber a silent-route load the
            // shouldOverrideUrlLoading path just issued). Only Android
            // paints chrome-error:// over the page and needs the clear.
            LogTag.webView.debug(
                'onReceivedError: suppressed — committed page intact, no-op (url=$reqUrl)',
                sensitive: true);
            return;
          }
          LogTag.webView.debug(
              'onReceivedError: suppressed — loading about:blank to clear error commit (url=$reqUrl)',
              sensitive: true);
          // The fallback page actually loaded (HtmlCache shows
          // multi-MB saves); Android then painted chrome-error://
          // chromewebdata over it because the page's JS retried the
          // intent we cancelled. about:blank clears the error visibly
          // without walking back through history (controller.goBack
          // dropped users out of the webview entirely). The
          // suppression already prevents another dialog if the page
          // tries again.
          Future.microtask(() async {
            await view?.loadUrl('about:blank');
          });
          return;
        }
        final resolved = ExternalUrlParser.toWebUrl(externalInfo);
        if (resolved != null) {
          ExternalUrlSuppressor.mark(externalInfo);
          LogTag.webView.debug(
              'onReceivedError: external scheme resolved → $resolved (from $reqUrl)',
              sensitive: true);
          Future.microtask(() async {
            final bool allow = config.shouldOverrideUrlLoading
                    ?.call(resolved, hasGesture: false) ??
                true;
            await view?.loadUrl(allow ? resolved : 'about:blank');
          });
          return;
        }
        // No web equivalent — fall through to the dialog path so the
        // user can still choose to launch the target app.
        LogTag.webView.debug('onReceivedError: type=${error.type} url=$reqUrl '
            '— routing to external-scheme dialog', sensitive: true);
        config.hooks.externalScheme(externalInfo, loadIn: view);
      },
      // Header names, never values, and no URL, so the line reaches logcat:
      // the name set tells the app's own proxy relay (`connection` alone, or
      // `proxy-authenticate`) apart from a real server.
      onReceivedHttpError: (controller, request, errorResponse) {
        if (request.isForMainFrame != true) return;
        final headerNames = [
          for (final name in errorResponse.headers?.keys ?? const <String>[])
            name.toLowerCase(),
        ]..sort();
        LogTag.webViewLifecycle.warning(
            'main-frame HTTP ${errorResponse.statusCode} '
            'headers=[${headerNames.join(',')}] ${ProxyManager.stateForLogs}');
      },
      onDownloadStartRequest: (controller, downloadStartRequest) async {
        // onUrlChanged / onUpdateVisitedHistory has likely already fired
        // with the download URL (e.g. "data:application/pdf;..."), which
        // would otherwise be persisted as the site's "current URL" and
        // tried again on next launch. Resolve the revert target BEFORE
        // awaiting the download so a nested callback can't clobber it,
        // then roll the URL bar back after stopLoading().
        final revert = DownloadUrlRevertEngine.pickRevertTarget(
          lastStableUrl: lastStableUrl,
          initialUrl: config.initialUrl,
        );
        // Abort the main-frame navigation to this URL. Without this the
        // webview tries to render the attachment response as a page and ends
        // up on a "net::ERR_UNKNOWN_URL_SCHEME" / "invalid request" error
        // page while the URL bar is stuck on the download URL.
        await view?.stopLoading();
        await WebViewDownloads.handleDownloadRequest(
          controller,
          req: downloadStartRequest,
          referer: lastStableUrl ?? config.initialUrl,
          proxy: config.posture.container.proxy,
        );
        if (revert != null) {
          config.onUrlChanged?.call(revert);
        }
      },
      onReceivedServerTrustAuthRequest: (controller, challenge) =>
          WebViewTls.handleServerTrust(view, challenge: challenge, prompt: config.hooks.untrustedCertificate),
      onReceivedHttpAuthRequest: (controller, challenge) =>
          answerHttpAuthChallenge(
            routerIdentity: routerIdentityForConfig(config),
            session: httpAuth,
            challenge: challenge,
          ),
      // Android `WebView.onRenderProcessGone`: the OS can kill the renderer
      // process while the app is backgrounded to reclaim memory. Coming back
      // to a renderer-gone WebView shows a black surface because the view is
      // alive but has no renderer driving it. Android docs require the host
      // to destroy and rebuild the WebView — we hand the event up to the
      // owning model, which clears `webview`/`controller` and triggers a
      // setState so the IndexedStack child rebuilds at the same `currentUrl`.
      // Fixes issue #333.
      onRenderProcessGone: (controller, detail) {
        LogTag.webView.warning(
            'onRenderProcessGone: siteId=${config.posture.siteId} didCrash=${detail.didCrash} '
            'priority=${detail.rendererPriorityAtExit}');
        config.onRendererGone?.call(didCrash: detail.didCrash);
      },
      // iOS/macOS parity for `onRenderProcessGone`: WKWebView raises this
      // when the web content process is killed (OS memory pressure during
      // backgrounding, or a page-induced crash). Same recovery path —
      // throw the WebView away and let the host rebuild.
      onWebContentProcessDidTerminate: (controller) {
        LogTag.webView.warning(
            'onWebContentProcessDidTerminate: siteId=${config.posture.siteId}');
        config.onRendererGone?.call(didCrash: true);
      },
    );
    final scoped = ControllerScope(
      key: config.key,
      onUnmount: () => view?.markDisposed(),
      child: webViewWidget,
    );
    return _applyLetterbox(config,
        webView: _applyRefreshGate(config, webView: scoped));
  }

  /// Feeds the raw pointer stream to [WebViewConfig.pullToRefreshGate].
  /// [Listener] never joins the gesture arena, so the webview keeps every
  /// touch it would otherwise receive.
  static Widget _applyRefreshGate(WebViewConfig config,
      {required Widget webView}) {
    final gate = config.pullToRefreshGate;
    if (gate == null) return webView;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) => gate.onPointerDown(event.pointer),
      onPointerUp: (event) => gate.onPointerUp(event.pointer),
      onPointerCancel: (event) => gate.onPointerUp(event.pointer),
      child: webView,
    );
  }

  /// Wrap [webView] in a centered, grid-snapped box with margin bars when the
  /// site has letterboxing on. The InAppWebView instance is reused across
  /// layout changes (rotation re-snaps the box without rebuilding the view),
  /// so the page is not reloaded. When letterboxing is off or the parent is
  /// unbounded, the WebView is returned unwrapped.
  ///
  /// The box is snapped against the extent the body has with the repaint nudge
  /// backed out ([SurfaceNudgeScope]); the nudge's pixel is then taken off the
  /// box rather than the bars, so the platform view still resizes and the bars
  /// hold still.
  static Widget _applyLetterbox(WebViewConfig config,
      {required Widget webView}) {
    if (!config.posture.fingerprint.letterbox) return webView;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
          return webView;
        }
        final target = computeLetterboxTarget(
          availableWidth: constraints.maxWidth,
          availableHeight: constraints.maxHeight,
          fixedWidth: config.posture.fingerprint.windowWidth,
          fixedHeight: config.posture.fingerprint.windowHeight,
          transientInsetHeight: SurfaceNudgeScope.bottomInsetOf(context),
        );
        return Container(
          color: const Color(0xFF202124),
          alignment: Alignment.center,
          child: SizedBox(
            width: target.width,
            height: target.height,
            child: webView,
          ),
        );
      },
    );
  }

}
