import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:webspace/services/log_service.dart';
import '../third_party/favicon/favicon.dart';

/// Icon Service - Handles favicon fetching with quality scoring
///
/// Features:
/// - Progressive loading: icons update as better quality versions are found
/// - Google & DuckDuckGo services for high-quality icons
/// - Falls back to favicon package for HTML parsing + favicon.ico
/// - Domain substitution rules
/// - Caching to avoid repeated requests
/// - Max 5 concurrent requests

/// Represents an icon update with quality information
class IconUpdate {
  final String url;
  final int quality;
  final bool isFinal;

  IconUpdate(this.url, this.quality, {this.isFinal = false});
}

// Cache for favicon URLs (stores best quality found)
final Map<String, String?> _faviconCache = {};
final Map<String, int> _faviconQualityCache = {};

// In-memory cache for SVG content
final Map<String, String> _svgContentCache = {};

/// Callback to persist SVG content. Set by the UI layer (FaviconUrlCache).
Future<void> Function(String url, String content)? onSvgContentCached;

/// Get cached SVG content for a URL, or fetch and cache it.
Future<String?> getSvgContent(String svgUrl, {String? persistedContent}) async {
  if (_svgContentCache.containsKey(svgUrl)) {
    return _svgContentCache[svgUrl];
  }
  // Use persisted content from disk cache if available
  if (persistedContent != null) {
    _svgContentCache[svgUrl] = persistedContent;
    return persistedContent;
  }
  try {
    final response = await http.get(Uri.parse(svgUrl)).timeout(
      const Duration(seconds: 5),
    );
    if (response.statusCode == 200) {
      _svgContentCache[svgUrl] = response.body;
      onSvgContentCached?.call(svgUrl, response.body);
      return response.body;
    }
  } catch (e) {
    LogService.instance.log('Icon', 'Failed to fetch SVG content: $e', level: LogLevel.error);
  }
  return null;
}

/// Invalidate in-memory caches for a URL so icons are re-fetched.
void invalidateFaviconFor(String siteUrl) {
  _faviconCache.remove(siteUrl);
  _faviconQualityCache.remove(siteUrl);
}

// Verified URLs cache
final Set<String> _verifiedUrls = {};

// Domain substitution rules
const Map<String, String> _domainSubstitutions = {
  'gmail.com': 'mail.google.com',
};

// Request queue management
const int _maxConcurrentRequests = 5;
int _activeRequests = 0;
final Queue<Completer<void>> _requestQueue = Queue();

String _applyDomainSubstitution(String domain) {
  return _domainSubstitutions[domain] ?? domain;
}

// Check if host is an IP address (IPv4 or IPv6)
bool _isIpAddress(String host) {
  // IPv4: digits and dots only, with valid octet pattern
  final ipv4Pattern = RegExp(r'^(\d{1,3}\.){3}\d{1,3}$');
  if (ipv4Pattern.hasMatch(host)) return true;

  // IPv6: contains colons (including bracketed form [::1])
  if (host.contains(':')) return true;

  // Localhost variations
  if (host == 'localhost') return true;

  return false;
}

// Check if we should use public icon services (Google, DuckDuckGo)
// Returns false for http:// sites and IP addresses
bool _shouldUsePublicIconServices(Uri uri) {
  // Skip for non-HTTPS sites
  if (uri.scheme != 'https') return false;

  // Skip for IP addresses and localhost
  if (_isIpAddress(uri.host)) return false;

  return true;
}

class _IconCandidate {
  final String url;
  final int quality;

  _IconCandidate(this.url, this.quality);
}

Future<bool> _verifyIconUrl(String iconUrl) async {
  if (_verifiedUrls.contains(iconUrl)) {
    return true;
  }

  try {
    final response = await http.head(Uri.parse(iconUrl)).timeout(
      Duration(milliseconds: 8000),
      onTimeout: () => http.Response('', 408),
    );

    final isValid = response.statusCode == 200;
    if (isValid) {
      _verifiedUrls.add(iconUrl);
    }
    return isValid;
  } catch (e) {
    return false;
  }
}

