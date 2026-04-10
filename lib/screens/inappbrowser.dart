import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp show PullToRefreshController, PullToRefreshSettings;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:webspace/services/webview.dart';
import 'package:webspace/widgets/find_toolbar.dart';
import 'package:webspace/widgets/url_bar.dart';

class InAppWebViewScreen extends StatefulWidget {
  final String url;
  final String? homeTitle;
  final bool incognito;
  final bool thirdPartyCookiesEnabled;
  final bool clearUrlEnabled;
  final bool dnsBlockEnabled;
  final bool contentBlockEnabled;
  final String? language;
  final bool showUrlBar;

  InAppWebViewScreen({
    required this.url,
    this.homeTitle,
    required this.incognito,
    required this.thirdPartyCookiesEnabled,
    required this.clearUrlEnabled,
    required this.dnsBlockEnabled,
    required this.contentBlockEnabled,
    required this.language,
    this.showUrlBar = false,
  });

  @override
  _InAppWebViewScreenState createState() => _InAppWebViewScreenState();
}

class _InAppWebViewScreenState extends State<InAppWebViewScreen> {
  WebViewController? _controller;
  String? title;
  late String _currentUrl;
  late final inapp.PullToRefreshController? _pullToRefreshController;

  bool _isFindVisible = false;
  FindMatchesResult findMatches = FindMatchesResult();

  @override
  void initState() {
    super.initState();
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
          Expanded(
            child: WebViewFactory.createWebView(
              config: WebViewConfig(
                initialUrl: widget.url,
                incognito: widget.incognito,
                thirdPartyCookiesEnabled: widget.thirdPartyCookiesEnabled,
                clearUrlEnabled: widget.clearUrlEnabled,
                dnsBlockEnabled: widget.dnsBlockEnabled,
                contentBlockEnabled: widget.contentBlockEnabled,
                language: widget.language,
                pullToRefreshController: _pullToRefreshController,
                onUrlChanged: (url) {
                  setState(() {
                    _currentUrl = url;
                  });
                },
                onFindResult: (activeMatch, totalMatches) {
                  setState(() {
                    findMatches.activeMatchOrdinal = activeMatch;
                    findMatches.numberOfMatches = totalMatches;
                  });
                },
                onWindowRequested: _showPopupWindow,
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
            ),
          ),
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
