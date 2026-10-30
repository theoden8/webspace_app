import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/engine_image.dart';
import 'package:webspace/services/host_resolution.dart';
import 'package:webspace/services/host_user_agent.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/trusted_hosts_service.dart';
import '../third_party/favicon/favicon.dart';

/// Acquire an HTTP client honoring [proxy], or null when the proxy cannot
/// be honored (e.g. malformed address). Callers MUST treat null as "abort
/// the request" — falling back to the default `http` client would leak the
/// device IP and defeat the proxy the user configured.
http.Client? _proxiedClient(ProxyRoute proxy) {
  final result = outboundHttp.clientFor(proxy);
  if (result is OutboundClientReady) {
    return SiteUserAgentClient(result.client,
        userAgent: HostBrowser.sentUserAgent);
  }
  if (result is OutboundClientBlocked) {
    LogTag.icon.warning('Outbound blocked: ${result.reason}');
  }
  return null;
}

class IconUpdate {
  final String url;
  final int quality;
  final bool isFinal;

  IconUpdate(this.url, {required this.quality,this.isFinal = false});
}

// Cache for favicon URLs (stores best quality found)
final Map<String, String?> _faviconCache = {};
final Map<String, int> _faviconQualityCache = {};

final Map<String, String> _svgContentCache = {};

// In-memory cache of raster icon bytes, keyed by icon URL. The render path
// pulls bytes from here instead of letting an image widget run its own HTTP
// stack, so without a cache every drawer/tab rebuild would re-issue the fetch.
final Map<String, Uint8List> _iconBytesCache = {};

/// Callback to persist SVG content. Set by the UI layer (FaviconUrlCache).
Future<void> Function(String url, {required String content})?
    onSvgContentCached;

/// Get cached SVG content for a URL, or fetch and cache it.
///
/// [proxy] is the per-site proxy of the *site* the icon belongs to. When
/// null, the app-global outbound proxy applies.
Future<String?> getSvgContent(
  String svgUrl, {
  String? persistedContent,
  required OutboundProxy proxy,
  bool persist = true,
}) async {
  if (_svgContentCache.containsKey(svgUrl)) {
    return _svgContentCache[svgUrl];
  }
  if (persistedContent != null) {
    _svgContentCache[svgUrl] = persistedContent;
    return persistedContent;
  }
  final client = _proxiedClient(proxy.resolved);
  if (client == null) return null;
  try {
    final response = await client.get(Uri.parse(svgUrl)).timeout(
      const Duration(seconds: 5),
    );
    if (response.statusCode == 200) {
      _svgContentCache[svgUrl] = response.body;
      if (persist) unawaited(onSvgContentCached?.call(svgUrl, content: response.body));
      _imageController.add(svgUrl);
      return response.body;
    }
  } on http.ClientException catch (e) {
    LogTag.icon.error('Failed to fetch SVG content: $e');
  } on IOException catch (e) {
    LogTag.icon.error('Failed to fetch SVG content: $e');
  } on FormatException catch (e) {
    LogTag.icon.error('Failed to fetch SVG content: $e');
  } on TimeoutException catch (e) {
    LogTag.icon.error('Failed to fetch SVG content: $e');
  } finally {
    client.close();
  }
  // Another fetch may have brought it while this one ran.
  return _svgContentCache[svgUrl];
}

/// Fetch the raw bytes of an icon at [iconUrl] through the proxy-aware
/// client. Returns null when the proxy cannot be honored (fail-closed, same
/// as every other favicon fetch) or the request fails. [proxy] is the
/// per-site proxy of the site the icon belongs to; null means the app-global
/// outbound proxy applies.
Future<Uint8List?> fetchIconBytes(String iconUrl, {required OutboundProxy proxy}) async {
  final client = _proxiedClient(proxy.resolved);
  if (client == null) return null;
  try {
    final response = await client.get(Uri.parse(iconUrl)).timeout(
      const Duration(seconds: 10),
    );
    if (response.statusCode == 200) {
      return response.bodyBytes;
    }
  } on http.ClientException catch (e) {
    LogTag.icon.error('Failed to fetch icon bytes: $e');
  } on IOException catch (e) {
    LogTag.icon.error('Failed to fetch icon bytes: $e');
  } on FormatException catch (e) {
    LogTag.icon.error('Failed to fetch icon bytes: $e');
  } on TimeoutException catch (e) {
    LogTag.icon.error('Failed to fetch icon bytes: $e');
  } finally {
    client.close();
  }
  return null;
}

