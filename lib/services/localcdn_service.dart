import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// CDN URL pattern with named capture groups for library, version, and file.
class _CdnPattern {
  final RegExp pattern;
  final int libGroup;
  final int verGroup;
  final int fileGroup;
  /// Optional file suffix to append (e.g., for code.jquery.com pattern).
  final String? fileSuffix;

  const _CdnPattern({
    required this.pattern,
    required this.libGroup,
    required this.verGroup,
    required this.fileGroup,
    this.fileSuffix,
  });
}

/// LocalCDN service - intercepts CDN resource requests and serves them
/// from a local cache to prevent CDN providers from tracking users.
///
/// On first encounter of a CDN resource, the resource is downloaded and cached.
/// Subsequent requests for the same resource (even from different CDN providers)
/// are served from the local cache.
///
/// Works on Android via shouldInterceptRequest. On iOS/macOS, CDN requests
/// pass through normally (feature degrades gracefully).
class LocalCdnService {
  static LocalCdnService? _instance;
  static LocalCdnService get instance => _instance ??= LocalCdnService._();
  LocalCdnService._();

  /// CDN URL patterns that extract (library, version, file) from known CDN URLs.
  static final _cdnPatterns = [
    // cdnjs.cloudflare.com/ajax/libs/{lib}/{ver}/{file}
    _CdnPattern(
      pattern: RegExp(r'https?://cdnjs\.cloudflare\.com/ajax/libs/([^/]+)/([^/]+)/(.+?)(?:\?.*)?$'),
      libGroup: 1, verGroup: 2, fileGroup: 3,
    ),
    // cdn.jsdelivr.net/npm/{lib}@{ver}/{file}
    _CdnPattern(
      pattern: RegExp(r'https?://cdn\.jsdelivr\.net/npm/([^@/]+)@([^/]+)/(.+?)(?:\?.*)?$'),
      libGroup: 1, verGroup: 2, fileGroup: 3,
    ),
    // cdn.jsdelivr.net/gh/{user}/{lib}@{ver}/{file} (GitHub CDN)
    _CdnPattern(
      pattern: RegExp(r'https?://cdn\.jsdelivr\.net/gh/[^/]+/([^@/]+)@([^/]+)/(.+?)(?:\?.*)?$'),
      libGroup: 1, verGroup: 2, fileGroup: 3,
    ),
    // unpkg.com/{lib}@{ver}/{file}
    _CdnPattern(
      pattern: RegExp(r'https?://unpkg\.com/([^@/]+)@([^/]+)/(.+?)(?:\?.*)?$'),
      libGroup: 1, verGroup: 2, fileGroup: 3,
    ),
    // ajax.googleapis.com/ajax/libs/{lib}/{ver}/{file}
    _CdnPattern(
      pattern: RegExp(r'https?://ajax\.googleapis\.com/ajax/libs/([^/]+)/([^/]+)/(.+?)(?:\?.*)?$'),
      libGroup: 1, verGroup: 2, fileGroup: 3,
    ),
    // code.jquery.com/jquery-{ver}.min.js or jquery-{ver}.js
    _CdnPattern(
      pattern: RegExp(r'https?://code\.jquery\.com/(jquery)-([0-9.]+)(\.min\.js|\.js|\.slim\.min\.js|\.slim\.js)(?:\?.*)?$'),
      libGroup: 1, verGroup: 2, fileGroup: 3,
    ),
    // code.jquery.com/ui/{ver}/jquery-ui.min.js
    _CdnPattern(
      pattern: RegExp(r'https?://code\.jquery\.com/(ui)/([0-9.]+)/(.+?)(?:\?.*)?$'),
      libGroup: 1, verGroup: 2, fileGroup: 3,
    ),
    // stackpath.bootstrapcdn.com/bootstrap/{ver}/{file}
    _CdnPattern(
      pattern: RegExp(r'https?://stackpath\.bootstrapcdn\.com/(bootstrap)/([^/]+)/(.+?)(?:\?.*)?$'),
      libGroup: 1, verGroup: 2, fileGroup: 3,
    ),
    // maxcdn.bootstrapcdn.com/bootstrap/{ver}/{file}
    _CdnPattern(
      pattern: RegExp(r'https?://maxcdn\.bootstrapcdn\.com/(bootstrap)/([^/]+)/(.+?)(?:\?.*)?$'),
      libGroup: 1, verGroup: 2, fileGroup: 3,
    ),
    // cdn.bootcss.com/{lib}/{ver}/{file} (Chinese cdnjs mirror)
    _CdnPattern(
      pattern: RegExp(r'https?://cdn\.bootcss\.com/([^/]+)/([^/]+)/(.+?)(?:\?.*)?$'),
      libGroup: 1, verGroup: 2, fileGroup: 3,
    ),
    // cdn.bootcdn.net/ajax/libs/{lib}/{ver}/{file}
    _CdnPattern(
      pattern: RegExp(r'https?://cdn\.bootcdn\.net/ajax/libs/([^/]+)/([^/]+)/(.+?)(?:\?.*)?$'),
      libGroup: 1, verGroup: 2, fileGroup: 3,
    ),
    // cdn.staticfile.org/{lib}/{ver}/{file} (Chinese CDN)
    _CdnPattern(
      pattern: RegExp(r'https?://cdn\.staticfile\.org/([^/]+)/([^/]+)/(.+?)(?:\?.*)?$'),
      libGroup: 1, verGroup: 2, fileGroup: 3,
    ),
    // lib.sinaapp.com/js/{lib}/{ver}/{file} (Sina CDN)
    _CdnPattern(
      pattern: RegExp(r'https?://lib\.sinaapp\.com/js/([^/]+)/([^/]+)/(.+?)(?:\?.*)?$'),
      libGroup: 1, verGroup: 2, fileGroup: 3,
    ),
    // libs.baidu.com/jquery/{ver}/{file}
    _CdnPattern(
      pattern: RegExp(r'https?://libs\.baidu\.com/([^/]+)/([^/]+)/(.+?)(?:\?.*)?$'),
      libGroup: 1, verGroup: 2, fileGroup: 3,
    ),
    // pagecdn.io/lib/{lib}/{ver}/{file}
    _CdnPattern(
      pattern: RegExp(r'https?://pagecdn\.io/lib/([^/]+)/([^/]+)/(.+?)(?:\?.*)?$'),
      libGroup: 1, verGroup: 2, fileGroup: 3,
    ),
  ];

