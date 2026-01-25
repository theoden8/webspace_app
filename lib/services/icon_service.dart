import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:favicon/favicon.dart';

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

// Helper: Check if SVG is monochrome (returns true if it's a colored SVG)
Future<bool> _isSvgColored(String svgUrl) async {
  try {
    final response = await http.get(Uri.parse(svgUrl)).timeout(
      Duration(seconds: 2),
    );
    if (response.statusCode != 200) return false;

    final svgContent = response.body.toLowerCase();

    // Check for hex colors in attributes (fill="..." stroke="...")
    final attrColorPattern = RegExp(
        r'(?:fill|stroke)\s*=\s*["\x27]#([0-9a-f]{3,6})["\x27]');
    final attrMatches = attrColorPattern.allMatches(svgContent);

    for (var match in attrMatches) {
      final color = match.group(1)!.toLowerCase();
      if (_isRealColor(color)) {
        if (kDebugMode) {
          print('[Icon] Found colored SVG with attr color #$color: $svgUrl');
        }
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
          if (kDebugMode) {
            print('[Icon] Found colored SVG with CSS color #$color: $svgUrl');
          }
          return true;
        }
      }

      // Check for rgb/hsl
      if (withoutMedia.contains('rgb(') || withoutMedia.contains('hsl(')) {
        if (kDebugMode) {
          print('[Icon] Found colored SVG with rgb/hsl: $svgUrl');
        }
        return true;
      }
    }

    if (kDebugMode) {
      print('[Icon] SVG appears monochrome: $svgUrl');
    }
    return false;
  } catch (e) {
    if (kDebugMode) {
      print('[Icon] Failed to check SVG color: $e');
    }
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
  if (kDebugMode) {
    print('[Icon] Favicons: ${favicons.map((f) => '${f.url} (width: ${f.width}, height: ${f.height})').join(', ')}');
  }
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
    if (kDebugMode) {
      print('[Icon] Using cached icon for $url');
    }
    return _faviconCache[url];
  }

  // Queue management to limit concurrent requests
  if (_activeRequests >= _maxConcurrentRequests) {
    if (kDebugMode) {
      print('[Icon] Queueing request for $url (active: $_activeRequests)');
    }
    final completer = Completer<void>();
    _requestQueue.add(completer);
    await completer.future;
  }

  _activeRequests++;
  if (kDebugMode) {
    print('[Icon] Starting request for $url (active: $_activeRequests, queued: ${_requestQueue.length})');
  }

  try {
    return await _fetchFaviconUrlInternal(url);
  } finally {
    _activeRequests--;
    if (kDebugMode) {
      print('[Icon] Finished request for $url (active: $_activeRequests, queued: ${_requestQueue.length})');
    }

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
    if (kDebugMode) {
      print('[Icon] Stream: Using cached icon for $url (quality: $cachedQuality)');
    }
    yield IconUpdate(cachedUrl, cachedQuality, isFinal: true);
    return;
  }

  // Check if we should use public icon services (skip for http:// and IP addresses)
  final usePublicServices = _shouldUsePublicIconServices(uri);

  if (kDebugMode) {
    print('[Icon] Stream: Starting progressive fetch for $url (domain: $domain, usePublicServices: $usePublicServices)');
  }

  // Phase 1 & 2: Public icon services (only for HTTPS + non-IP addresses)
  if (usePublicServices) {
    // Phase 1: Quick sources (DuckDuckGo) - typically responds fast
    final ddgResult = await _tryDuckDuckGo(domain);
    if (ddgResult != null) {
      bestUrl = ddgResult;
      bestQuality = 64;
      if (kDebugMode) {
        print('[Icon] Stream: Emitting DuckDuckGo icon (quality: 64)');
      }
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
      if (kDebugMode) {
        print('[Icon] Stream: Emitting Google 128px icon');
      }
      yield IconUpdate(googleResults[0]!, 128);
    }

    // Emit Google 256px if better
    if (googleResults[1] != null && 256 > bestQuality) {
      bestUrl = googleResults[1];
      bestQuality = 256;
      if (kDebugMode) {
        print('[Icon] Stream: Emitting Google 256px icon');
      }
      yield IconUpdate(googleResults[1]!, 256);
    }
  }

  // Phase 3: Favicon package (slowest but can find high-res site-specific icons)
  final faviconResult = await _tryFaviconPackage(url);
  if (faviconResult != null && faviconResult.quality > bestQuality) {
    bestUrl = faviconResult.url;
    bestQuality = faviconResult.quality;
    if (kDebugMode) {
      print('[Icon] Stream: Emitting favicon package icon (quality: ${faviconResult.quality})');
    }
    yield IconUpdate(faviconResult.url, faviconResult.quality, isFinal: true);
  } else if (bestUrl != null) {
    // Re-emit best as final
    yield IconUpdate(bestUrl, bestQuality, isFinal: true);
  }

  // Cache the best result
  _faviconCache[url] = bestUrl;
  _faviconQualityCache[url] = bestQuality;

  if (kDebugMode) {
    print('[Icon] Stream: Completed for $url, best quality: $bestQuality');
  }
}