/// Largest page icon read, in bytes.
const int kMaxPageIconBytes = 1024 * 1024;

const int _maxPageIconRedirects = 3;

bool _isRedirectStatus(int status) =>
    status == 301 ||
    status == 302 ||
    status == 303 ||
    status == 307 ||
    status == 308;

/// GET [iconUrl], an icon link a site's page declared (ICON-013), through
/// the site's [proxy]. Reads at most [kMaxPageIconBytes]; see
/// [fetchPageLinkedBytes].
Future<Uint8List?> fetchPageIconBytes(
  String iconUrl, {
  required String documentHost,
  required bool Function(Uri target) allowed,
  required OutboundProxy proxy,
}) =>
    fetchPageLinkedBytes(
      iconUrl,
      documentHost: documentHost,
      allowed: allowed,
      proxy: proxy,
      maxBytes: kMaxPageIconBytes,
    );

/// GET [url], a resource a site's page linked (an icon, an OpenSearch
/// description), through the site's [proxy].
///
/// The page chooses the address, so every hop (the link and each redirect)
/// must pass [allowed], the site's own blockers, and the private-range guard
/// the user-script bridge uses; a redirect may not drop from https to http.
/// Hops to [documentHost] skip the range guard: a site the user added on
/// their LAN serves its icon from the LAN. Reads at most [maxBytes].
/// Null on any refusal or failure.
Future<Uint8List?> fetchPageLinkedBytes(
  String url, {
  required String documentHost,
  required bool Function(Uri target) allowed,
  required int maxBytes,
  required OutboundProxy proxy,
}) async {
  final effective = proxy.resolved;
  Future<bool> permitted(Uri target) async {
    if (target.scheme != 'http' && target.scheme != 'https') return false;
    final host = target.host.toLowerCase();
    if (host.isEmpty || !allowed(target)) return false;
    if (host == documentHost.toLowerCase()) return true;
    if (isPrivateOrLoopbackHost(host)) return false;
    final verdict =
        await classifyOutboundTarget(target.toString(), effective: effective);
    return verdict == HostRangeVerdict.public ||
        verdict == HostRangeVerdict.notResolvedHere;
  }

  final first = Uri.tryParse(url);
  if (first == null || !await permitted(first)) return null;
  final client = _proxiedClient(effective);
  if (client == null) return null;
  try {
    return await _readPageLinked(client,
            first: first, permitted: permitted, maxBytes: maxBytes)
        .timeout(const Duration(seconds: 15));
  } on http.ClientException catch (e) {
    LogTag.icon.warning('Failed to fetch page link $url: $e', sensitive: true);
    return null;
  } on IOException catch (e) {
    LogTag.icon.warning('Failed to fetch page link $url: $e', sensitive: true);
    return null;
  } on FormatException catch (e) {
    LogTag.icon.warning('Failed to fetch page link $url: $e', sensitive: true);
    return null;
  } on TimeoutException catch (e) {
    LogTag.icon.warning('Failed to fetch page link $url: $e', sensitive: true);
    return null;
  } finally {
    client.close();
  }
}

Future<Uint8List?> _readPageLinked(
  http.Client client, {
  required Uri first,
  required Future<bool> Function(Uri target) permitted,
  required int maxBytes,
}) async {
  var target = first;
  for (var hop = 0;; hop++) {
    final response = await client
        .send(http.Request('GET', target)..followRedirects = false);
    final location = response.headers['location'];
    if (_isRedirectStatus(response.statusCode) &&
        location != null &&
        location.isNotEmpty) {
      final next = target.resolve(location);
      if (hop >= _maxPageIconRedirects ||
          (target.scheme == 'https' && next.scheme == 'http') ||
          !await permitted(next)) {
        return null;
      }
      target = next;
      continue;
    }
    if (response.statusCode != 200) return null;
    final length = response.contentLength;
    if (length != null && length > maxBytes) return null;
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      bytes.add(chunk);
      if (bytes.length > maxBytes) return null;
    }
    return bytes.takeBytes();
  }
}