  /// Content type mapping by file extension.
  static const _contentTypes = <String, String>{
    '.js': 'application/javascript',
    '.mjs': 'application/javascript',
    '.css': 'text/css',
    '.json': 'application/json',
    '.woff': 'font/woff',
    '.woff2': 'font/woff2',
    '.ttf': 'font/ttf',
    '.otf': 'font/otf',
    '.eot': 'application/vnd.ms-fontobject',
    '.svg': 'image/svg+xml',
    '.map': 'application/json',
  };

  /// Cached resource index: cache key -> file path on disk.
  final Map<String, String> _cache = {};
  String? _cacheDir;
  bool _initialized = false;

  /// Whether the service has been initialized.
  bool get isInitialized => _initialized;

  /// Whether any resources are cached.
  bool get hasCache => _cache.isNotEmpty;

  /// Number of cached resources.
  int get resourceCount => _cache.length;

  /// Total size of cached resources in bytes.
  Future<int> get cacheSize async {
    int total = 0;
    for (final path in _cache.values) {
      try {
        final file = File(path);
        if (await file.exists()) {
          total += await file.length();
        }
      } catch (_) {}
    }
    return total;
  }

  /// Initialize the service - load cache index from disk.
  Future<void> initialize() async {
    if (_initialized) return;
    final dir = await getApplicationDocumentsDirectory();
    _cacheDir = '${dir.path}/localcdn_cache';
    await Directory(_cacheDir!).create(recursive: true);
    await _loadCacheIndex();
    _initialized = true;
  }

