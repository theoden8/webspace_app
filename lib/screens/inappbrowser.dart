import 'dart:async';
import 'package:webspace/platform/host_platform.dart';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/screens/dev_tools.dart';
import 'package:webspace/services/camera_decision_engine.dart';
import 'package:webspace/services/navigation_decision_engine.dart';
import 'package:webspace/services/microphone_decision_engine.dart';
import 'package:webspace/services/screen_share_decision_engine.dart';
import 'package:webspace/services/site_posture.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/repaint_log_throttle.dart';
import 'package:webspace/services/repaint_suppression.dart';
import 'package:webspace/services/passkey_engine.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/pull_to_refresh_gate.dart';
import 'package:webspace/services/resume_reload_engine.dart';
import 'package:webspace/services/surface_repaint_engine.dart';
import 'package:webspace/services/surface_route_observer.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/services/webview_host_hooks.dart';
import 'package:webspace/services/outbound_http_types.dart';
import 'package:webspace/settings/camera.dart';
import 'package:webspace/settings/microphone.dart';
import 'package:webspace/settings/screen_share.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/web_view_model.dart'
    show extractDomain, matchesBlockedCookie, rendererProbeIndicatesGone;
import 'package:webspace/widgets/download_button.dart';
import 'package:webspace/widgets/external_url_prompt.dart';
import 'package:webspace/widgets/find_toolbar.dart';
import 'package:webspace/widgets/tor_bootstrap.dart';
import 'package:webspace/widgets/unproxied_block.dart';
import 'package:webspace/widgets/site_info_sheet.dart';
import 'package:webspace/widgets/url_bar.dart';

/// Identifies the nested webview's slot, the counterpart of the main page's
/// per-site `ValueKey(siteId)` slot. The BUG-001 pixel suite samples the
/// composited window over this rect (integration_test/white_screen_test.dart).
const String kNestedWebViewSlotKey = 'nested-webview-slot';

class InAppWebViewScreen extends StatefulWidget {
  final String url;
  final String? homeTitle;

  /// The opening site's posture, as a nested screen starts from it
  /// ([SitePosture.forNested]). A nested screen has no persisted model, so
  /// the decisions it seeds (capture, DRM) live in this screen's memory only.
  final SitePosture posture;
  final WebViewHostHooks hooks;
  final bool showUrlBar;

  /// A link here into one of the user's sites, with Site tabs on: true when
  /// the app takes it as a tab of the site this screen was opened from, and
  /// this screen closes (LIR-032). Null for a screen a share opened.
  final bool Function(String url, bool hadGesture)? onOpenAsTab;

  /// What the site on screen was running as when this screen opened, for
  /// the site info sheet. Null for a screen a share opened.
  final String? openedFrom;
  /// Invoked when the user toggles the URL bar from this nested screen's
  /// popup menu. Threaded back to `_WebSpacePageState` so the change
  /// updates the same global preference shown in the parent menu.
  final Future<void> Function(bool show)? onShowUrlBarChanged;

  InAppWebViewScreen({
    required this.url,
    required SitePosture posture,
    required this.hooks,
    this.homeTitle,
    this.showUrlBar = false,
    this.onOpenAsTab,
    this.openedFrom,
    this.onShowUrlBarChanged,
  }) : posture = posture.forNested();

  @override
  _InAppWebViewScreenState createState() => _InAppWebViewScreenState();
}