// Helper: Check if SVG is monochrome (returns true if it's a colored SVG).
// Also returns false for SVGs that rely on CSS-based visibility switching
// (e.g. theme-aware icons with `<style>` blocks toggling `display: none`),
// since flutter_svg's limited CSS support renders all groups simultaneously
// and those SVGs end up with overlay rectangles obscuring the actual icon.
Future<bool> _isSvgColored(String svgUrl) async {
  try {
    final response = await http.get(Uri.parse(svgUrl)).timeout(
      Duration(seconds: 2),
    );
    if (response.statusCode != 200) return false;

    final svgContent = response.body.toLowerCase();

    // Detect CSS-driven visibility toggles in <style> blocks. flutter_svg
    // does not honor `display: none` from style sheets, so both variants
    // render and a hidden background rect can cover the visible icon (e.g.
    // duck.ai's favicon.svg with light/dark icon swap).
    final styleBlockPattern = RegExp(r'<style[^>]*>(.*?)</style>', dotAll: true);
    for (var styleMatch in styleBlockPattern.allMatches(svgContent)) {
      final styleContent = styleMatch.group(1) ?? '';
      if (RegExp(r'display\s*:\s*none').hasMatch(styleContent)) {
        LogService.instance.log('Icon',
            'SVG uses CSS visibility switching, treating as low quality: $svgUrl');
        return false;
      }
    }

    // Check for hex colors in attributes (fill="..." stroke="...")
    final attrColorPattern = RegExp(
        r'(?:fill|stroke)\s*=\s*["\x27]#([0-9a-f]{3,6})["\x27]');
    final attrMatches = attrColorPattern.allMatches(svgContent);

    for (var match in attrMatches) {
      final color = match.group(1)!.toLowerCase();
      if (_isRealColor(color)) {
        LogService.instance.log('Icon', 'Found colored SVG with attr color #$color: $svgUrl');
        return true;
      }
    }

    // Check for colors in style blocks (including CSS properties)
    final stylePattern = RegExp(r'<style[^>]*>(.*?)</style>', dotAll: true);
    final styleMatches = stylePattern.allMatches(svgContent);

    for (var styleMatch in styleMatches) {
      final styleContent = styleMatch.group(1) ?? '';

      // Remove media queries to avoid false positives from theme switching
      final withoutMedia = styleContent.replaceAll(
          RegExp(r'@media[^{]*\{[^}]*\}', dotAll: true), '');

      // Look for CSS color properties: color, fill, stroke, stop-color, etc.
      final cssColorPattern = RegExp(
          r'(?:color|fill|stroke|stop-color|background)\s*:\s*#([0-9a-f]{3,6})');
      final cssMatches = cssColorPattern.allMatches(withoutMedia);

      for (var match in cssMatches) {
        final color = match.group(1)!.toLowerCase();
        if (_isRealColor(color)) {
          LogService.instance.log('Icon', 'Found colored SVG with CSS color #$color: $svgUrl');
          return true;
        }
      }

      // Check for rgb/hsl
      if (withoutMedia.contains('rgb(') || withoutMedia.contains('hsl(')) {
        LogService.instance.log('Icon', 'Found colored SVG with rgb/hsl: $svgUrl');
        return true;
      }
    }

    LogService.instance.log('Icon', 'SVG appears monochrome: $svgUrl');
    return false;
  } catch (e) {
    LogService.instance.log('Icon', 'Failed to check SVG color: $e', level: LogLevel.error);
    return false;
  }
}

bool _isRealColor(String color) {
  // Skip black, white, and common grays
  return color != '000' && color != '000000' &&
         color != 'fff' && color != 'ffffff' &&
         color != '333' && color != '666' && color != '999' &&
         color != 'ccc' && color != 'eee';
}