  /// Extract a canonical cache key from a CDN URL.
  /// Returns null if the URL doesn't match any known CDN pattern.
  String? getCacheKey(String url) {
    for (final cdn in _cdnPatterns) {
      final match = cdn.pattern.firstMatch(url);
      if (match != null) {
        final lib = match.group(cdn.libGroup)!.toLowerCase();
        final ver = match.group(cdn.verGroup)!;
        final file = match.group(cdn.fileGroup)!;
        return '$lib/$ver/$file';
      }
    }
    return null;
  }

  /// Check if a URL is a CDN URL that can be intercepted.
  bool isCdnUrl(String url) => getCacheKey(url) != null;

  /// Check if a CDN resource is already cached.
  bool isCached(String url) {
    final key = getCacheKey(url);
    return key != null && _cache.containsKey(key);
  }

  /// Get cached resource content for a CDN URL.
  /// Returns null if not cached or if the URL doesn't match a CDN pattern.
  Future<Uint8List?> getResource(String url) async {
    final key = getCacheKey(url);
    if (key == null) return null;

    final filePath = _cache[key];
    if (filePath == null) return null;

    try {
      final file = File(filePath);
      if (await file.exists()) {
        return await file.readAsBytes();
      }
      // File missing - remove from index
      _cache.remove(key);
      await _saveCacheIndex();
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Get the content type for a URL based on its file extension.
  String getContentType(String url) {
    // Strip query string
    final path = url.contains('?') ? url.substring(0, url.indexOf('?')) : url;
    for (final entry in _contentTypes.entries) {
      if (path.endsWith(entry.key)) {
        return entry.value;
      }
    }
    return 'application/octet-stream';
  }

  /// Download a CDN resource and cache it locally.
  /// Returns the cached content on success, null on failure.
  Future<Uint8List?> cacheResource(String url) async {
    if (!_initialized) return null;

    final key = getCacheKey(url);
    if (key == null) return null;

    // Already cached
    if (_cache.containsKey(key)) {
      return getResource(url);
    }

    try {
      final response = await http.get(Uri.parse(url)).timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode != 200) return null;

      // Save to disk with a safe filename
      final safeFilename = key
          .replaceAll('/', '__')
          .replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      final filePath = '$_cacheDir/$safeFilename';
      await File(filePath).writeAsBytes(response.bodyBytes);

      // Update cache index
      _cache[key] = filePath;
      await _saveCacheIndex();

      return response.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  /// Try to get a resource from cache, falling back to download-and-cache.
  /// This is the primary method used by the webview interceptor.
  Future<Uint8List?> getOrCacheResource(String url) async {
    // Try cache first
    final cached = await getResource(url);
    if (cached != null) return cached;

    // Download and cache
    return cacheResource(url);
  }

  /// Clear all cached resources.
  Future<void> clearCache() async {
    if (!_initialized) return;

    try {
      final dir = Directory(_cacheDir!);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
        await dir.create(recursive: true);
      }
    } catch (_) {}

    _cache.clear();
    await _saveCacheIndex();
  }

  /// Load cache index from SharedPreferences.
  Future<void> _loadCacheIndex() async {
    final prefs = await SharedPreferences.getInstance();
    final indexJson = prefs.getString('localcdn_cache_index');
    if (indexJson != null) {
      try {
        final Map<String, dynamic> index = jsonDecode(indexJson);
        _cache.clear();
        for (final entry in index.entries) {
          // Verify file exists before adding to index
          if (await File(entry.value as String).exists()) {
            _cache[entry.key] = entry.value as String;
          }
        }
        // Clean up index if any files were missing
        if (_cache.length != index.length) {
          await _saveCacheIndex();
        }
      } catch (_) {
        _cache.clear();
      }
    }
  }

  /// Save cache index to SharedPreferences.
  Future<void> _saveCacheIndex() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('localcdn_cache_index', jsonEncode(_cache));
  }

  /// Format cache size as human-readable string.
  static String formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
