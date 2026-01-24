import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as html_dom;

/// Icon Service - Handles favicon fetching from multiple sources with quality scoring
///
/// This service provides intelligent icon fetching with the following features:
/// - Parallel fetching from multiple sources (Google, HTML parsing, DuckDuckGo, favicon.ico)
/// - Quality-based selection (prefers colored high-res icons over monochrome)
/// - SVG color detection (distinguishes colored SVGs from monochrome masks)
/// - Domain substitution rules (e.g., gmail.com → mail.google.com)
/// - Caching to avoid repeated requests

// Cache for favicon URLs to avoid repeated requests
final Map<String, String?> _faviconCache = {};

// Domain substitution rules for better icon results
// Some services have different domains for their main site vs their icon-rich pages
const Map<String, String> _domainSubstitutions = {
  'gmail.com': 'mail.google.com',
  // Add more substitutions here as needed
  // 'example.com': 'icons.example.com',
};

// Apply domain substitution rules
String _applyDomainSubstitution(String domain) {
  return _domainSubstitutions[domain] ?? domain;
}

// Icon candidate with quality scoring
class _IconCandidate {
  final String url;
  final int quality;
  final bool verified; // Whether the URL has already been verified as accessible

  _IconCandidate(this.url, this.quality, {this.verified = false});
}

// Helper: Verify icon URL is accessible
Future<bool> _verifyIconUrl(String iconUrl) async {
  try {
    final iconResponse = await http.head(Uri.parse(iconUrl)).timeout(
      Duration(seconds: 2),
    );
    return iconResponse.statusCode == 200;
  } catch (e) {
    if (kDebugMode) {
      print('[Icon] Failed to verify $iconUrl: $e');
    }
    return false;
  }
}

// Helper: Resolve relative URLs to absolute
String _resolveIconUrl(String href, String scheme, String baseUrl) {
  if (href.startsWith('http://') || href.startsWith('https://')) {
    return href;
  } else if (href.startsWith('//')) {
    return '$scheme:$href';
  } else if (href.startsWith('/')) {
    return '$baseUrl$href';
  } else {
    return '$baseUrl/$href';
  }
}

// Helper: Check if SVG is monochrome (returns true if it's a colored SVG)
Future<bool> _isSvgColored(String svgUrl) async {
  try {
    final response = await http.get(Uri.parse(svgUrl)).timeout(
      Duration(seconds: 2),
    );

    if (response.statusCode != 200) {
      return false; // Assume monochrome if we can't fetch
    }

    final svgContent = response.body.toLowerCase();

    // Look for color indicators (excluding black/white/gray)
    // Check for hex colors that aren't black/white/gray
    final colorPattern = RegExp(r'fill\s*=\s*["\x27]#([0-9a-f]{3,6})["\x27]|stroke\s*=\s*["\x27]#([0-9a-f]{3,6})["\x27]');
    final matches = colorPattern.allMatches(svgContent);

    for (var match in matches) {
      final color = (match.group(1) ?? match.group(2) ?? '').toLowerCase();
      // Skip black, white, and gray colors
      if (color != '000' && color != '000000' &&
          color != 'fff' && color != 'ffffff' &&
          color != '333' && color != '666' && color != '999' &&
          color != 'ccc' && color != 'eee') {
        if (kDebugMode) {
          print('[Icon] Found colored SVG with color #$color: $svgUrl');
        }
        return true; // Found a real color!
      }
    }

    // Check for rgb/hsl colors
    if (svgContent.contains('rgb(') || svgContent.contains('hsl(')) {
      if (kDebugMode) {
        print('[Icon] Found colored SVG with rgb/hsl: $svgUrl');
      }
      return true;
    }

    // If we only find currentColor or no colors, it's a monochrome mask
    if (kDebugMode) {
      print('[Icon] SVG appears monochrome: $svgUrl');
    }
    return false;
  } catch (e) {
    if (kDebugMode) {
      print('[Icon] Failed to check SVG color: $e');
    }
    return false; // Assume monochrome on error
  }
}

// Helper: Try Google Favicon service
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

// Helper: Extract icons from HTML
Future<List<_IconCandidate>> _extractIconsFromHtml(
  String url,
  String scheme,
  String baseUrl,
) async {
  List<_IconCandidate> candidates = [];

  try {
    final pageResponse = await http.get(Uri.parse(url)).timeout(
      Duration(seconds: 3),
      onTimeout: () => throw TimeoutException('Page fetch timeout'),
    );

    if (pageResponse.statusCode == 200) {
      html_dom.Document document = html_parser.parse(pageResponse.body);

      // Look for favicon in <link> tags
      List<String> iconRels = ['icon'];

      for (String rel in iconRels) {
        var linkElements = document.querySelectorAll('link[rel*="$rel"]');
        for (var link in linkElements) {
          String? href = link.attributes['href'];
          String? type = link.attributes['type'];
          String? sizes = link.attributes['sizes'];

          if (href != null && href.isNotEmpty) {
            String iconUrl = _resolveIconUrl(href, scheme, baseUrl);
            int quality = 16; // default for unknown size

            // Check if it's an SVG icon
            bool isSvg = type == 'image/svg+xml' || href.toLowerCase().endsWith('.svg');
            if (isSvg) {
              // SVGs need color checking - temporarily mark with negative quality
              // We'll check and update quality later
              quality = -1; // Marker for "needs SVG color check"
            } else if (sizes != null) {
              // Parse sizes attribute (e.g., "128x128", "any")
              if (sizes.contains('256')) {
                quality = 256;
              } else if (sizes.contains('128') || sizes.contains('any')) {
                quality = 128;
              }
            }

            candidates.add(_IconCandidate(iconUrl, quality));
          }
        }
      }

      if (kDebugMode && candidates.isNotEmpty) {
        print('[Icon] Found ${candidates.length} icon(s) in HTML for $url');
      }
    }
  } catch (e) {
    if (kDebugMode) {
      print('[Icon] HTML parsing failed for $url: $e');
    }
  }

  return candidates;
}