int _compareFavicons(Favicon a, Favicon b, Map<String, bool> svgColorCache) {
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

Future<Favicon?> _findBestIcon(String url) async {
  final favicons = await FaviconFinder.getAll(url);
  LogService.instance.log('Icon', 'Favicons: ${favicons.map((f) => '${f.url} (width: ${f.width}, height: ${f.height})').join(', ')}');
  if (favicons.isEmpty) return null;

  final svgColorCache = <String, bool>{};

  // Check SVG colors in parallel
  await Future.wait(
    favicons.where((f) => f.url.endsWith('.svg')).map((f) async {
      svgColorCache[f.url] = await _isSvgColored(f.url);
    })
  );

  favicons.sort((a, b) => _compareFavicons(a, b, svgColorCache));

  return favicons.first;
}

/// Fetches the best quality favicon for a given URL (legacy single-result API)
///
/// Quality scoring:
/// - 256: Google 256px
/// - 128: Google 128px
/// - 64: DuckDuckGo
/// - 50: favicon package (HTML parsing + favicon.ico)
Future<String?> getFaviconUrl(String url) async {
  // Check cache first
  if (_faviconCache.containsKey(url)) {
    LogService.instance.log('Icon', 'Using cached icon for $url');
    return _faviconCache[url];
  }

  // Queue management to limit concurrent requests
  if (_activeRequests >= _maxConcurrentRequests) {
    LogService.instance.log('Icon', 'Queueing request for $url (active: $_activeRequests)');
    final completer = Completer<void>();
    _requestQueue.add(completer);
    await completer.future;
  }

  _activeRequests++;
  LogService.instance.log('Icon', 'Starting request for $url (active: $_activeRequests, queued: ${_requestQueue.length})');

  try {
    return await _fetchFaviconUrlInternal(url);
  } finally {
    _activeRequests--;
    LogService.instance.log('Icon', 'Finished request for $url (active: $_activeRequests, queued: ${_requestQueue.length})');

    // Process next queued request
    if (_requestQueue.isNotEmpty) {
      final nextCompleter = _requestQueue.removeFirst();
      nextCompleter.complete();
    }
  }
}

/// Progressive favicon loading - yields icons as they're found
///
/// Emits IconUpdate objects with increasing quality:
/// 1. First emits fast sources (DuckDuckGo ~64px)
/// 2. Then Google services (128px, 256px)
/// 3. Finally the favicon package for site-specific high-res icons
///
/// Each emission only occurs if it's better quality than the previous.
/// The final emission has isFinal=true.
Stream<IconUpdate> getFaviconUrlStream(String url) async* {
  Uri? uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) {
    return;
  }

  String domain = _applyDomainSubstitution(uri.host);
  int bestQuality = 0;
  String? bestUrl;

  // Check cache first - if we have a cached result, emit it immediately
  if (_faviconCache.containsKey(url) && _faviconCache[url] != null) {
    final cachedUrl = _faviconCache[url]!;
    final cachedQuality = _faviconQualityCache[url] ?? 100;
    LogService.instance.log('Icon', 'Stream: Using cached icon for $url (quality: $cachedQuality)');
    yield IconUpdate(cachedUrl, cachedQuality, isFinal: true);
    return;
  }

  // Check if we should use public icon services (skip for http:// and IP addresses)
  final usePublicServices = _shouldUsePublicIconServices(uri);

  LogService.instance.log('Icon', 'Stream: Starting progressive fetch for $url (domain: $domain, usePublicServices: $usePublicServices)');

  // Phase 1 & 2: Public icon services (only for HTTPS + non-IP addresses)
  if (usePublicServices) {
    // Phase 1: Quick sources (DuckDuckGo) - typically responds fast
    final ddgResult = await _tryDuckDuckGo(domain);
    if (ddgResult != null) {
      bestUrl = ddgResult;
      bestQuality = 64;
      LogService.instance.log('Icon', 'Stream: Emitting DuckDuckGo icon (quality: 64)');
      yield IconUpdate(ddgResult, 64);
    }

    // Phase 2: Google services in parallel (128px and 256px)
    final googleResults = await Future.wait([
      _tryGoogleFavicon(domain, 128),
      _tryGoogleFavicon(domain, 256),
    ]);

    // Emit Google 128px if better
    if (googleResults[0] != null && 128 > bestQuality) {
      bestUrl = googleResults[0];
      bestQuality = 128;
      LogService.instance.log('Icon', 'Stream: Emitting Google 128px icon');
      yield IconUpdate(googleResults[0]!, 128);
    }

    // Emit Google 256px if better
    if (googleResults[1] != null && 256 > bestQuality) {
      bestUrl = googleResults[1];
      bestQuality = 256;
      LogService.instance.log('Icon', 'Stream: Emitting Google 256px icon');
      yield IconUpdate(googleResults[1]!, 256);
    }
  }

  // Phase 3: Favicon package (slowest but can find high-res site-specific icons)
  final faviconResult = await _tryFaviconPackage(url);
  if (faviconResult != null && faviconResult.quality > bestQuality) {
    bestUrl = faviconResult.url;
    bestQuality = faviconResult.quality;
    LogService.instance.log('Icon', 'Stream: Emitting favicon package icon (quality: ${faviconResult.quality})');
    yield IconUpdate(faviconResult.url, faviconResult.quality, isFinal: true);
  } else if (bestUrl != null) {
    // Re-emit best as final
    yield IconUpdate(bestUrl, bestQuality, isFinal: true);
  }

  // Cache the best result
  _faviconCache[url] = bestUrl;
  _faviconQualityCache[url] = bestQuality;

  LogService.instance.log('Icon', 'Stream: Completed for $url, best quality: $bestQuality');
}

