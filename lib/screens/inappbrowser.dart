import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp
    show PullToRefreshController, PullToRefreshSettings, SslCertificate;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:webspace/screens/dev_tools.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/settings/location.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/web_view_model.dart' show extractDomain;
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
  final String? language;
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
  final Future<bool> Function(String url)? onConfirmScriptFetch;
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
    required this.language,
    this.showUrlBar = false,
    this.locationMode = LocationMode.off,
    this.spoofLatitude,
    this.spoofLongitude,
    this.spoofAccuracy = 50.0,
    this.spoofTimezone,
    this.spoofTimezoneFromLocation = false,
    this.liveLocationGranularity = LocationGranularity.fine,
    this.webRtcPolicy = WebRtcPolicy.defaultPolicy,
    this.userScripts = const [],
    this.onConfirmScriptFetch,
    this.onShowUrlBarChanged,
    UserProxySettings? proxySettings,
    this.notificationsEnabled = false,
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
        incognito: widget.incognito,
        thirdPartyCookiesEnabled: widget.thirdPartyCookiesEnabled,
        // Mirror parent: when umbrella protection is on, force the four
        // tracker-protection subordinates effectively-on regardless of
        // their stored value.
        clearUrlEnabled: widget.clearUrlEnabled || widget.trackingProtectionEnabled,
        dnsBlockEnabled: widget.dnsBlockEnabled || widget.trackingProtectionEnabled,
        contentBlockEnabled: widget.contentBlockEnabled || widget.trackingProtectionEnabled,
        localCdnEnabled: widget.localCdnEnabled || widget.trackingProtectionEnabled,
        trackingProtectionEnabled: widget.trackingProtectionEnabled,
        language: widget.language,
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

  Future<void> launchExternalUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not launch $url')),
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

    if (kDebugMode) {
      debugPrint('[PopupWindow] Opening popup window with id: $windowId, url: $url');
    }

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
                      Text('Verification', style: TextStyle(fontWeight: FontWeight.bold)),
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

    if (kDebugMode) {
      debugPrint('[PopupWindow] Popup window closed');
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Always intercept so we can try goBack() in the nested webview's own
      // history before letting the route pop. Mirrors NAV-002 (main app):
      // canGoBack() is unreliable for pushState SPAs, so we always attempt
      // goBack() and decide via URL comparison.
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
          final urlBefore = (await controller.getUrl())?.toString();
          await controller.goBack();
          await Future.delayed(const Duration(milliseconds: 150));
          if (!mounted) return;
          final urlAfter = (await controller.getUrl())?.toString();
          if (!mounted) return;
          if (urlBefore == urlAfter) {
            LogService.instance.log('Navigation',
                'Nested back gesture: no history ($urlAfter), exiting nested');
            navigator.pop();
          } else {
            LogService.instance.log('Navigation',
                'Nested back gesture: navigated $urlBefore -> $urlAfter');
          }
        } finally {
          _isBackHandling = false;
        }
      },
      child: Scaffold(
      appBar: AppBar(
        title: Text(title ?? 'In-App WebView'),
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
                      Text("Open in Browser"),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: "refresh",
                  child: Row(
                    children: [
                      Icon(Icons.refresh),
                      SizedBox(width: 8),
                      Text("Refresh"),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: "search",
                  child: Row(
                    children: [
                      Icon(Icons.search),
                      SizedBox(width: 8),
                      Text("Find"),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: "share",
                  child: Row(
                    children: [
                      Icon(Icons.share),
                      SizedBox(width: 8),
                      Text("Share"),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: "toggleUrlBar",
                  child: Row(
                    children: [
                      Icon(_showUrlBar ? Icons.visibility_off : Icons.visibility),
                      SizedBox(width: 8),
                      Text(_showUrlBar ? "Hide URL Bar" : "Show URL Bar"),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: "devTools",
                  child: Row(
                    children: [
                      Icon(Icons.developer_mode),
                      SizedBox(width: 8),
                      Text("Developer Tools"),
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
          Expanded(child: _webView),
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
