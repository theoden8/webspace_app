import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'find_toolbar.dart';

class InAppWebViewPage extends StatefulWidget {
  final String url;

  InAppWebViewPage({required this.url});

  @override
  _InAppWebViewPageState createState() => _InAppWebViewPageState();
}

class _InAppWebViewPageState extends State<InAppWebViewPage> {
  InAppWebViewController? _controller;
  String? title;

  bool _isFindVisible = false;
  FindMatchesResult findMatches = FindMatchesResult();

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

  void removeAllCookies(InAppWebViewController controller) async {
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

    await controller.evaluateJavascript(source: script);
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
              ];
            },
            onSelected: (String value) {
              switch(value) {
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
          if(_isFindVisible && _controller != null)
            FindToolbar(
              webViewController: _controller,
              matches: findMatches,
              onClose: () {
                _toggleFind();
              },
            ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: Uri.parse(widget.url)),
              onWebViewCreated: (InAppWebViewController controller) {
                _controller = controller;
              },
              onTitleChanged: (InAppWebViewController controller, String? newTitle) {
                if (newTitle != null) {
                  updateTitle(newTitle);
                }
              },
              onLoadStop: (controller, Uri? url) async {
                if(url == null) {
                  return;
                }
                if(_controller != null) {
                  removeAllCookies(_controller!);
                }
              },
              onFindResultReceived: (controller, int activeMatchOrdinal, int numberOfMatches, bool isDoneCounting) {
                findMatches.activeMatchOrdinal = activeMatchOrdinal;
                findMatches.numberOfMatches = numberOfMatches;
              },
            ),
          ),
        ],
      ),
    );
  }
}
