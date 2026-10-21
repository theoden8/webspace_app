import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/engine_image.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/site_icon_engine.dart';

/// Where a site's own icon comes from.
enum PageIconSource {
  /// The icon the webview reports: Android's `onReceivedIcon`, and WPE's
  /// `page-icons` forwarded as it (ICON-009).
  webview,

  /// The links the page declared, fetched by the app (ICON-013).
  declaredLinks,

  /// Neither: no webview hosts a site here.
  none,
}

/// Whether this Linux build's WPE reports the page's icons, read once at
/// startup.
class WpePageIcons {
  static bool _reported = false;

  static Future<void> initialize() async {
    if (!hostIsLinux) return;
    try {
      _reported = wpeReportsPageIcons(
          await inapp.WebViewEnvironment.getAvailableVersion());
    } on PlatformException catch (e) {
      LogTag.icon.warning('WPE version unknown: $e');
    } on MissingPluginException catch (e) {
      LogTag.icon.warning('WPE version unknown: $e');
    }
  }
}

/// Whether WPE [version] has `WebKitWebView:page-icons` (2.54), which the
/// fork forwards as `onReceivedIcon`. A plugin built against it needs it at
/// run time too; one built against an older WPE does not forward it even on
/// a newer one, and the site keeps its ICON-002 icon there.
@visibleForTesting
bool wpeReportsPageIcons(String? version) {
  final parts = (version ?? '').split('.').map(int.tryParse).toList();
  if (parts.length < 2) return false;
  final [major, minor, ...] = parts;
  if (major == null || minor == null) return false;
  return major > 2 || (major == 2 && minor >= 54);
}

/// Where a site's own icon comes from on this platform, read when a webview
/// is created.
PageIconSource get pageIconSource => pageIconSourceFor(
      webviewReports: hostIsAndroid || WpePageIcons._reported,
      webkit: hostIsIOS || hostIsMacOS || hostIsLinux,
    );

/// Android WebView and WPE from 2.54 report a page icon they fetched
/// themselves; WKWebView and an older WPE report none, so the app fetches
/// the declared links there.
@visibleForTesting
PageIconSource pageIconSourceFor({
  required bool webviewReports,
  required bool webkit,
}) {
  if (webviewReports) return PageIconSource.webview;
  return webkit ? PageIconSource.declaredLinks : PageIconSource.none;
}

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
    final buffered =
        await engineImage(() => ui.ImmutableBuffer.fromUint8List(bytes));
    buffer = buffered;
    final described =
        await engineImage(() => ui.ImageDescriptor.encoded(buffered));
    descriptor = described;
    final width = described.width;
    final height = described.height;
    if (math.min(width, height) < kMinSiteIconEdge ||
        math.max(width, height) > kMaxSiteIconDecodeEdge) {
      return null;
    }
    final scale = math.min(1.0, kMaxSiteIconEdge / math.max(width, height));
    final frames = await engineImage(() => described.instantiateCodec(
          targetWidth: math.max(1, (width * scale).round()),
          targetHeight: math.max(1, (height * scale).round()),
        ));
    codec = frames;
    final frame = (await engineImage(frames.getNextFrame)).image;
    image = frame;
    final png = await engineImage(
        () => frame.toByteData(format: ui.ImageByteFormat.png));
    if (png == null) return null;
    return SiteIcon(
      png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      width: frame.width,
      height: frame.height,
    );
  } on EngineImageFailure {
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// Fetches the icon links a site's page declared and picks the one to offer
/// (ICON-013). One per site webview.
class SiteIconFetcher {
  SiteIconFetcher({required this.fetch});

  /// GET an http(s) icon link declared by the document at the given URL, or
  /// null.
  final Future<Uint8List?> Function(String url, {required String documentUrl})
      fetch;

  final LinkedHashMap<String, Future<SiteIcon?>> _icons = LinkedHashMap();

  /// The largest icon among [urls] declared by the document at
  /// [documentUrl], or null when none decodes to a usable icon.
  Future<SiteIcon?> best(List<String> urls,
      {required String documentUrl}) async {
    final icons = await Future.wait(
        [for (final url in urls) _icon(url, documentUrl: documentUrl)]);
    SiteIcon? best;
    for (final icon in icons) {
      if (icon != null && (best == null || icon.edge > best.edge)) best = icon;
    }
    return best;
  }

  Future<SiteIcon?> _icon(String url, {required String documentUrl}) {
    final known = _icons.remove(url);
    if (known != null) return _icons[url] = known;
    late final Future<SiteIcon?> loading;
    loading = _load(url, documentUrl: documentUrl, forget: () {
      // A cached future dropped, not one started.
      // ignore: discarded_futures
      if (identical(_icons[url], loading)) _icons.remove(url);
    });
    _icons[url] = loading;
    while (_icons.length > _maxCachedIcons) {
      // ignore: discarded_futures
      _icons.remove(_icons.keys.first);
    }
    return loading;
  }

  Future<SiteIcon?> _load(
    String url, {
    required String documentUrl,
    required void Function() forget,
  }) async {
    if (url.startsWith('data:')) {
      final bytes = _dataBytes(url);
      return bytes == null ? null : decodeSiteIcon(bytes);
    }
    final bytes = await fetch(url, documentUrl: documentUrl);
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
      return Uri.tryParse(url)?.data?.contentAsBytes();
    } on FormatException {
      return null;
    }
  }
}