/// Bytes for [iconUrl], cached in memory, fetched through the proxy-aware
/// client on a miss. The favicon host is chosen by the page (any absolute
/// `href` in its markup wins) and the winner is re-rendered on every launch,
/// so the render path must not reach the network on its own: null means
/// "render the fallback", never "retry unproxied".
Future<Uint8List?> getIconBytes(String iconUrl, {required OutboundProxy proxy}) async {
  final cached = _iconBytesCache[iconUrl];
  if (cached != null) return cached;
  final bytes = await fetchIconBytes(iconUrl, proxy: proxy);
  // Another fetch may have brought them while this one ran.
  if (bytes == null) return _iconBytesCache[iconUrl];
  _iconBytesCache[iconUrl] = bytes;
  _imageController.add(iconUrl);
  return bytes;
}

/// Invalidate in-memory caches for a URL so icons are re-fetched.
/// Emits on [faviconInvalidations] only when an entry actually
/// existed, so re-entrant calls (widget listener → FaviconUrlCache
/// → here) terminate instead of looping forever.
void invalidateFaviconFor(String siteUrl) {
  final hadEntry = _faviconCache.containsKey(siteUrl) ||
      _faviconQualityCache.containsKey(siteUrl);
  _faviconCache.remove(siteUrl);
  _faviconQualityCache.remove(siteUrl);
  if (hadEntry) {
    _invalidationController.add(siteUrl);
  }
}

/// Fires the site URL whenever its cached favicon entry is invalidated.
/// `UnifiedFaviconImage` subscribes so a TLS pin granted after the
/// initial fetch (which would have died with CERTIFICATE_VERIFY_FAILED
/// before the user had a chance to approve) reliably triggers a
/// re-fetch without waiting for a page rebuild.
final StreamController<String> _invalidationController =
    StreamController<String>.broadcast();
Stream<String> get faviconInvalidations => _invalidationController.stream;

bool _trustListenerWired = false;

/// One-shot bootstrap: subscribes the icon service to
/// [TrustedHostsService.trustChanges]. After every new pin, every
/// favicon cache entry whose URL host (case-insensitive, port aware)
/// matches the trusted entry is invalidated and re-fetched.
void wireFaviconTrustInvalidation() {
  if (_trustListenerWired) return;
  _trustListenerWired = true;
  TrustedHostsService.instance.trustChanges.listen((entry) {
    final host = entry.host.toLowerCase();
    final keys = _faviconCache.keys.toList();
    final hits = <String>[];
    for (final key in keys) {
      final uri = Uri.tryParse(key);
      if (uri == null) continue;
      if (uri.host.toLowerCase() != host) continue;
      final port = uri.hasPort
          ? uri.port
          : (uri.scheme == 'https' ? 443 : (uri.scheme == 'http' ? 80 : 0));
      if (port != entry.port) continue;
      hits.add(key);
    }
    if (hits.isEmpty) return;
    LogTag.icon.debug('Trust granted for ${entry.host}:${entry.port} — '
        'invalidating ${hits.length} cached favicon(s)', sensitive: true);
    for (final key in hits) {
      invalidateFaviconFor(key);
    }
  });
}

final Set<String> _verifiedUrls = {};

final StreamController<void> _reloadController =
    StreamController<void>.broadcast();

final StreamController<String> _foundController =
    StreamController<String>.broadcast();

/// Fires a site's URL when a search finds its icon, so an icon of the site
/// whose own search found none takes it: a folder's preview drawn at launch,
/// offline, learns of the icon its site's tile found later.
Stream<String> get faviconsFound => _foundController.stream;

final StreamController<String> _imageController =
    StreamController<String>.broadcast();

/// Fires an icon's URL when its image, or its SVG body, arrives, so an icon
/// whose own fetch of it failed takes it: a folder's preview drawn at launch
/// with the icon's URL known, before the network or its proxy was up.
Stream<String> get iconImagesFetched => _imageController.stream;