Future<String?> _fetchFaviconUrlInternal(String url) async {
  Uri? uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) {
    _faviconCache[url] = null;
    return null;
  }

  String domain = _applyDomainSubstitution(uri.host);
  final usePublicServices = _shouldUsePublicIconServices(uri);

  LogService.instance.log('Icon', 'Fetching icon for $url (domain: $domain, usePublicServices: $usePublicServices)');

  final List<_IconCandidate> candidates = [];

  // Try sources in parallel (skip public services for http:// and IP addresses)
  try {
    final futures = <Future<_IconCandidate?>>[];

    if (usePublicServices) {
      futures.addAll([
        _tryGoogleFavicon(domain, 256).then((url) =>
          url != null ? _IconCandidate(url, 256) : null),
        _tryGoogleFavicon(domain, 128).then((url) =>
          url != null ? _IconCandidate(url, 128) : null),
        _tryDuckDuckGo(domain).then((url) =>
          url != null ? _IconCandidate(url, 64) : null),
      ]);
    }

    futures.add(_tryFaviconPackage(url));

    final results = await Future.wait(futures).timeout(
      Duration(seconds: 15),
      onTimeout: () => List<_IconCandidate?>.filled(futures.length, null),
    );

    candidates.addAll(results.whereType<_IconCandidate>());
  } catch (e) {
    LogService.instance.log('Icon', 'Error fetching icons for $url: $e', level: LogLevel.error);
  }

  if (candidates.isEmpty) {
    _faviconCache[url] = null;
    return null;
  }

  // Sort by quality (highest first)
  candidates.sort((a, b) => b.quality.compareTo(a.quality));

  LogService.instance.log('Icon', 'Candidates: ${candidates.map((c) => '${c.url} (quality: ${c.quality})').join(', ')}');

  // Return first valid candidate
  for (var candidate in candidates) {
    if (_verifiedUrls.contains(candidate.url)) {
      _faviconCache[url] = candidate.url;
      return candidate.url;
    }

    // Already verified in the try methods, so just return it
    _faviconCache[url] = candidate.url;
    return candidate.url;
  }

  _faviconCache[url] = null;
  return null;
}

Future<String?> _tryGoogleFavicon(String domain, int size) async {
  try {
    final googleUrl = 'https://www.google.com/s2/favicons?domain=$domain&sz=$size';
    if (await _verifyIconUrl(googleUrl)) {
      LogService.instance.log('Icon', 'Found Google favicon at ${size}px for $domain');
      return googleUrl;
    }
  } catch (e) {
    LogService.instance.log('Icon', 'Google ${size}px failed for $domain: $e', level: LogLevel.error);
  }
  return null;
}

