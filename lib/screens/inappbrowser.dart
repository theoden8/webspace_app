import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp
    show PullToRefreshController, PullToRefreshSettings, SslCertificate;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/screens/dev_tools.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/surface_repaint_engine.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/settings/location.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/web_view_model.dart'
    show extractDomain, getNormalizedDomain, rendererProbeIndicatesGone;
import 'package:webspace/widgets/download_button.dart';
import 'package:webspace/widgets/external_url_prompt.dart';
import 'package:webspace/widgets/find_toolbar.dart';
import 'package:webspace/widgets/untrusted_cert_prompt.dart';
import 'package:webspace/widgets/url_bar.dart';

class InAppWebViewScreen extends StatefulWidget {
  final String url;
  final String? homeTitle;
  final String? siteId;
  final bool incognito;
  final bool thirdPartyCookiesEnabled;
  final bool clearUrlEnabled;
  final bool dnsBlockEnabled;
  final bool contentBlockEnabled;
  final bool localCdnEnabled;
  final bool trackingProtectionEnabled;
  final bool letterboxEnabled;
  final int? spoofWindowWidth;
  final int? spoofWindowHeight;
  final String? fingerprintResetNonce;
  final String? language;
  final int zoomPercent;
  final bool showUrlBar;
  final LocationMode locationMode;
  final double? spoofLatitude;
  final double? spoofLongitude;
  final double spoofAccuracy;
  final String? spoofTimezone;
  final bool spoofTimezoneFromLocation;
  final LocationGranularity liveLocationGranularity;
  final WebRtcPolicy webRtcPolicy;
  /// Pre-combined per-site + opted-in global user scripts to inject. Carried
  /// over from the parent webview so cosmetic/privacy/custom scripts keep
  /// working when the user follows an outbound link into a nested screen.
  final List<UserScriptConfig> userScripts;
  // Per-site posture that must not silently revert on the untrusted nested
  // surface: a custom/desktop UA and a JS-disabled hardening choice.
  final String? userAgent;
  final bool javascriptEnabled;
  final Future<bool> Function(String url)? onConfirmScriptFetch;
  /// Protected-content (Widevine/EME) permission popup, forwarded from the
  /// parent so a DRM site followed through an outbound link prompts the
  /// same way. The decision is remembered in-memory for this screen only
  /// (nested screens have no persisted `WebViewModel`).
  final Future<bool> Function(String origin)? onProtectedMediaRequest;
  /// Invoked when the user toggles the URL bar from this nested screen's
  /// popup menu. Threaded back to `_WebSpacePageState` so the change
  /// updates the same global preference shown in the parent menu.
  final Future<void> Function(bool show)? onShowUrlBarChanged;
  /// Per-site proxy of the parent site that opened this nested browser.
  /// Forwarded into the nested [WebViewConfig] so cross-domain links from
  /// a proxied site stay proxied. Resolves through the global outbound
  /// proxy when type is DEFAULT.
  final UserProxySettings proxySettings;
  final bool notificationsEnabled;

  /// Inherited from the site that opened this nested webview. When true, a
  /// user-tapped cross-domain link leaves WebSpace for the system browser
  /// instead of navigating in-place (NESTED-009). Cross-domain is judged
  /// against the page currently shown in this nested webview.
  final bool externalLinksInBrowser;

  InAppWebViewScreen({
    required this.url,
    this.homeTitle,
    this.siteId,
    required this.incognito,
    required this.thirdPartyCookiesEnabled,
    required this.clearUrlEnabled,
    required this.dnsBlockEnabled,
    required this.contentBlockEnabled,
    required this.localCdnEnabled,
    required this.trackingProtectionEnabled,
    this.letterboxEnabled = false,
    this.spoofWindowWidth,
    this.spoofWindowHeight,
    this.fingerprintResetNonce,
    required this.language,
    this.zoomPercent = 100,
    this.showUrlBar = false,
    this.locationMode = LocationMode.off,
    this.spoofLatitude,
    this.spoofLongitude,
    this.spoofAccuracy = 50.0,
    this.spoofTimezone,
    this.spoofTimezoneFromLocation = false,
    this.liveLocationGranularity = LocationGranularity.gps,
    this.webRtcPolicy = WebRtcPolicy.defaultPolicy,
    this.userScripts = const [],
    this.userAgent,
    this.javascriptEnabled = true,
    this.onConfirmScriptFetch,
    this.onProtectedMediaRequest,
    this.onShowUrlBarChanged,
    UserProxySettings? proxySettings,
    this.notificationsEnabled = false,
    this.externalLinksInBrowser = false,
  }) : proxySettings = proxySettings ??
            UserProxySettings(type: ProxyType.DEFAULT);

  @override
  _InAppWebViewScreenState createState() => _InAppWebViewScreenState();
}