/// Fires when every icon cache was cleared, so every icon on screen is
/// fetched again.
Stream<void> get iconReloads => _reloadController.stream;

/// Clear the in-memory caches and have every icon on screen fetched again.
/// The caller clears what is kept on disk first.
void reloadAllIcons() {
  clearFaviconCache();
  _reloadController.add(null);
}

class _IconCandidate {
  final String url;
  final int quality;

  _IconCandidate(this.url, {required this.quality});
}

Future<bool> _verifyIconUrl(String iconUrl,
    {required ProxyRoute proxy}) async {
  if (_verifiedUrls.contains(iconUrl)) {
    return true;
  }
  final client = _proxiedClient(proxy);
  if (client == null) return false;

  try {
    final response = await client.head(Uri.parse(iconUrl)).timeout(
      Duration(milliseconds: 8000),
      onTimeout: () => http.Response('', 408),
    );

    final isValid = response.statusCode == 200;
    if (isValid) {
      _verifiedUrls.add(iconUrl);
    }
    return isValid;
  } on http.ClientException {
    return false;
  } on IOException {
    return false;
  } on FormatException {
    return false;
  } finally {
    client.close();
  }
}

// CSS `display: none` theme toggles defeat flutter_svg: it ignores the rule,
// draws both light/dark variants, and a hidden overlay rect ends up masking
// the icon. The pixel render probe below can't catch this (the frame comes
// back fully painted, just wrong), so detect it structurally. Input must be
// lowercased.
bool svgHasMaskingStyleToggle(String lowerSvg) {
  final styleBlockPattern = RegExp(r'<style[^>]*>(.*?)</style>', dotAll: true);
  for (var styleMatch in styleBlockPattern.allMatches(lowerSvg)) {
    if (RegExp(r'display\s*:\s*none').hasMatch(styleMatch.group(1) ?? '')) {
      return true;
    }
  }
  return false;
}

// True if the SVG declares any non-trivial color (attribute or CSS). Input
// must be lowercased.
bool svgHasRealColor(String lowerSvg) {
  final attrColorPattern =
      RegExp(r'(?:fill|stroke)\s*=\s*["\x27]#([0-9a-f]{3,6})["\x27]');
  for (var match in attrColorPattern.allMatches(lowerSvg)) {
    if (_isRealColor(match.group(1)!)) return true;
  }

  final stylePattern = RegExp(r'<style[^>]*>(.*?)</style>', dotAll: true);
  for (var styleMatch in stylePattern.allMatches(lowerSvg)) {
    // Drop media queries so theme-switch palettes don't read as real color.
    final withoutMedia = (styleMatch.group(1) ?? '')
        .replaceAll(RegExp(r'@media[^{]*\{[^}]*\}', dotAll: true), '');
    final cssColorPattern = RegExp(
        r'(?:color|fill|stroke|stop-color|background)\s*:\s*#([0-9a-f]{3,6})');
    for (var match in cssColorPattern.allMatches(withoutMedia)) {
      if (_isRealColor(match.group(1)!)) return true;
    }
    if (withoutMedia.contains('rgb(') || withoutMedia.contains('hsl(')) {
      return true;
    }
  }
  return false;
}

/// [svg], a page's, compiled to a picture, or null when the compiler rejects
/// it. It rejects bad input with errors as well as exceptions (an element it
/// does not support is an [UnsupportedError], a `<use>` inside the element
/// it names recurses until the stack overflows), so what a hostile icon can
/// make it throw is named here, once.
Future<PictureInfo?> loadUntrustedSvg(String svg) async {
  try {
    return await vg.loadPicture(SvgStringLoader(svg), null);
  } on FormatException catch (e) {
    LogTag.icon.warning('SVG rejected: $e');
  } on UnsupportedError catch (e) {
    LogTag.icon.warning('SVG rejected: $e');
  } on StateError catch (e) {
    LogTag.icon.warning('SVG rejected: $e');
  } on ArgumentError catch (e) {
    LogTag.icon.warning('SVG rejected: $e');
  } on StackOverflowError catch (e) {
    LogTag.icon.warning('SVG rejected: $e');
  }
  return null;
}

