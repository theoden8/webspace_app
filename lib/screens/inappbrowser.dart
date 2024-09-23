import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:webspace/widgets/find_toolbar.dart';

class InAppWebViewScreen extends StatefulWidget {
  final String url;

  InAppWebViewScreen({required this.url});

  @override
  _InAppWebViewScreenState createState() => _InAppWebViewScreenState();
}

class _InAppWebViewScreenState extends State<InAppWebViewScreen> {
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

  Future<void> launchUrl(String url) async {
    if (await canLaunch(url)) {
      await launch(url);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not launch $url')),
      );
    }
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
              ];
            },
            onSelected: (String value) async {
              switch(value) {
                case 'openbrowser':
                  if(_controller != null) {
                    String url = (await _controller!.getUrl()).toString();
                    launchUrl(url);
                    Navigator.pop(context);
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
              initialUrlRequest: URLRequest(url: WebUri(widget.url)),
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
