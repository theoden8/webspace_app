import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp show PullToRefreshController, PullToRefreshSettings;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:webspace/services/webview.dart';
import 'package:webspace/settings/location.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/widgets/download_button.dart';
import 'package:webspace/widgets/external_url_prompt.dart';
import 'package:webspace/widgets/find_toolbar.dart';
import 'package:webspace/widgets/ios_universal_link_prompt.dart';
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
  final String? language;
  final bool showUrlBar;
  final LocationMode locationMode;
  final double? spoofLatitude;
  final double? spoofLongitude;
  final double spoofAccuracy;
  final String? spoofTimezone;
  final bool spoofTimezoneFromLocation;
  final WebRtcPolicy webRtcPolicy;
  /// Pre-combined per-site + opted-in global user scripts to inject. Carried
  /// over from the parent webview so cosmetic/privacy/custom scripts keep
  /// working when the user follows an outbound link into a nested screen.
  final List<UserScriptConfig> userScripts;
  final Future<bool> Function(String url)? onConfirmScriptFetch;

  InAppWebViewScreen({
    required this.url,
    this.homeTitle,
    this.siteId,
    required this.incognito,
    required this.thirdPartyCookiesEnabled,
    required this.clearUrlEnabled,
    required this.dnsBlockEnabled,
    required this.contentBlockEnabled,
    required this.language,
    this.showUrlBar = false,
    this.locationMode = LocationMode.off,
    this.spoofLatitude,
    this.spoofLongitude,
    this.spoofAccuracy = 50.0,
    this.spoofTimezone,
    this.spoofTimezoneFromLocation = false,
    this.webRtcPolicy = WebRtcPolicy.defaultPolicy,
    this.userScripts = const [],
    this.onConfirmScriptFetch,
  });

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
  FindMatchesResult findMatches = FindMatchesResult();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Use home site title if provided
    title = widget.homeTitle;
    _currentUrl = widget.url;
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
        clearUrlEnabled: widget.clearUrlEnabled,
        dnsBlockEnabled: widget.dnsBlockEnabled,
        contentBlockEnabled: widget.contentBlockEnabled,
        language: widget.language,
        locationMode: widget.locationMode,
        spoofLatitude: widget.spoofLatitude,
        spoofLongitude: widget.spoofLongitude,
        spoofAccuracy: widget.spoofAccuracy,
        spoofTimezone: widget.spoofTimezone,
        spoofTimezoneFromLocation: widget.spoofTimezoneFromLocation,
        webRtcPolicy: widget.webRtcPolicy,
        userScripts: widget.userScripts,
        onConfirmScriptFetch: widget.onConfirmScriptFetch,
        pullToRefreshController: _pullToRefreshController,
        onUrlChanged: (url) {
          if (mounted) {
            setState(() {
              _currentUrl = url;
            });
          }
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
        onExternalSchemeUrl: (url, info) async {
          if (!mounted) return;
          await confirmAndLaunchExternalUrl(context, info);
        },
        onIosUniversalLinkUrl: (url, continueHere) {
          if (!mounted) return;
          confirmIosUniversalLinkUrl(context, url, continueHere: continueHere);
        },
      ),
      onControllerCreated: (controller) {
        _controller = controller;
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
    return Scaffold(
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
                case 'refresh':
                  _controller?.reload();
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
          if (widget.showUrlBar)
            UrlBar(
              currentUrl: _currentUrl,
              onUrlSubmitted: (url) {
                _controller?.loadUrl(url, language: widget.language);
              },
            ),
        ],
      ),
    );
  }
}