// Rasterize the SVG the way the app will and report whether it comes back
// effectively empty. flutter_svg (vector_graphics) renders some valid SVGs
// blank, e.g. nested <svg> viewports (duck.ai's favicon.svg), and such an icon
// must lose to raster fallbacks instead of winning on color and showing
// nothing. On probe failure we assume the icon is fine (return false) rather
// than punish it.
@visibleForTesting
Future<bool> svgRendersBlank(String rawSvg) async {
  const n = 48;
  final info = await loadUntrustedSvg(rawSvg);
  if (info == null) return false;
  try {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final size = info.size;
    if (size.width > 0 && size.height > 0) {
      canvas.scale(n / size.width, n / size.height);
    }
    canvas.drawPicture(info.picture);
    final image =
        await engineImage(() => recorder.endRecording().toImage(n, n));
    try {
      final bytes = await engineImage(
          () => image.toByteData(format: ui.ImageByteFormat.rawRgba));
      if (bytes == null) return false;
      final data = bytes.buffer.asUint8List();
      var opaque = 0;
      for (var i = 3; i < data.length; i += 4) {
        if (data[i] > 16) opaque++;
      }
      return opaque / (n * n) < 0.01;
    } finally {
      image.dispose();
    }
  } finally {
    info.picture.dispose();
  }
}

// Whether an SVG should be preferred as a high-quality icon: it must carry
// real color AND actually render. A colored-but-blank SVG (or a theme-toggle
// SVG flutter_svg masks) is demoted so raster fallbacks win.
Future<bool> _isSvgColored(String svgUrl, {required ProxyRoute proxy}) async {
  final client = _proxiedClient(proxy);
  if (client == null) return false;
  try {
    final response = await client.get(Uri.parse(svgUrl)).timeout(
      Duration(seconds: 2),
    );
    if (response.statusCode != 200) return false;

    final rawSvg = response.body;
    final lowerSvg = rawSvg.toLowerCase();

    if (svgHasMaskingStyleToggle(lowerSvg)) {
      LogTag.icon.debug(
          'SVG uses CSS visibility switching, treating as low quality: $svgUrl',
          sensitive: true);
      return false;
    }

    if (!svgHasRealColor(lowerSvg)) {
      LogTag.icon.debug('SVG appears monochrome: $svgUrl', sensitive: true);
      return false;
    }

    if (await svgRendersBlank(rawSvg)) {
      LogTag.icon.debug(
          'SVG renders blank under flutter_svg (e.g. nested <svg>), treating as low quality: $svgUrl',
          sensitive: true);
      return false;
    }

    return true;
  } on http.ClientException catch (e) {
    LogTag.icon.error('Failed to check SVG color: $e');
    return false;
  } on IOException catch (e) {
    LogTag.icon.error('Failed to check SVG color: $e');
    return false;
  } on FormatException catch (e) {
    LogTag.icon.error('Failed to check SVG color: $e');
    return false;
  } on TimeoutException catch (e) {
    LogTag.icon.error('Failed to check SVG color: $e');
    return false;
  } on EngineImageFailure catch (e) {
    LogTag.icon.error('Failed to check SVG color: $e');
    return false;
  } finally {
    client.close();
  }
}

bool _isRealColor(String color) {
  // Skip black, white, and common grays
  return color != '000' && color != '000000' &&
         color != 'fff' && color != 'ffffff' &&
         color != '333' && color != '666' && color != '999' &&
         color != 'ccc' && color != 'eee';
}

int _compareFavicons(Favicon a,
    {required Favicon b, required Map<String, bool> svgColorCache}) {
  final aSvg = a.url.endsWith('.svg');
  final bSvg = b.url.endsWith('.svg');

  if (aSvg && bSvg) {
    final aColored = svgColorCache[a.url] ?? false;
    final bColored = svgColorCache[b.url] ?? false;

    if (aColored && !bColored) return -1;
    if (!aColored && bColored) return 1;

    // Both monochrome SVGs, treat as low quality
    if (!aColored && !bColored) return 1; // Prefer bitmaps over monochrome SVGs
  }

  // Monochrome SVG vs bitmap - prefer bitmap
  if (aSvg && !bSvg && !(svgColorCache[a.url] ?? false)) return 1;
  if (bSvg && !aSvg && !(svgColorCache[b.url] ?? false)) return -1;

  return a.compareTo(b);
}