class _InAppWebViewScreenState extends State<InAppWebViewScreen>
    with WidgetsBindingObserver {
  WebViewController? _controller;
  String? title;
  late String _currentUrl;
  late final inapp.PullToRefreshController? _pullToRefreshController;

  /// In-memory protected-content (Widevine/EME) decision for this nested
  /// screen. null = ask, true/false = remembered grant/deny. Nested screens
  /// are transient and have no persisted model, so the choice only lives
  /// for the lifetime of this screen. [_protectedMediaInFlight] coalesces a
  /// burst of `PROTECTED_MEDIA_ID` requests onto one popup.
  bool? _protectedContentAllowed;
  Future<bool>? _protectedMediaInFlight;

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
  late final Widget _webView;

  bool _isFindVisible = false;
  late bool _showUrlBar;
  FindMatchesResult findMatches = FindMatchesResult();

  /// Race guard for the PopScope handler. Async swipe gestures (iOS edge
  /// swipe) can re-enter `onPopInvokedWithResult` while the previous
  /// invocation is still awaiting `goBack()` / URL diff, which would
  /// double-pop the route or fire `goBack()` twice. Cleared in `finally`.
  bool _isBackHandling = false;

  /// Surface-repaint nudge for this nested webview (BUG-001 gap #1). A back
  /// navigation that restores a bfcached page re-attaches a blank Android
  /// SurfaceView; mirror the main page's `_goBackAndRepaint`/`_nudgeSurfaceRepaint`
  /// here so the nested screen recomposites too. Pure-Dart engine drives the
  /// 1px-inset toggle rendered below; no-op off Android.
  final SurfaceRepaintEngine _surfaceRepaint = SurfaceRepaintEngine();
  bool _repaintNudge = false;

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
    _devToolsHost = NestedDevToolsHost(
      name: widget.homeTitle ?? extractDomain(widget.url),
      siteId: widget.siteId,
      currentUrl: widget.url,
    );
    final bool isMobile = Platform.isIOS || Platform.isAndroid;
    _pullToRefreshController = isMobile ? inapp.PullToRefreshController(
      settings: inapp.PullToRefreshSettings(enabled: true),
      onRefresh: () async {
        _controller?.reload();
      },
    ) : null;
    _webView = WebViewFactory.createWebView(
      config: WebViewConfig(
        siteId: widget.siteId,
        initialUrl: widget.url,
        // BUG-002 gap #1: the OS can kill this nested webview's renderer
        // (memory reclaim while backgrounded, or a page-induced crash),
        // leaving a dead black surface. Destroy-and-rebuild on the event,
        // mirroring the main screen's handleRendererGone.
        onRendererGone: (didCrash) => _handleRendererGone(didCrash),
        incognito: widget.incognito,
        javascriptEnabled: widget.javascriptEnabled,
        userAgent: widget.userAgent,
        thirdPartyCookiesEnabled: widget.thirdPartyCookiesEnabled,
        // Mirror parent: when umbrella protection is on, force the four
        // tracker-protection subordinates effectively-on regardless of
        // their stored value.
        clearUrlEnabled: widget.clearUrlEnabled || widget.trackingProtectionEnabled,
        dnsBlockEnabled: widget.dnsBlockEnabled || widget.trackingProtectionEnabled,
        contentBlockEnabled: widget.contentBlockEnabled || widget.trackingProtectionEnabled,
        localCdnEnabled: widget.localCdnEnabled || widget.trackingProtectionEnabled,
        trackingProtectionEnabled: widget.trackingProtectionEnabled,
        letterboxEnabled: widget.letterboxEnabled,
        spoofWindowWidth: widget.spoofWindowWidth,
        spoofWindowHeight: widget.spoofWindowHeight,
        fingerprintResetNonce: widget.fingerprintResetNonce,
        language: widget.language,
        zoomPercent: widget.zoomPercent,
        // Geolocation mode is independent of the umbrella. Static
        // spoof coords still force the timezone to "From picked
        // location" so Date/Intl match the spoofed geo. With no coords
        // the umbrella leaves the timezone alone.
        locationMode: widget.locationMode,
        spoofLatitude: widget.spoofLatitude,
        spoofLongitude: widget.spoofLongitude,
        spoofAccuracy: widget.spoofAccuracy,
        spoofTimezone: (widget.trackingProtectionEnabled &&
                widget.spoofLatitude != null &&
                widget.spoofLongitude != null)
            ? null
            : widget.spoofTimezone,
        spoofTimezoneFromLocation: (widget.trackingProtectionEnabled &&
                widget.spoofLatitude != null &&
                widget.spoofLongitude != null)
            ? true
            : widget.spoofTimezoneFromLocation,
        liveLocationGranularity: widget.liveLocationGranularity,
        webRtcPolicy: widget.webRtcPolicy,
        proxySettings: widget.proxySettings,
        userScripts: widget.userScripts,
        onConfirmScriptFetch: widget.onConfirmScriptFetch,
        onProtectedMediaRequest: widget.onProtectedMediaRequest == null
            ? null
            : (origin) async {
                // ETP-023: DRM provisions a durable Widevine device
                // identifier, so the umbrella denies without prompting.
                if (widget.trackingProtectionEnabled) {
                  return false;
                }
                if (_protectedContentAllowed != null) {
                  return _protectedContentAllowed!;
                }
                _protectedMediaInFlight ??= () async {
                  final granted =
                      await widget.onProtectedMediaRequest!(origin);
                  _protectedContentAllowed = granted;
                  return granted;
                }();
                try {
                  return await _protectedMediaInFlight!;
                } finally {
                  _protectedMediaInFlight = null;
                }
              },
        notificationsEnabled: widget.notificationsEnabled,
        pullToRefreshController: _pullToRefreshController,
        onUrlChanged: (url) {
          _devToolsHost.currentUrl = url;
          if (mounted) {
            setState(() {
              _currentUrl = url;
            });
          }
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
        // NESTED-009: when the opening site routes external links to the
        // system browser, a user-tapped cross-domain link here leaves
        // WebSpace instead of navigating in-place. Same-domain navigation
        // and script-initiated (no-gesture) loads stay in this webview.
        // Null when off, so default behaviour is byte-identical.
        shouldOverrideUrlLoading: widget.externalLinksInBrowser
            ? (url, hasGesture) {
                if (!hasGesture) return true;
                final scheme = Uri.tryParse(url)?.scheme ?? '';
                if (scheme != 'http' && scheme != 'https') return true;
                if (getNormalizedDomain(url) == getNormalizedDomain(_currentUrl)) {
                  return true;
                }
                launchUrlInSystemBrowser(url);
                return false;
              }
            : null,
        onWindowRequested: _showPopupWindow,
        onUntrustedCertificate: (host, port, cert) async {
          if (!mounted) return false;
          return promptUntrustedCertificate(
            context,
            host: host,
            port: port,
            certificate: cert,
          );
        },
        onExternalSchemeUrl: (url, info) async {
          if (!mounted) return;
          await confirmAndLaunchExternalUrl(
            context,
            info,
            loadInWebView: _controller,
          );
        },
      ),
      onControllerCreated: (controller) {
        _controller = controller;
        _devToolsHost.controller = controller;
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
  void dispose() {
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

  void _toggleFind() {
    setState(() {
      _isFindVisible = !_isFindVisible;
    });
  }

  /// Recomposite the nested Android surface after a back navigation: a bfcache
  /// restore re-attaches a blank SurfaceView (BUG-001 / PAUSE-018). Mirrors
  /// `_WebSpacePageState._nudgeSurfaceRepaint`; no-op off Android.
  void _nudgeSurfaceRepaint() {
    if (!Platform.isAndroid) return;
    if (!_surfaceRepaint.request()) return;
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
    _nudgeSurfaceRepaint();
  }

  /// Destroy-and-rebuild this nested webview after its renderer process is gone
  /// (BUG-002 gap #1). Bumping `_rendererGen` remounts a fresh `InAppWebView`;
  /// the dead controller is dropped (a fresh one arrives via onControllerCreated).
  void _handleRendererGone(bool didCrash) {
    if (!mounted) return;
    LogService.instance.log(
      'WebView',
      'Nested renderer gone (siteId: ${widget.siteId}, didCrash: $didCrash) — recreating',
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
    if (state == AppLifecycleState.resumed) {
      _probeNestedRenderer();
    }
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

  /// Shows a popup window for handling window.open() requests from webviews.
  Future<void> _showPopupWindow(int windowId, String url) async {
    if (!mounted) return;
    final loc = AppLocalizations.of(context);

    LogService.instance.log(
      'PopupWindow',
      'Opening popup window with id: $windowId, url: $url',
      sensitivity: LogSensitivity.sensitive,
    );

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return Dialog(
          insetPadding: EdgeInsets.all(16),
          child: Container(
            width: MediaQuery.of(dialogContext).size.width * 0.9,
            height: MediaQuery.of(dialogContext).size.height * 0.8,
            child: Column(
              children: [
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(loc.inappBrowserVerificationTitle, style: TextStyle(fontWeight: FontWeight.bold)),
                      IconButton(
                        icon: Icon(Icons.close),
                        onPressed: () => Navigator.of(dialogContext).pop(),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: WebViewFactory.createPopupWebView(
                    windowId: windowId,
                    onCloseWindow: () {
                      if (Navigator.of(dialogContext).canPop()) {
                        Navigator.of(dialogContext).pop();
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    LogService.instance.log('PopupWindow', 'Popup window closed');
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
          if (Platform.isAndroid) {
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
                  _controller?.reload();
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
              padding: EdgeInsets.only(bottom: _repaintNudge ? 1.0 : 0.0),
              // KeyedSubtree key bumped by _handleRendererGone remounts a fresh
              // InAppWebView after a renderer death (BUG-002 gap #1).
              child: KeyedSubtree(key: ValueKey(_rendererGen), child: _webView),
            ),
          ),
          if (_showUrlBar)
            SafeArea(
              top: false,
              child: UrlBar(
                currentUrl: _currentUrl,
                onUrlSubmitted: (url) {
                  _controller?.loadUrl(url, language: widget.language);
                },
              ),
            ),
        ],
      ),
      ),
    );
  }
}
