import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_svg/flutter_svg.dart';
import 'package:image/image.dart' as img;

import 'package:webspace/services/icon_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/settings/proxy.dart';

bool _isSvgUrl(String url) {
  final lower = url.toLowerCase();
  return lower.endsWith('.svg') || lower.contains('.svg?');
}

/// Resolve, fetch, and normalize a site's favicon to PNG bytes.
///
/// The favicon a site serves may be a PNG, an ICO (DuckDuckGo), or an SVG.
/// This always returns a valid PNG: raster sources are decoded and
/// re-encoded; SVG sources are rasterized at [size]x[size]. Returns null when
/// no icon can be resolved/fetched (e.g. proxy fail-closed) or decoding fails.
///
/// Pass [resolvedIconUrl] when the caller already knows the favicon URL (e.g.
/// from `FaviconUrlCache`) to skip a network round-trip resolving it.
/// [proxy] is the per-site proxy of the site the icon belongs to.
Future<Uint8List?> exportIconAsPng(
  String siteUrl, {
  String? resolvedIconUrl,
  UserProxySettings? proxy,
  int size = 256,
}) async {
  final iconUrl = resolvedIconUrl ?? await _resolveIconUrl(siteUrl, proxy);
  if (iconUrl == null) return null;

  try {
    if (_isSvgUrl(iconUrl)) {
      final svg = await getSvgContent(iconUrl, proxy: proxy);
      if (svg == null) return null;
      return await _rasterizeSvg(svg, size);
    }
    final bytes = await fetchIconBytes(iconUrl, proxy: proxy);
    if (bytes == null) return null;
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    return Uint8List.fromList(img.encodePng(decoded));
  } catch (e) {
    LogService.instance.log('Icon', 'PNG export failed: $e', level: LogLevel.error);
    return null;
  }
}

Future<String?> _resolveIconUrl(String siteUrl, UserProxySettings? proxy) async {
  String? best;
  await for (final update in getFaviconUrlStream(siteUrl, proxy: proxy)) {
    best = update.url;
    if (update.isFinal) break;
  }
  return best;
}

Future<Uint8List?> _rasterizeSvg(String svg, int size) async {
  final info = await vg.loadPicture(SvgStringLoader(svg), null);
  try {
    final srcW = info.size.width > 0 ? info.size.width : size.toDouble();
    final srcH = info.size.height > 0 ? info.size.height : size.toDouble();
    final scale = size / (srcW > srcH ? srcW : srcH);
    final outW = (srcW * scale).round();
    final outH = (srcH * scale).round();

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.scale(scale);
    canvas.drawPicture(info.picture);
    final scaled = recorder.endRecording();
    try {
      final image = await scaled.toImage(outW, outH);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        return data?.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    } finally {
      scaled.dispose();
    }
  } finally {
    info.picture.dispose();
  }
}