/// Fetches the best quality favicon for a given URL
///
/// Quality scoring:
/// - 1000: Colored SVG icons (scale-invariant, best quality!)
/// - 256: Google 256px (colored, high-res)
/// - 128: Google 128px, HTML high-res icons (colored)
/// - 64: DuckDuckGo (colored)
/// - 50: Monochrome SVG icons (black/white masks)
/// - 32: /favicon.ico fallback
/// - 16: HTML unknown size icons
/// - -1: SVG that needs color checking (temporary, updated dynamically)
///
/// The function tries all sources in parallel and picks the best quality icon.
/// Results are cached to avoid repeated requests.
Future<String?> getFaviconUrl(String url) async {
  // Check cache first - return immediately if cached
  if (_faviconCache.containsKey(url)) {
    if (kDebugMode) {
      print('[Icon] Using cached icon for $url');
    }
    return _faviconCache[url];
  }

  Uri? uri = Uri.tryParse(url);
  if (uri == null) {
    _faviconCache[url] = null;
    return null;
  }

  String scheme = uri.scheme;
  String host = uri.host;
  int? port = uri.hasPort ? uri.port : null;
  String domain = _applyDomainSubstitution(host);

  if (scheme.isEmpty || host.isEmpty) {
    _faviconCache[url] = null;
    return null;
  }

  String baseUrl = port != null ? '$scheme://$host:$port' : '$scheme://$host';

  if (kDebugMode) {
    print('[Icon] Fetching icon for $url (domain: $domain)');
  }

  // Try all sources IN PARALLEL to avoid UI freezing
  final results = await Future.wait([
    // Google 256px (already verified by _tryGoogleFavicon)
    _tryGoogleFavicon(domain, 256).then((url) =>
      url != null ? _IconCandidate(url, 256, verified: true) : null
    ),
    // Google 128px (already verified by _tryGoogleFavicon)
    _tryGoogleFavicon(domain, 128).then((url) =>
      url != null ? _IconCandidate(url, 128, verified: true) : null
    ),
    // HTML parsing for native icons (NOT verified yet)
    _extractIconsFromHtml(url, scheme, baseUrl),
    // DuckDuckGo (verified here)
    Future(() async {
      try {
        final ddg = 'https://icons.duckduckgo.com/ip3/$domain.ico';
        if (await _verifyIconUrl(ddg)) {
          if (kDebugMode) {
            print('[Icon] Found DuckDuckGo icon for $domain');
          }
          return _IconCandidate(ddg, 64, verified: true);
        }
      } catch (e) {
        if (kDebugMode) {
          print('[Icon] DuckDuckGo failed for $domain: $e');
        }
      }
      return null;
    }),
    // /favicon.ico at root (verified here)
    Future(() async {
      try {
        final faviconIco = '$baseUrl/favicon.ico';
        if (await _verifyIconUrl(faviconIco)) {
          if (kDebugMode) {
            print('[Icon] Found /favicon.ico for $url');
          }
          return _IconCandidate(faviconIco, 32, verified: true);
        }
      } catch (e) {
        if (kDebugMode) {
          print('[Icon] /favicon.ico failed for $url: $e');
        }
      }
      return null;
    }),
  ]);

  // Collect all candidates from parallel results
  List<_IconCandidate> candidates = [];
  for (var result in results) {
    if (result is _IconCandidate) {
      candidates.add(result);
    } else if (result is List<_IconCandidate>) {
      candidates.addAll(result);
    }
  }

  // Check SVG icons for color (quality = -1 means needs checking)
  List<_IconCandidate> finalCandidates = [];
  for (var candidate in candidates) {
    if (candidate.quality == -1) {
      // This is an SVG that needs color checking
      final isColored = await _isSvgColored(candidate.url);
      final svgQuality = isColored ? 1000 : 50; // Colored SVG = best, monochrome = low
      finalCandidates.add(_IconCandidate(candidate.url, svgQuality, verified: candidate.verified));
    } else {
      finalCandidates.add(candidate);
    }
  }

  // Pick the best quality icon from all sources
  if (finalCandidates.isEmpty) {
    if (kDebugMode) {
      print('[Icon] No icon found for $url');
    }
    _faviconCache[url] = null;
    return null;
  }

  // Sort by quality (highest first)
  finalCandidates.sort((a, b) => b.quality.compareTo(a.quality));

  if (kDebugMode) {
    print('[Icon] Found ${finalCandidates.length} candidate(s) for $url');
  }

  // Return the best candidate, verifying only if needed
  for (var candidate in finalCandidates) {
    // Skip verification if already verified
    if (candidate.verified) {
      if (kDebugMode) {
        print('[Icon] Using pre-verified icon with quality ${candidate.quality} for $url: ${candidate.url}');
      }
      _faviconCache[url] = candidate.url;
      return candidate.url;
    }

    // Verify unverified candidates (e.g., from HTML)
    if (await _verifyIconUrl(candidate.url)) {
      if (kDebugMode) {
        print('[Icon] Using verified icon with quality ${candidate.quality} for $url: ${candidate.url}');
      }
      _faviconCache[url] = candidate.url;
      return candidate.url;
    }
  }

  if (kDebugMode) {
    print('[Icon] All candidates failed verification for $url');
  }
  _faviconCache[url] = null;
  return null;
}