Future<String?> _tryDuckDuckGo(String domain) async {
  try {
    final ddgUrl = 'https://icons.duckduckgo.com/ip3/$domain.ico';
    if (await _verifyIconUrl(ddgUrl)) {
      LogService.instance.log('Icon', 'Found DuckDuckGo favicon for $domain');
      return ddgUrl;
    }
  } catch (e) {
    LogService.instance.log('Icon', 'DuckDuckGo failed for $domain: $e', level: LogLevel.error);
  }
  return null;
}

Future<_IconCandidate?> _tryFaviconPackage(String url) async {
  try {
    final favicons = await FaviconFinder.getAll(url).timeout(Duration(seconds: 15));
    if (favicons.isEmpty) return null;

    LogService.instance.log('Icon', 'Favicons: ${favicons.map((f) => '${f.url} (width: ${f.width}, height: ${f.height})').join(', ')}');

    final svgColorCache = <String, bool>{};

    // Check SVG colors in parallel ONCE
    await Future.wait(
      favicons.where((f) => f.url.endsWith('.svg')).map((f) async {
        svgColorCache[f.url] = await _isSvgColored(f.url);
      })
    );

    // Sort with color information
    favicons.sort((a, b) => _compareFavicons(a, b, svgColorCache));

    final best = favicons.first;

    if (await _verifyIconUrl(best.url)) {
      int quality;

      if (best.url.endsWith('.svg')) {
        quality = (svgColorCache[best.url] ?? false) ? 1000 : 30;
      } else {
        quality = (best.width > 0) ? best.width : 50;
      }

      LogService.instance.log('Icon', 'Found favicon via package for $url (quality: $quality) ${best.url}');
      return _IconCandidate(best.url, quality);
    }
  } catch (e) {
    LogService.instance.log('Icon', 'FaviconFinder failed for $url: $e', level: LogLevel.error);
  }
  return null;
}

// Cache for high-resolution icons discovered by getHighResFaviconUrl.
final Map<String, String?> _hdFaviconCache = {};

/// Parse a "sizes" attribute like "96x96" or "192x192 128x128" into the max px.
/// Returns 0 if unparseable or if value is "any" (vector).
int _parseSizes(String? sizes) {
  if (sizes == null || sizes.isEmpty) return 0;
  int best = 0;
  for (final part in sizes.toLowerCase().split(RegExp(r'\s+'))) {
    if (part == 'any') continue;
    final m = RegExp(r'^(\d+)x(\d+)$').firstMatch(part);
    if (m != null) {
      final w = int.tryParse(m.group(1)!) ?? 0;
      final h = int.tryParse(m.group(2)!) ?? 0;
      final side = w < h ? w : h;
      if (side > best) best = side;
    }
  }
  return best;
}

String _resolveUrl(Uri base, String href) {
  var h = href.trim();
  if (h.startsWith('//')) return '${base.scheme}:$h';
  if (h.startsWith('http://') || h.startsWith('https://')) return h;
  if (h.startsWith('/')) return '${base.scheme}://${base.host}${base.hasPort ? ':${base.port}' : ''}$h';
  return base.resolve(h).toString();
}

bool _isBitmapIconUrl(String url) {
  final lower = url.toLowerCase().split('?').first;
  return lower.endsWith('.png') ||
      lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.webp') ||
      lower.endsWith('.ico') ||
      lower.endsWith('.gif');
}

