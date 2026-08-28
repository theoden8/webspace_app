import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import 'package:webspace/settings/proxy.dart';

/// Web favicon rendering, via a real `<img>` element.
///
/// The obvious route — fetching the bytes, as CachedNetworkImage does — is
/// subject to CORS, and the public favicon endpoints (DuckDuckGo, Google)
/// send no `Access-Control-Allow-Origin`, so a browser refuses to hand the
/// response to the page. An `<img>` may *display* a cross-origin image even
/// when script may not read it, which is the whole difference here.
/// [proxy] is ignored: the browser owns the connection an `<img>` makes, and
/// the app's Dart-side proxy seam cannot reach it.
Widget faviconNetworkImage({
  required String url,
  required double size,
  required WidgetBuilder placeholder,
  required WidgetBuilder error,
  UserProxySettings? proxy,
}) =>
    _ImgElementView(url: url, size: size);

class _ImgElementView extends StatefulWidget {
  const _ImgElementView({required this.url, required this.size});

  final String url;
  final double size;

  @override
  State<_ImgElementView> createState() => _ImgElementViewState();
}

class _ImgElementViewState extends State<_ImgElementView> {
  static final Set<String> _registered = {};

  late String _viewType = _register(widget.url);

  String _register(String url) {
    final type = 'ws-favicon-${url.hashCode}';
    if (_registered.add(type)) {
      ui_web.platformViewRegistry.registerViewFactory(type, (int _) {
        final img = web.document.createElement('img') as web.HTMLImageElement
          ..src = url
          ..referrerPolicy = 'no-referrer'
          ..style.width = '100%'
          ..style.height = '100%'
          ..style.objectFit = 'contain';
        return img;
      });
    }
    return type;
  }

  @override
  void didUpdateWidget(_ImgElementView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      setState(() => _viewType = _register(widget.url));
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: widget.size,
        height: widget.size,
        child: HtmlElementView(viewType: _viewType),
      );
}