class _InAppWebViewScreenState extends State<InAppWebViewScreen>
    with WidgetsBindingObserver, RouteAware {
  WebViewController? _controller;
  String? title;
  late String _currentUrl;
  late final PullToRefreshGate? _pullToRefreshGate;

  /// In-memory protected-content (Widevine/EME) decision for this nested
  /// screen. null = ask, true/false = remembered grant/deny. Nested screens
  /// are transient and have no persisted model, so the choice only lives
  /// for the lifetime of this screen. [_protectedMediaInFlight] coalesces a
  /// burst of `PROTECTED_MEDIA_ID` requests onto one popup.
  bool? _protectedContentAllowed;
  Future<bool>? _protectedMediaInFlight;

  /// In-memory camera-access decision for this nested screen, seeded from
  /// the opening site's posture; once the popup / file-pick settles it holds
  /// the chosen mode and, for virtual, the picked source for the life of this
  /// screen. Resolution runs through the same [CameraDecisionEngine] as the
  /// parent — only the storage differs (in-memory, no persistence).
  late CameraAccessMode _cameraMode;
  VirtualCameraSource? _cameraSource;
  final CameraDecisionEngine _cameraEngine = CameraDecisionEngine();

  /// In-memory microphone-access decision for this nested screen, same
  /// contract as the camera one above.
  late MicrophoneAccessMode _microphoneMode;
  VirtualMicrophoneSource? _microphoneSource;
  final MicrophoneDecisionEngine _microphoneEngine = MicrophoneDecisionEngine();

  /// In-memory screen-sharing decision for this nested screen, same contract
  /// as the camera one above.
  late ScreenShareMode _screenShareMode;
  VirtualScreenSource? _screenShareSource;
  final ScreenShareDecisionEngine _screenShareEngine =
      ScreenShareDecisionEngine();

  /// Cached InAppWebView widget. Built once in initState and reused on
  /// every build() so setState calls (URL bar updates, find results,
  /// FindToolbar visibility) don't reconstruct the WebView Widget.
  ///
  /// Why this matters: each WebViewFactory.createWebView call returns a
  /// fresh InAppWebView Widget. Even with key=null Flutter's element
  /// matching has been observed to recreate the underlying State on
  /// some Android System WebView builds when the parent Column's
  /// children list churns (FindToolbar appearing/disappearing). State
  /// recreation tears down the platform view and creates a new one,
  /// which triggers fresh onWebViewCreated → attachToAllWebViews. That
  /// platform-view churn, mid-page-load, has been the trigger for
  /// `partition_alloc_support.cc:770 dangling raw_ptr` SIGTRAPs on
  /// Chrome_IOThread. Stabilizing the Widget reference removes the
  /// source of churn.
  /// Null while the site's proxy is `ProxyType.TOR` and the runtime has not
  /// yet reached [TorUp]. Constructing the InAppWebView here against a null
  /// proxy binding would leave its WKWebsiteDataStore with no proxy for the
  /// life of the widget (TOR-008), so we defer construction until the SOCKS
  /// endpoint is real. The subscription in [_torStatusSub] flips this in.
  Widget? _webView;
  StreamSubscription<TorStatus>? _torStatusSub;

  bool _isFindVisible = false;
  late bool _showUrlBar;
  FindMatchesResult findMatches = FindMatchesResult();

  /// Transient load state for the AppBar progress bar, mirroring the main
  /// screen's `WebViewModel.isLoading` / `loadingProgress`.
  bool _isLoading = false;
  int _loadingProgress = 0;
  static const double _loadingBarHeight = 3.0;

  /// Race guard for the PopScope handler. Async swipe gestures (iOS edge
  /// swipe) can re-enter `onPopInvokedWithResult` while the previous
  /// invocation is still awaiting `goBack()` / URL diff, which would
  /// double-pop the route or fire `goBack()` twice. Cleared in `finally`.
  bool _isBackHandling = false;

  /// Destination this screen refused to navigate to because the app could not
  /// establish that it would go through the site's proxy (LEAK-010).
  String? _blockedNavigationUrl;

  /// Same-domain gesture timestamp feeding `NavigationDecisionEngine`'s
  /// 10s propagation window, mirroring the parent webview's closure state.
  DateTime? _lastSameDomainGestureTime;

  /// A link was handed to [InAppWebViewScreen.onOpenAsTab] and this screen is
  /// closing: nothing else loads or is handed over.
  bool _handedOffToTab = false;

  /// Surface-repaint nudge for this nested webview (BUG-001 gap #1). A back
  /// navigation that restores a bfcached page re-attaches a blank Android
  /// SurfaceView; mirror the main page's `_goBackAndRepaint`/`_nudgeSurfaceRepaint`
  /// here so the nested screen recomposites too. Pure-Dart engine drives the
  /// 1px-inset toggle rendered below; no-op off Android.
  final SurfaceRepaintEngine _surfaceRepaint = SurfaceRepaintEngine();
  bool _repaintNudge = false;
  bool _resumeRepaintWindowOpen = false;
  Timer? _resumeRepaintWindowTimer;
  // Bounds the commit latch opened by _armCommitLatch (PAUSE-027).
  Timer? _commitWindowTimer;
  // Collapses repaint-trace bursts; only ever fed while developer mode is on.
  final RepaintLogThrottle _repaintLog = RepaintLogThrottle();
  Timer? _repaintLogFlushTimer;

  /// Recovery state for a load the OS stranded while the app was backgrounded
  /// (PAUSE-022). The nested screen is as exposed as the main page: it is the
  /// visible webview when the user switches away mid-navigation.
  final ResumeReloadEngine _resumeReload = ResumeReloadEngine();
  bool _isRetryingIncompleteLoad = false;

  /// Bumped on renderer-gone recovery (BUG-002 gap #1). Wraps the webview in a
  /// `KeyedSubtree` whose changing key remounts a fresh `InAppWebView` — the
  /// nested analog of the main screen's destroy-and-rebuild. Recovery reloads
  /// at the nested entry URL (`widget.url`); in-nested navigation is lost, but
  /// that beats a permanent black screen.
  int _rendererGen = 0;

  /// DevTools host for this nested webview. Captures console output and
  /// tracks the current URL/controller so the user can open Developer
  /// Tools (Console + JS eval + HTML export + app logs) from the popup
  /// menu just like on the parent site.
  late final NestedDevToolsHost _devToolsHost;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Use home site title if provided
    title = widget.homeTitle;
    _currentUrl = widget.url;
    _showUrlBar = widget.showUrlBar;
    final media = widget.posture.media;
    _cameraMode = media.camera.mode;
    _cameraSource = media.camera.source;
    _microphoneMode = media.microphone.mode;
    _microphoneSource = media.microphone.source;
    _screenShareMode = media.screenShare.mode;
    _screenShareSource = media.screenShare.source;
    _protectedContentAllowed = media.protectedContent;
    _devToolsHost = NestedDevToolsHost(
      name: widget.homeTitle ?? extractDomain(widget.url),
      siteId: widget.posture.siteId,
      currentUrl: widget.url,
    );
    _pullToRefreshGate =
        PullToRefreshGate.forHost(onRefresh: _reloadAndRepaint);
    // Defer InAppWebView construction while Tor is not up (TOR-008). Building
    // it here binds its WKWebsiteDataStore to a null proxy for the widget's
    // lifetime, so a later Up transition would leak — the nested twin of the
    // gate in WebViewModel.getWebView.
    if (waitsForTor(
      widget.posture.container.proxy,
      siteId: widget.posture.siteId,
      torUp: TorService.instance.status.isUp,
    )) {
      _torStatusSub = TorService.instance.statusStream.listen((s) {
        if (s is TorUp && _webView == null && mounted) {
          setState(() => _webView = _createNestedInappWebView());
        }
      });
      TorService.instance.maybeStart(TorNestedHolder(widget.posture.siteId));
    } else {
      _webView = _createNestedInappWebView();
    }
  }

  /// Extracted so [initState] can defer the call under Tor. All state it
  /// closes over is either on [widget] or on `this`; no locals from
  /// `initState`.
  Widget _createNestedInappWebView() {
    final p = widget.posture;
    final blockedCookies = p.blocking.blockedCookies;
    return WebViewFactory.createWebView(
      config: WebViewConfig(
        posture: p,
        initialUrl: widget.url,
        // BUG-002 gap #1: the OS can kill this nested webview's renderer
        // (memory reclaim while backgrounded, or a page-induced crash),
        // leaving a dead black surface. Destroy-and-rebuild on the event,
        // mirroring the main screen's handleRendererGone.
        onRendererGone: (didCrash) => _handleRendererGone(didCrash),
        // Ungated, unlike the commit-settled trigger below: this fires when
        // the WebView has pixels, and the 15s commit window can close before
        // a slow renderer produces any (BUG-001 gap #18).
        onPageCommitVisible: () => _nudgeSurfaceRepaint('page-commit-visible'),
        onConfirmScriptFetch: widget.hooks.confirmScriptFetch,
        onUnproxiedNavigationBlocked: (blocked) {
          if (!mounted) return;
          setState(() => _blockedNavigationUrl = blocked);
        },
        onProtectedMediaRequest: (origin) async {
                if (_protectedContentAllowed != null) {
                  return _protectedContentAllowed!;
                }
                _protectedMediaInFlight ??= () async {
                  final granted = await widget.hooks.protectedMedia(origin);
                  _protectedContentAllowed = granted;
                  return granted;
                }();
                try {
                  return await _protectedMediaInFlight!;
                } finally {
                  _protectedMediaInFlight = null;
                }
              },
        onCameraDecision: (origin, isTopFrame) => _cameraEngine.decide(
                  origin: origin,
                  isTopFrame: isTopFrame,
                  // A nested screen is the visible webview for as long as it
                  // is mounted; a route pushed above it (including the camera
                  // popup itself) must not read as backgrounded, or a burst
                  // would stop coalescing onto that one popup.
                  isSiteActive: () => mounted,
                  effectiveMode: _cameraMode,
                  currentSource: () => _cameraSource,
                  resolve: widget.hooks.camera,
                  persist: (mode, source) {
                    _cameraMode = mode;
                    if (source != null) _cameraSource = source;
                  },
                  // Nested screens have no persisted model.
                  save: () async {},
                ),
        currentCameraMode: () => _cameraMode,
        onMicrophoneDecision: (origin, isTopFrame) => _microphoneEngine.decide(
                  origin: origin,
                  isTopFrame: isTopFrame,
                  // Mounted is the nested screen's "on screen": a route pushed
                  // above it (the popup itself included) must not read as
                  // backgrounded, or a burst would stop coalescing onto it.
                  isSiteActive: () => mounted,
                  effectiveMode: _microphoneMode,
                  currentSource: () => _microphoneSource,
                  resolve: widget.hooks.microphone,
                  persist: (mode, source) {
                    _microphoneMode = mode;
                    if (source != null) _microphoneSource = source;
                  },
                  // Nested screens have no persisted model.
                  save: () async {},
                ),
        currentMicrophoneMode: () => _microphoneMode,
        onScreenShareDecision: (origin) => _screenShareEngine.decide(
                  origin: origin,
                  // Mounted is the nested screen's "on screen": a route pushed
                  // above it (the popup itself included) must not read as
                  // backgrounded, or a burst would stop coalescing onto it.
                  isSiteActive: () => mounted,
                  effectiveMode: _screenShareMode,
                  currentSource: () => _screenShareSource,
                  resolve: widget.hooks.screenShare,
                  persist: (mode, source) {
                    _screenShareMode = mode;
                    if (source != null) _screenShareSource = source;
                  },
                  // Nested screens have no persisted model.
                  save: () async {},
                ),
        // Only wired when the opening site actually blocks cookies: an
        // always-on reader would add a jar round-trip to every load here.
        cookieManager:
            blockedCookies.isEmpty ? null : widget.hooks.cookieManager,
        containerCookieManager:
            blockedCookies.isEmpty ? null : widget.hooks.containerCookieManager,
        onCookiesChanged: blockedCookies.isEmpty
            ? null
            : (cookies) async {
                final url = Uri.parse(_currentUrl);
                for (final c in cookies) {
                  if (!matchesBlockedCookie(blockedCookies, c.name, c.domain)) {
                    continue;
                  }
                  final containerCookieManager =
                      widget.hooks.containerCookieManager;
                  if (containerCookieManager != null) {
                    await containerCookieManager.deleteCookie(
                      controller: _controller,
                      siteId: p.siteId,
                      url: url,
                      name: c.name,
                      domain: c.domain,
                      path: c.path ?? '/',
                    );
                  } else {
                    await widget.hooks.cookieManager.deleteCookie(
                      url: url,
                      name: c.name,
                      domain: c.domain,
                      path: c.path ?? '/',
                    );
                  }
                }
              },
        pullToRefreshGate: _pullToRefreshGate,
        onUrlChanged: (url) {
          _devToolsHost.currentUrl = url;
          if (mounted) {
            setState(() {
              _currentUrl = url;
            });
          }
        },
        onReloadIssued: () {
          _armCommitLatch();
          _nudgeSurfaceRepaint('reload');
        },
        onMainFrameLoad: _resumeReload.noteLoad,
        onLoadingChanged: (loading) {
          if (!mounted || _isLoading == loading) return;
          setState(() {
            _isLoading = loading;
            if (loading) _loadingProgress = 0;
          });
          // The reloaded document commits onto the surface here, which is
          // where the repaint has to land (PAUSE-021).
          if (!loading && _surfaceRepaint.noteLoadSettled()) {
            _nudgeSurfaceRepaint('commit-settled');
          }
        },
        onProgressChanged: (progress) {
          if (!mounted || _loadingProgress == progress) return;
          setState(() {
            _loadingProgress = progress;
          });
        },
        onConsoleMessage: (message, level) {
          _devToolsHost.appendConsole(message, level);
        },
        onFindResult: (activeMatch, totalMatches) {
          if (mounted) {
            setState(() {
              findMatches.activeMatchOrdinal = activeMatch;
              findMatches.numberOfMatches = totalMatches;
            });
          }
        },
        // Same decision engine as the parent webview, judged against the
        // page shown here (NESTED-009 for the external-link mode, NESTED-004
        // for gesture-less hops). A nested screen has nowhere further to
        // nest, so `blockOpenNested` navigates in place, unless the link is
        // one of the user's sites and goes back as a tab (LIR-032).
        shouldOverrideUrlLoading: (url, hasGesture) {
          final result = NavigationDecisionEngine
              .decideShouldOverrideUrlLoading(
            targetUrl: url,
            initUrl: _currentUrl,
            hasGesture: hasGesture,
            isSiteActive: mounted,
            lastSameDomainGestureTime: _lastSameDomainGestureTime,
            now: DateTime.now(),
            externalLinkMode: p.page.externalLinks,
          );
          _lastSameDomainGestureTime = result.gestureUpdate
              .applyTo(_lastSameDomainGestureTime, DateTime.now());
          if (_handedOffToTab) return false;
          switch (result.decision) {
            case NavigationDecision.allow:
              return true;
            case NavigationDecision.blockOpenNested:
              if (mounted &&
                  (widget.onOpenAsTab?.call(url, result.hadGesture) ?? false)) {
                _handedOffToTab = true;
                Navigator.of(context).pop();
                return false;
              }
              return true;
            case NavigationDecision.blockSilent:
            case NavigationDecision.blockSuppressed:
              return false;
            case NavigationDecision.blockOpenExternal:
              launchUrlInSystemBrowser(url);
              return false;
            case NavigationDecision.blockOutbound:
              if (result.hadGesture) showExternalLinkBlocked(url);
              return false;
          }
        },
        onWindowRequested: widget.hooks.showPopup,
        onUntrustedCertificate: widget.hooks.untrustedCertificate,
        onHttpAuthRequest: widget.hooks.httpAuth,
        passkeys: PasskeyAccess.forHost(
          enabled: p.container.passkeys,
          isOnScreen: () =>
              mounted && (ModalRoute.of(context)?.isCurrent ?? false),
        ),
        onExternalSchemeUrl: (url, info) =>
            widget.hooks.externalScheme(info, _controller),
      ),
      onControllerCreated: (controller) {
        _controller = controller;
        _devToolsHost.controller = controller;
        // This screen always mounts a brand-new hybrid-composition
        // SurfaceView, which shows its white default fill until something
        // paints it — the main page's PAUSE-017 case, which the nested screen
        // never had. Latch the first commit too: the entry URL is remote, so
        // it routinely settles after this nudge drains (PAUSE-025).
        _armCommitLatch();
        _nudgeSurfaceRepaint('controller-attach');
        // Remove all cookies on load
        controller.evaluateJavascript('''
          (function() {
            var cookies = document.cookie.split("; ");
            for (var i = 0; i < cookies.length; i++) {
              var cookie = cookies[i];
              var cookieName = cookie.split("=")[0];
              document.cookie = cookieName + "=; expires=Thu, 01 Jan 1970 00:00:00 UTC; path=/;";
            }
          })();
        ''');
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) surfaceRouteObserver.subscribe(this, route);
  }

  /// An opaque route pushed over this screen (Developer Tools, site settings,
  /// a further nested webview) has popped. The platform view was not
  /// composited while it was covered, so it re-attaches blank here — the
  /// nested counterpart of the main page's route return (PAUSE-024).
  @override
  void didPopNext() {
    _nudgeSurfaceRepaint('route-return');
  }

  @override
  void dispose() {
    _resumeRepaintWindowTimer?.cancel();
    _commitWindowTimer?.cancel();
    _repaintLogFlushTimer?.cancel();
    _torStatusSub?.cancel();
    if (widget.posture.container.proxy.type == ProxyType.TOR) {
      TorService.instance.release(TorNestedHolder(widget.posture.siteId));
    }
    surfaceRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeTextScaleFactor() {
    _controller?.setTextZoom(WebViewFactory.systemTextZoomPercent());
  }

  void updateTitle(String newTitle) {
    setState(() {
      title = newTitle;
    });
  }

  /// This screen runs as the site that opened it, or as the one outbound
  /// routing picked (LIR-015); the sheet says which, and which container it
  /// binds, by the rule the factory bound it with.
  void _showSiteInfo() {
    final p = widget.posture;
    showSiteInfoSheet(
      context,
      SiteInfo(
        siteName: widget.homeTitle ?? extractDomain(widget.url),
        openedFrom: widget.openedFrom,
        pageUrl: _currentUrl,
        containerId: containerIdFor(
          siteId: p.siteId,
          archiveContainerId: p.container.archiveContainerId,
          incognito: p.container.incognito,
        ),
        incognito: p.container.incognito,
        proxy: PlatformInfo.isProxySupported ? p.container.proxy : null,
        siteId: p.siteId,
      ),
    );
  }

  void _toggleFind() {
    setState(() {
      _isFindVisible = !_isFindVisible;
    });
  }

  /// Recomposite the nested Android surface after a back navigation: a bfcache
  /// restore re-attaches a blank SurfaceView (BUG-001 / PAUSE-018). Mirrors
  /// `_WebSpacePageState._nudgeSurfaceRepaint`; no-op off Android.
  void _nudgeSurfaceRepaint(String trigger) {
    if (!hostIsAndroid) return;
    // Debug-only, diag tiers only: drop this trigger so a scenario can observe
    // what the native layer repaints on its own (BUG-001 gap #5).
    if (RepaintSuppression.suppresses(trigger)) {
      _traceRepaint('$trigger-suppressed', coalesced: false);
      return;
    }
    final started = _surfaceRepaint.request();
    _traceRepaint(trigger, coalesced: !started);
    if (!started) return;
    void tick() {
      if (!mounted) {
        _surfaceRepaint.abort();
        return;
      }
      final t = _surfaceRepaint.tick();
      setState(() => _repaintNudge = t.inset);
      if (t.done) return;
      Future.delayed(const Duration(milliseconds: 100), tick);
    }

    tick();
  }

  Future<void> _goBackAndRepaint(WebViewController controller) async {
    await controller.goBack();
    _nudgeSurfaceRepaint('back');
  }

  /// Nested counterpart of `_WebSpacePageState._traceRepaint`: same funnel,
  /// same developer-mode gate and burst collapsing. `-nested` distinguishes
  /// this screen's surface from the main page's in a shared trace — the two
  /// have separate SurfaceViews and separate repaint machinery.
  void _traceRepaint(String trigger, {required bool coalesced}) {
    if (!DeveloperModeService.instance.enabled) return;
    for (final line in _repaintLog
        .note('$trigger-nested', coalesced: coalesced, now: DateTime.now())) {
      LogService.instance.log('SurfaceDiag', line);
    }
    _repaintLogFlushTimer?.cancel();
    if (!_repaintLog.hasPending) return;
    _repaintLogFlushTimer = Timer(RepaintLogThrottle.burstWindow, () {
      _repaintLogFlushTimer = null;
      final summary = _repaintLog.flush();
      if (summary != null) LogService.instance.log('SurfaceDiag', summary);
    });
  }

  /// Nested counterpart of `_WebSpacePageState._armCommitLatch` (PAUSE-027):
  /// arm the commit latch and hold it open for a bounded window, so every
  /// load settling inside it repaints — not just the first, whose document a
  /// second refresh or a redirect chain has already replaced.
  void _armCommitLatch() {
    _surfaceRepaint.noteCommitPending();
    _commitWindowTimer?.cancel();
    _commitWindowTimer = Timer(SurfaceRepaintEngine.commitWindow, () {
      _commitWindowTimer = null;
      _surfaceRepaint.closeCommitWindow();
    });
  }

  /// User asked for a repaint from the menu (PAUSE-028). Nested counterpart of
  /// `_WebSpacePageState._repaintCurrentSurface`, without the renderer probe:
  /// this screen recreates nothing, so a dead renderer here is the user's cue
  /// to leave and re-open the link.
  void _repaintCurrentSurface() => _nudgeSurfaceRepaint('manual');

  /// Reload funnel for the nested webview, mirroring
  /// `WebViewModel.reloadAndRepaint`. A reload drops the painted frame and
  /// recommits it later, leaving the Android surface blank in between with no
  /// relayout to clear it (BUG-001 / PAUSE-021). Nudge now for a fast
  /// recommit; the latch makes the settled load nudge again for a slow one.
  Future<void> _reloadAndRepaint() async {
    final controller = _controller;
    if (controller == null) return;
    _armCommitLatch();
    _nudgeSurfaceRepaint('reload');
    await controller.reload();
  }

  /// Nested counterpart of `_WebSpacePageState._retryIncompleteLoadOnResume`
  /// (PAUSE-022): re-issue a load the OS stranded while the app was in the
  /// background. Loads the URL explicitly rather than reloading — the webview
  /// may be sitting on an error page or on the previous document — and reports
  /// through the same repaint latch as a real reload.
  Future<void> _retryIncompleteLoadOnResume() async {
    if (_isRetryingIncompleteLoad) return;
    _isRetryingIncompleteLoad = true;
    try {
      for (var i = 0; i < ResumeReloadEngine.maxAttempts; i++) {
        var plan = _resumeReload.planRetry();
        if (plan.action == ResumeRetryAction.waitAndReplan) {
          await Future.delayed(plan.delay);
          if (!mounted || _controller == null) return;
          _resumeReload.noteStallGraceElapsed();
          plan = _resumeReload.planRetry();
        }
        if (plan.action != ResumeRetryAction.retryNow) return;
        if (!await ConnectivityService.instance.isOnline()) return;
        final controller = _controller;
        if (!mounted || controller == null) return;
        _resumeReload.noteRetryIssued();
        _armCommitLatch();
        _nudgeSurfaceRepaint('resume-reissue');
        try {
          await controller.loadUrl(plan.url!, language: widget.posture.page.language);
        } catch (_) {
          // Controller may have been disposed while the retry was in flight.
        }
        await Future.delayed(ResumeReloadEngine.retryBackoff);
        if (!mounted || _controller == null) return;
      }
    } finally {
      _isRetryingIncompleteLoad = false;
    }
  }

  /// Destroy-and-rebuild this nested webview after its renderer process is gone
  /// (BUG-002 gap #1). Bumping `_rendererGen` remounts a fresh `InAppWebView`;
  /// the dead controller is dropped (a fresh one arrives via onControllerCreated).
  void _handleRendererGone(bool didCrash) {
    if (!mounted) return;
    LogService.instance.log(
      'WebView',
      'Nested renderer gone (siteId: ${widget.posture.siteId}, didCrash: $didCrash) — recreating',
      level: LogLevel.warning,
    );
    setState(() {
      _controller = null;
      _rendererGen++;
    });
  }

  /// Proactive probe (PAUSE-014) for the nested screen: the renderer can be
  /// killed while offscreen without firing the termination event, so on resume
  /// read `offsetHeight` and recreate if the process is gone.
  Future<void> _probeNestedRenderer() async {
    final controller = _controller;
    if (controller == null) return;
    final result = await controller
        .evaluateJavascriptReturning('document.body ? document.body.offsetHeight : -1');
    if (!mounted) return;
    if (rendererProbeIndicatesGone(result) && identical(_controller, controller)) {
      _handleRendererGone(false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _resumeReload.noteAppBackgrounded();
    } else if (state == AppLifecycleState.resumed) {
      _probeNestedRenderer();
      // A warm start destroys and re-creates this screen's SurfaceView exactly
      // as it does the main page's, and the main page's nudge cannot reach it:
      // that one toggles the inset around an IndexedStack sitting under this
      // route. Same two-part fix as PAUSE-020 — a tail nudge now, plus a
      // re-nudge on the attach signal for a surface that comes back later.
      _openResumeRepaintWindow();
      _nudgeSurfaceRepaint('resume');
      unawaited(_retryIncompleteLoadOnResume());
    }
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (!_resumeRepaintWindowOpen) return;
    _nudgeSurfaceRepaint('metrics-resume');
  }

  /// Post-resume window during which a `didChangeMetrics` — the closest
  /// Dart-side signal to the SurfaceView re-attaching — re-fires the nudge.
  /// Bounded so steady-state metric changes (keyboard, rotation) don't nudge.
  /// Mirrors `_WebSpacePageState._openResumeRepaintWindow` (PAUSE-020).
  void _openResumeRepaintWindow() {
    if (!hostIsAndroid) return;
    _resumeRepaintWindowOpen = true;
    _resumeRepaintWindowTimer?.cancel();
    _resumeRepaintWindowTimer = Timer(const Duration(seconds: 3), () {
      _resumeRepaintWindowOpen = false;
      _resumeRepaintWindowTimer = null;
    });
  }

  Future<void> launchExternalUrl(String url) async {
    final loc = AppLocalizations.of(context);
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(loc.inappBrowserCouldNotLaunch(url))),
        );
      }
    }
  }

  void removeAllCookies(WebViewController controller) async {
    String script = '''
      (function() {
        var cookies = document.cookie.split("; ");
        for (var i = 0; i < cookies.length; i++) {
          var cookie = cookies[i];
          var domain = cookie.match(/domain=[^;]+/);
          if (domain) {
            var domainValue = domain[0].split("=")[1];
            var cookieName = cookie.split("=")[0];
            document.cookie = cookieName + "=; expires=Thu, 01 Jan 1970 00:00:00 UTC; path=/; domain=" + domainValue;
          }
        }
      })();
    ''';

    await controller.evaluateJavascript(script);
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return PopScope(
      // Always intercept so we can try goBack() in the nested webview's own
      // history before letting the route pop. Mirrors NAV-002 (main app):
      // Android trusts canGoBack() directly (Chromium reports pushState
      // correctly, and URL-diff false-positives on slow back navigations).
      // iOS/macOS attempt goBack() unconditionally and decide via URL
      // comparison since WKWebView's canGoBack() lies for pushState SPAs.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || _isBackHandling) return;
        _isBackHandling = true;
        // Capture navigator before any awaits so we don't touch BuildContext
        // across async gaps after the route may have been disposed.
        final navigator = Navigator.of(context);
        try {
          final controller = _controller;
          if (controller == null) {
            if (mounted) navigator.pop();
            return;
          }
          if (hostIsAndroid) {
            if (await controller.canGoBack()) {
              await _goBackAndRepaint(controller);
              LogService.instance.log('Navigation',
                  'Nested back gesture: navigated back (canGoBack)');
            } else {
              if (!mounted) return;
              LogService.instance.log('Navigation',
                  'Nested back gesture: no history, exiting nested');
              navigator.pop();
            }
            return;
          }
          final urlBefore = (await controller.getUrl())?.toString();
          await controller.goBack();
          await Future.delayed(const Duration(milliseconds: 150));
          if (!mounted) return;
          final urlAfter = (await controller.getUrl())?.toString();
          if (!mounted) return;
          if (urlBefore == urlAfter) {
            LogService.instance.log(
              'Navigation',
              'Nested back gesture: no history ($urlAfter), exiting nested',
              sensitivity: LogSensitivity.sensitive,
            );
            navigator.pop();
          } else {
            LogService.instance.log(
              'Navigation',
              'Nested back gesture: navigated $urlBefore -> $urlAfter',
              sensitivity: LogSensitivity.sensitive,
            );
          }
        } finally {
          _isBackHandling = false;
        }
      },
      child: Scaffold(
      appBar: AppBar(
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(_loadingBarHeight),
          child: _isLoading
              ? LinearProgressIndicator(
                  value: _loadingProgress > 0 ? _loadingProgress / 100 : null,
                  minHeight: _loadingBarHeight,
                  backgroundColor: Colors.transparent,
                )
              : const SizedBox(height: _loadingBarHeight),
        ),
        // Custom back button that bypasses PopScope by calling
        // Navigator.pop directly (vs maybePop), so the AppBar back
        // arrow always closes the nested screen. Only the system back
        // gesture (iOS edge swipe / Android back) routes through
        // PopScope and walks the nested webview's history first.
        leading: IconButton(
          icon: const BackButtonIcon(),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(title ?? loc.inappBrowserDefaultTitle),
        actions: [
          const DownloadButton(),
          PopupMenuButton<String>(
            itemBuilder: (BuildContext context) {
              return [
                PopupMenuItem<String>(
                  value: "openbrowser",
                  child: Row(
                    children: [
                      Icon(Icons.link),
                      SizedBox(width: 8),
                      Text(loc.inappBrowserMenuOpenInBrowser),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: "refresh",
                  child: Row(
                    children: [
                      Icon(Icons.refresh),
                      SizedBox(width: 8),
                      Text(loc.inappBrowserMenuRefresh),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: "search",
                  child: Row(
                    children: [
                      Icon(Icons.search),
                      SizedBox(width: 8),
                      Text(loc.inappBrowserMenuFind),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: "share",
                  child: Row(
                    children: [
                      Icon(Icons.share),
                      SizedBox(width: 8),
                      Text(loc.commonShare),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: "toggleUrlBar",
                  child: Row(
                    children: [
                      Icon(_showUrlBar ? Icons.visibility_off : Icons.visibility),
                      SizedBox(width: 8),
                      Text(_showUrlBar ? loc.inappBrowserMenuHideUrlBar : loc.inappBrowserMenuShowUrlBar),
                    ],
                  ),
                ),
                // Manual escape hatch for the recurring Android blank
                // surface (BUG-001 / PAUSE-028). Android-only, where the
                // nudge is not a no-op, and behind developer mode: it is a
                // diagnostic, not something to meet by accident.
                if (hostIsAndroid && DeveloperModeService.instance.enabled)
                  PopupMenuItem<String>(
                    value: "repaint",
                    child: Row(
                      children: [
                        Icon(Icons.format_paint),
                        SizedBox(width: 8),
                        Text(loc.commonRepaintScreen),
                      ],
                    ),
                  ),
                PopupMenuItem<String>(
                  value: "devTools",
                  child: Row(
                    children: [
                      Icon(Icons.developer_mode),
                      SizedBox(width: 8),
                      Text(loc.inappBrowserMenuDeveloperTools),
                    ],
                  ),
                ),
              ];
            },
            onSelected: (String value) async {
              switch (value) {
                case 'repaint':
                  _repaintCurrentSurface();
                  break;
                case 'share':
                  if (_controller != null) {
                    final url = await _controller!.getUrl();
                    if (url != null) {
                      SharePlus.instance.share(ShareParams(uri: Uri.parse(url.toString())));
                    }
                  }
                  break;
                case 'openbrowser':
                  if (_controller != null) {
                    final url = await _controller!.getUrl();
                    if (url != null) {
                      launchExternalUrl(url.toString());
                      if (mounted) {
                        Navigator.pop(context);
                      }
                    }
                  }
                  break;
                case 'search':
                  _toggleFind();
                  break;
                case 'toggleUrlBar':
                  setState(() {
                    _showUrlBar = !_showUrlBar;
                  });
                  await widget.onShowUrlBarChanged?.call(_showUrlBar);
                  break;
                case 'refresh':
                  await _reloadAndRepaint();
                  break;
                case 'devTools':
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => DevToolsScreen(
                        host: _devToolsHost,
                        cookieManager: CookieManager(),
                      ),
                    ),
                  );
                  break;
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (_isFindVisible && _controller != null)
            FindToolbar(
              webViewController: _controller,
              matches: findMatches,
              onClose: () {
                _toggleFind();
              },
            ),
          // 1px inset toggled by _nudgeSurfaceRepaint forces the nested
          // hybrid-composition SurfaceView to recomposite after a back
          // navigation (BUG-001 gap #1). Zero inset in steady state.
          Expanded(
            child: Padding(
              key: const ValueKey(kNestedWebViewSlotKey),
              padding: EdgeInsets.only(bottom: _repaintNudge ? 1.0 : 0.0),
              // KeyedSubtree key bumped by _handleRendererGone remounts a fresh
              // InAppWebView after a renderer death (BUG-002 gap #1).
              child: KeyedSubtree(
                key: ValueKey(_rendererGen),
                // Always the same Stack, for the reason the root surface
                // gives: swapping the child at this slot would unmount the
                // platform view under the interstitial (LEAK-010).
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _webView ?? const TorBootstrapPlaceholder(),
                    if (_blockedNavigationUrl != null)
                      Positioned.fill(
                        child: UnproxiedNavigationBlock(
                          siteName:
                              widget.homeTitle ?? extractDomain(_currentUrl),
                          blockedUrl: _blockedNavigationUrl!,
                          onGoBack: () =>
                              setState(() => _blockedNavigationUrl = null),
                          onOpenProxySettings: () => widget.hooks
                              .openSiteSettings(widget.posture.siteId),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (_showUrlBar)
            SafeArea(
              top: false,
              child: UrlBar(
                currentUrl: _currentUrl,
                onSiteInfo: _showSiteInfo,
                onUrlSubmitted: (url) {
                  _controller?.loadUrl(url, language: widget.posture.page.language);
                },
              ),
            ),
        ],
      ),
      ),
    );
  }
}
