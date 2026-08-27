import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:webspace/services/icon_service.dart' show getIconBytes;
import 'package:webspace/settings/proxy.dart';

/// Native favicon rendering: bytes through the app's proxy-aware outbound
/// client, then decoded from memory.
///
/// The image widget must not run its own HTTP stack here. The icon host is
/// page-chosen — any absolute `href` in the site's markup wins the discovery
/// pass — and the winner is persisted and re-rendered on every launch, so an
/// unproxied GET on this path is a per-launch beacon carrying the device IP
/// out from under whatever proxy the user configured.
Widget faviconNetworkImage({
  required String url,
  required double size,
  required WidgetBuilder placeholder,
  required WidgetBuilder error,
  UserProxySettings? proxy,
}) =>
    _FaviconBytesImage(
      url: url,
      size: size,
      placeholder: placeholder,
      error: error,
      proxy: proxy,
    );

class _FaviconBytesImage extends StatefulWidget {
  const _FaviconBytesImage({
    required this.url,
    required this.size,
    required this.placeholder,
    required this.error,
    required this.proxy,
  });

  final String url;
  final double size;
  final WidgetBuilder placeholder;
  final WidgetBuilder error;
  final UserProxySettings? proxy;

  @override
  State<_FaviconBytesImage> createState() => _FaviconBytesImageState();
}

class _FaviconBytesImageState extends State<_FaviconBytesImage> {
  Uint8List? _bytes;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_FaviconBytesImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _bytes = null;
      _loading = true;
      _load();
    }
  }

  Future<void> _load() async {
    final bytes = await getIconBytes(widget.url, proxy: widget.proxy);
    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) {
      return _loading ? widget.placeholder(context) : widget.error(context);
    }
    return Image.memory(
      bytes,
      width: widget.size,
      height: widget.size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) => widget.error(context),
    );
  }
}
