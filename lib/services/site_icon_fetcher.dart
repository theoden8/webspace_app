import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/site_icon_engine.dart';

/// Whether this platform's webview reports no page icon of its own, so the
/// app would fetch the declared links instead (ICON-013). Android's does.
bool get siteIconFetchRunsHere => hostIsIOS || hostIsMacOS || hostIsLinux;

/// Largest source image edge decoded. Most formats decode at full size before
/// scaling, so this bounds what one icon can cost in memory.
const int kMaxSiteIconDecodeEdge = 1024;

/// Decoded icons one site webview keeps, so each page of a site does not
/// refetch the same links.
const int _maxCachedIcons = 24;

/// Decode [bytes] to a PNG no larger than [kMaxSiteIconEdge], or null when
/// the image is not one Flutter decodes, is under [kMinSiteIconEdge], or is
/// over [kMaxSiteIconDecodeEdge].
Future<SiteIcon?> decodeSiteIcon(Uint8List bytes) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final width = descriptor.width;
    final height = descriptor.height;
    if (math.min(width, height) < kMinSiteIconEdge ||
        math.max(width, height) > kMaxSiteIconDecodeEdge) {
      return null;
    }
    final scale = math.min(1.0, kMaxSiteIconEdge / math.max(width, height));
    codec = await descriptor.instantiateCodec(
      targetWidth: math.max(1, (width * scale).round()),
      targetHeight: math.max(1, (height * scale).round()),
    );
    image = (await codec.getNextFrame()).image;
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) return null;
    return SiteIcon(
      png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      image.width,
      image.height,
    );
  } catch (_) {
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// Fetches the icon links a site's page declared and picks the one to offer
/// (ICON-013), for webviews that report no icon of their own. One per site
/// webview.
class SiteIconFetcher {
  SiteIconFetcher({required this.fetch});

  /// GET an http(s) icon link declared by the document at the given URL, or
  /// null.
  final Future<Uint8List?> Function(String url, String documentUrl) fetch;

  final LinkedHashMap<String, Future<SiteIcon?>> _icons = LinkedHashMap();

  /// The largest icon among [urls] declared by the document at
  /// [documentUrl], or null when none decodes to a usable icon.
  Future<SiteIcon?> best(List<String> urls, String documentUrl) async {
    final icons = await Future.wait(
        [for (final url in urls) _icon(url, documentUrl)]);
    SiteIcon? best;
    for (final icon in icons) {
      if (icon != null && (best == null || icon.edge > best.edge)) best = icon;
    }
    return best;
  }

  Future<SiteIcon?> _icon(String url, String documentUrl) {
    final known = _icons.remove(url);
    if (known != null) return _icons[url] = known;
    late final Future<SiteIcon?> loading;
    loading = _load(url, documentUrl, forget: () {
      if (identical(_icons[url], loading)) _icons.remove(url);
    });
    _icons[url] = loading;
    while (_icons.length > _maxCachedIcons) {
      _icons.remove(_icons.keys.first);
    }
    return loading;
  }

  Future<SiteIcon?> _load(
    String url,
    String documentUrl, {
    required void Function() forget,
  }) async {
    if (url.startsWith('data:')) {
      final bytes = _dataBytes(url);
      return bytes == null ? null : decodeSiteIcon(bytes);
    }
    final bytes = await fetch(url, documentUrl);
    if (bytes == null) {
      // A refused or failed request can go through for a later document. An
      // image that decodes to nothing usable (a 16px favicon.ico) stays
      // cached, or every page of the site would fetch it again.
      forget();
      return null;
    }
    return decodeSiteIcon(bytes);
  }

  static Uint8List? _dataBytes(String url) {
    try {
      return Uri.parse(url).data?.contentAsBytes();
    } catch (_) {
      return null;
    }
  }
}