/// Finds a high-resolution bitmap favicon suitable for an Android home screen
/// shortcut (target ~192px). Scrapes the page for apple-touch-icon, sized
/// link[rel=icon] tags, and the web app manifest. Returns the URL of the
/// largest candidate; falls back to Google's 256px service for HTTPS hosts.
/// SVG icons are skipped because Android ShortcutInfoCompat requires a bitmap.
Future<String?> getHighResFaviconUrl(String siteUrl) async {
  if (_hdFaviconCache.containsKey(siteUrl)) {
    return _hdFaviconCache[siteUrl];
  }

  final uri = Uri.tryParse(siteUrl);
  if (uri == null || uri.host.isEmpty) {
    _hdFaviconCache[siteUrl] = null;
    return null;
  }

  int bestScore = 0;
  String? bestUrl;

  void consider(String url, int score) {
    if (!_isBitmapIconUrl(url)) return;
    if (score > bestScore) {
      bestScore = score;
      bestUrl = url;
    }
  }

  try {
    final response = await http
        .get(uri, headers: {'User-Agent': 'Mozilla/5.0'})
        .timeout(const Duration(seconds: 8));
    if (response.statusCode == 200) {
      final doc = html_parser.parse(response.body);
      final links = doc.querySelectorAll('link[rel]');
      String? manifestUrl;
      for (final link in links) {
        final rel = (link.attributes['rel'] ?? '').toLowerCase();
        final href = link.attributes['href'];
        if (href == null || href.isEmpty) continue;
        final resolved = _resolveUrl(uri, href);

        if (rel == 'manifest') {
          manifestUrl = resolved;
          continue;
        }

        // apple-touch-icon is commonly 180x180 — the best default bitmap.
        if (rel.contains('apple-touch-icon')) {
          final sizedScore = _parseSizes(link.attributes['sizes']);
          consider(resolved, sizedScore > 0 ? sizedScore : 180);
          continue;
        }

        if (rel == 'icon' || rel == 'shortcut icon' || rel.contains('fluid-icon')) {
          final sized = _parseSizes(link.attributes['sizes']);
          // Prefer tags with explicit sizes; otherwise assume modest 32px.
          consider(resolved, sized > 0 ? sized : 32);
        }
      }

      if (manifestUrl != null) {
        try {
          final manifestResp = await http
              .get(Uri.parse(manifestUrl), headers: {'User-Agent': 'Mozilla/5.0'})
              .timeout(const Duration(seconds: 5));
          if (manifestResp.statusCode == 200) {
            final manifestUri = Uri.parse(manifestUrl);
            final data = jsonDecode(manifestResp.body);
            if (data is Map && data['icons'] is List) {
              for (final icon in (data['icons'] as List)) {
                if (icon is! Map) continue;
                final src = icon['src'];
                if (src is! String || src.isEmpty) continue;
                final resolved = _resolveUrl(manifestUri, src);
                final sizesRaw = icon['sizes'];
                final score = _parseSizes(sizesRaw is String ? sizesRaw : null);
                consider(resolved, score > 0 ? score : 64);
              }
            }
          }
        } catch (e) {
          LogService.instance.log('Icon', 'HD: manifest fetch failed: $e');
        }
      }
    }
  } catch (e) {
    LogService.instance.log('Icon', 'HD: page fetch failed for $siteUrl: $e');
  }

  // If the page didn't yield anything good (< 96px), fall back to Google 256.
  if ((bestUrl == null || bestScore < 96) &&
      uri.scheme == 'https' &&
      !_isIpAddress(uri.host)) {
    final domain = _applyDomainSubstitution(uri.host);
    final google = 'https://www.google.com/s2/favicons?domain=$domain&sz=256';
    if (await _verifyIconUrl(google) && 256 > bestScore) {
      bestScore = 256;
      bestUrl = google;
    }
  }

  LogService.instance.log(
      'Icon', 'HD favicon for $siteUrl: $bestUrl (score: $bestScore)');
  _hdFaviconCache[siteUrl] = bestUrl;
  return bestUrl;
}

/// Clears the favicon cache
void clearFaviconCache() {
  _faviconCache.clear();
  _faviconQualityCache.clear();
  _verifiedUrls.clear();
  _svgContentCache.clear();
  _hdFaviconCache.clear();
}

/// Gets current queue stats (for debugging)
Map<String, int> getQueueStats() {
  return {
    'active': _activeRequests,
    'queued': _requestQueue.length,
  };
}
