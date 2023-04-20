import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class InAppWebViewPage extends StatefulWidget {
  final String url;

  InAppWebViewPage({required this.url});

  @override
  _InAppWebViewPageState createState() => _InAppWebViewPageState();
}

class _InAppWebViewPageState extends State<InAppWebViewPage> {
  late InAppWebViewController _controller;
  String? title;

  void updateTitle(String newTitle) {
    setState(() {
      title = newTitle;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title ?? 'In-app WebView')),
      body: InAppWebView(
        initialUrlRequest: URLRequest(url: Uri.parse(widget.url)),
        onWebViewCreated: (InAppWebViewController controller) {
          _controller = controller;
        },
        onTitleChanged: (InAppWebViewController controller, String? newTitle) {
          if (newTitle != null) {
            updateTitle(newTitle);
          }
        },
      ),
    );
  }
}