/// The best icon the site's home page declares (ICON-002), as one final
/// [IconUpdate], or nothing when none is found. Every request goes to a host
/// the page names, through [proxy]; no third-party icon service is asked
/// (ICON-014).
Stream<IconUpdate> getFaviconUrlStream(String url, {required OutboundProxy proxy}) async* {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) {
    return;
  }

  final cachedUrl = _faviconCache[url];
  if (cachedUrl != null) {
    final cachedQuality = _faviconQualityCache[url] ?? 100;
    LogTag.icon.debug(
        'Stream: Using cached icon for $url (quality: $cachedQuality)',
        sensitive: true);
    yield IconUpdate(cachedUrl, quality: cachedQuality, isFinal: true);
    return;
  }

  final found = await _tryFaviconPackage(url, site: proxy);
  final known = _faviconCache[url];
  if (found == null && known != null) {
    // Another search found it while this one ran, and nothing replaces it.
    yield IconUpdate(known,
        quality: _faviconQualityCache[url] ?? 100, isFinal: true);
    return;
  }
  _faviconCache[url] = found?.url;
  _faviconQualityCache[url] = found?.quality ?? 0;
  if (found != null) {
    _foundController.add(url);
    yield IconUpdate(found.url, quality: found.quality, isFinal: true);
  }

  LogTag.icon.debug(
      'Stream: Completed for $url, quality: ${found?.quality ?? 0}',
      sensitive: true);
}

Future<_IconCandidate?> _tryFaviconPackage(String url,
    {required OutboundProxy site}) async {
  final proxy = site.resolved;
  // Internal schemes (chrome://, about:, file:, data:, blob:) have no
  // favicon reachable over the network — sending them through any proxy
  // (let alone SOCKS5) yields a confusing connection error from the
  // remote side. Skip the fetch entirely.
  final uri = Uri.tryParse(url);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  // Scraping the page for <link rel=icon> means reading a cross-origin
  // response, which a browser refuses however the request is made, so on web
  // a site shows the placeholder rather than raising a CORS error per site.
  if (!hostCanReadCrossOriginResponses) return null;
  try {
    final favicons = await FaviconFinder.getAll(url, proxy: site).timeout(Duration(seconds: 15));
    if (favicons.isEmpty) return null;

    LogTag.icon.debug(
        'Favicons: ${favicons.map((f) => '${f.url} (width: ${f.width}, height: ${f.height})').join(', ')}',
        sensitive: true);

    final svgColorCache = <String, bool>{};

    await Future.wait(
      favicons.where((f) => f.url.endsWith('.svg')).map((f) async {
        svgColorCache[f.url] = await _isSvgColored(f.url, proxy: proxy);
      })
    );

    favicons.sort((a, b) => _compareFavicons(a, b: b, svgColorCache: svgColorCache));

    final best = favicons.first;

    if (await _verifyIconUrl(best.url, proxy: proxy)) {
      int quality;

      if (best.url.endsWith('.svg')) {
        quality = (svgColorCache[best.url] ?? false) ? 1000 : 30;
      } else {
        quality = (best.width > 0) ? best.width : 50;
      }

      LogTag.icon.debug(
          'Found favicon via package for $url (quality: $quality) ${best.url}',
          sensitive: true);
      return _IconCandidate(best.url, quality: quality);
    }
  } on http.ClientException catch (e) {
    LogTag.icon.error('FaviconFinder failed for $url: $e', sensitive: true);
  } on IOException catch (e) {
    LogTag.icon.error('FaviconFinder failed for $url: $e', sensitive: true);
  } on FormatException catch (e) {
    LogTag.icon.error('FaviconFinder failed for $url: $e', sensitive: true);
  } on TimeoutException catch (e) {
    LogTag.icon.error('FaviconFinder failed for $url: $e', sensitive: true);
  }
  return null;
}

void clearFaviconCache() {
  _faviconCache.clear();
  _faviconQualityCache.clear();
  _verifiedUrls.clear();
  _svgContentCache.clear();
  _iconBytesCache.clear();
}