Future<String?> _fetchFaviconUrlInternal(String url) async {
  Uri? uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) {
    _faviconCache[url] = null;
    return null;
  }

  String domain = _applyDomainSubstitution(uri.host);
  final usePublicServices = _shouldUsePublicIconServices(uri);

  if (kDebugMode) {
    print('[Icon] Fetching icon for $url (domain: $domain, usePublicServices: $usePublicServices)');
  }

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
    if (kDebugMode) {
      print('[Icon] Error fetching icons for $url: $e');
    }
  }

  if (candidates.isEmpty) {
    _faviconCache[url] = null;
    return null;
  }

  // Sort by quality (highest first)
  candidates.sort((a, b) => b.quality.compareTo(a.quality));

  if (kDebugMode) {
    print('[Icon] Candidates: ${candidates.map((c) => '${c.url} (quality: ${c.quality})').join(', ')}');
  }

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
      if (kDebugMode) {
        print('[Icon] Found Google favicon at ${size}px for $domain');
      }
      return googleUrl;
    }
  } catch (e) {
    if (kDebugMode) {
      print('[Icon] Google ${size}px failed for $domain: $e');
    }
  }
  return null;
}

Future<String?> _tryDuckDuckGo(String domain) async {
  try {
    final ddgUrl = 'https://icons.duckduckgo.com/ip3/$domain.ico';
    if (await _verifyIconUrl(ddgUrl)) {
      if (kDebugMode) {
        print('[Icon] Found DuckDuckGo favicon for $domain');
      }
      return ddgUrl;
    }
  } catch (e) {
    if (kDebugMode) {
      print('[Icon] DuckDuckGo failed for $domain: $e');
    }
  }
  return null;
}

Future<_IconCandidate?> _tryFaviconPackage(String url) async {
  try {
    final favicons = await FaviconFinder.getAll(url).timeout(Duration(seconds: 15));
    if (favicons.isEmpty) return null;

    if (kDebugMode) {
      print('[Icon] Favicons: ${favicons.map((f) => '${f.url} (width: ${f.width}, height: ${f.height})').join(', ')}');
    }

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

      if (kDebugMode) {
        print('[Icon] Found favicon via package for $url (quality: $quality) ${best.url}');
      }
      return _IconCandidate(best.url, quality);
    }
  } catch (e) {
    if (kDebugMode) {
      print('[Icon] FaviconFinder failed for $url: $e');
    }
  }
  return null;
}

/// Clears the favicon cache
void clearFaviconCache() {
  _faviconCache.clear();
  _faviconQualityCache.clear();
  _verifiedUrls.clear();
}

/// Gets current queue stats (for debugging)
Map<String, int> getQueueStats() {
  return {
    'active': _activeRequests,
    'queued': _requestQueue.length,
  };
}
