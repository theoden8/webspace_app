import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/log_service.dart';

/// CDN URL pattern with named capture groups for library, version, and file.
class _CdnPattern {
  final RegExp pattern;
  final int libGroup;
  final int verGroup;
  final int fileGroup;

  const _CdnPattern({
    required this.pattern,
    required this.libGroup,
    required this.verGroup,
    required this.fileGroup,
  });
}

/// LocalCDN service - intercepts CDN resource requests and serves them
/// from a local cache to prevent CDN providers from tracking users.
///
/// Resources are always downloaded from cdnjs.cloudflare.com (a single trusted
/// source), never from the original CDN that was requested. This means the
/// original CDN never sees the request.
///
/// Two modes of operation:
/// 1. **Pre-download**: User downloads popular resources via app settings
///    (like DNS blocklist download). These are immediately available.
/// 2. **On-demand**: When a CDN URL is intercepted that isn't pre-downloaded,
///    the resource is fetched from cdnjs, cached, and served.
///
/// Works on Android via shouldInterceptRequest. On iOS/macOS, CDN requests
/// pass through normally (feature degrades gracefully).
class LocalCdnService {
  static LocalCdnService? _instance;
  static LocalCdnService get instance => _instance ??= LocalCdnService._();
  LocalCdnService._();

  static const String _lastUpdatedKey = 'localcdn_last_updated';

  /// The single trusted CDN source for downloading resources.
  /// All resources are fetched from cdnjs regardless of which CDN originally
  /// hosted them. This means only cdnjs sees any request (once per resource).
  static const String _preferredCdnBase =
      'https://cdnjs.cloudflare.com/ajax/libs';

  /// CDN URL patterns that extract (library, version, file) from known CDN URLs.
  static final _cdnPatterns = [
    // cdnjs.cloudflare.com/ajax/libs/{lib}/{ver}/{file}
    _CdnPattern(
      pattern: RegExp(
          r'https?://cdnjs\.cloudflare\.com/ajax/libs/([^/]+)/([^/]+)/(.+?)(?:\?.*)?$'),
      libGroup: 1, verGroup: 2, fileGroup: 3,
    ),
    // cdn.jsdelivr.net/npm/{lib}@{ver}/{file}
    _CdnPattern(
      pattern: RegExp(
          r'https?://cdn\.jsdelivr\.net/npm/([^@/]+)@([^/]+)/(.+?)(?:\?.*)?$'),
      libGroup: 1, verGroup: 2, fileGroup: 3,
    ),
    // cdn.jsdelivr.net/gh/{user}/{lib}@{ver}/{file} (GitHub CDN)
    _CdnPattern(
      pattern: RegExp(
          r'https?://cdn\.jsdelivr\.net/gh/[^/]+/([^@/]+)@([^/]+)/(.+?)(?:\?.*)?$'),
      libGroup: 1, verGroup: 2, fileGroup: 3,
    ),
    // unpkg.com/{lib}@{ver}/{file}
    _CdnPattern(
      pattern: RegExp(
          r'https?://unpkg\.com/([^@/]+)@([^/]+)/(.+?)(?:\?.*)?$'),
      libGroup: 1, verGroup: 2, fileGroup: 3,
    ),
    // ajax.googleapis.com/ajax/libs/{lib}/{ver}/{file}
    _CdnPattern(
      pattern: RegExp(
          r'https?://ajax\.googleapis\.com/ajax/libs/([^/]+)/([^/]+)/(.+?)(?:\?.*)?$'),
      libGroup: 1, verGroup: 2, fileGroup: 3,
    ),
    // code.jquery.com/jquery-{ver}.min.js or jquery-{ver}.js
    _CdnPattern(
      pattern: RegExp(
          r'https?://code\.jquery\.com/(jquery)-([0-9.]+)(\.min\.js|\.js|\.slim\.min\.js|\.slim\.js)(?:\?.*)?$'),
      libGroup: 1, verGroup: 2, fileGroup: 3,
    ),
    // code.jquery.com/ui/{ver}/jquery-ui.min.js
    _CdnPattern(
      pattern: RegExp(
          r'https?://code\.jquery\.com/(ui)/([0-9.]+)/(.+?)(?:\?.*)?$'),
      libGroup: 1, verGroup: 2, fileGroup: 3,
    ),
    // stackpath.bootstrapcdn.com/bootstrap/{ver}/{file}
    _CdnPattern(
      pattern: RegExp(
          r'https?://stackpath\.bootstrapcdn\.com/(bootstrap)/([^/]+)/(.+?)(?:\?.*)?$'),
      libGroup: 1, verGroup: 2, fileGroup: 3,
    ),
    // maxcdn.bootstrapcdn.com/bootstrap/{ver}/{file}
    _CdnPattern(
      pattern: RegExp(
          r'https?://maxcdn\.bootstrapcdn\.com/(bootstrap)/([^/]+)/(.+?)(?:\?.*)?$'),
      libGroup: 1, verGroup: 2, fileGroup: 3,
    ),
    // cdn.bootcss.com/{lib}/{ver}/{file} (Chinese cdnjs mirror)
    _CdnPattern(
      pattern: RegExp(
          r'https?://cdn\.bootcss\.com/([^/]+)/([^/]+)/(.+?)(?:\?.*)?$'),
      libGroup: 1, verGroup: 2, fileGroup: 3,
    ),
    // cdn.bootcdn.net/ajax/libs/{lib}/{ver}/{file}
    _CdnPattern(
      pattern: RegExp(
          r'https?://cdn\.bootcdn\.net/ajax/libs/([^/]+)/([^/]+)/(.+?)(?:\?.*)?$'),
      libGroup: 1, verGroup: 2, fileGroup: 3,
    ),
    // cdn.staticfile.org/{lib}/{ver}/{file} (Chinese CDN)
    _CdnPattern(
      pattern: RegExp(
          r'https?://cdn\.staticfile\.org/([^/]+)/([^/]+)/(.+?)(?:\?.*)?$'),
      libGroup: 1, verGroup: 2, fileGroup: 3,
    ),
    // lib.sinaapp.com/js/{lib}/{ver}/{file} (Sina CDN)
    _CdnPattern(
      pattern: RegExp(
          r'https?://lib\.sinaapp\.com/js/([^/]+)/([^/]+)/(.+?)(?:\?.*)?$'),
      libGroup: 1, verGroup: 2, fileGroup: 3,
    ),
    // libs.baidu.com/jquery/{ver}/{file}
    _CdnPattern(
      pattern: RegExp(
          r'https?://libs\.baidu\.com/([^/]+)/([^/]+)/(.+?)(?:\?.*)?$'),
      libGroup: 1, verGroup: 2, fileGroup: 3,
    ),
    // pagecdn.io/lib/{lib}/{ver}/{file}
    _CdnPattern(
      pattern: RegExp(
          r'https?://pagecdn\.io/lib/([^/]+)/([^/]+)/(.+?)(?:\?.*)?$'),
      libGroup: 1, verGroup: 2, fileGroup: 3,
    ),
  ];

  /// Popular resources to pre-download. Each entry is (library, version, file)
  /// as they appear on cdnjs.cloudflare.com.
  /// These are the most commonly encountered CDN resources across the web.
  static const _popularResources = [
    // jQuery
    ('jquery', '3.7.1', 'jquery.min.js'),
    ('jquery', '3.6.0', 'jquery.min.js'),
    ('jquery', '3.5.1', 'jquery.min.js'),
    ('jquery', '3.4.1', 'jquery.min.js'),
    ('jquery', '3.3.1', 'jquery.min.js'),
    ('jquery', '2.2.4', 'jquery.min.js'),
    ('jquery', '2.1.4', 'jquery.min.js'),
    ('jquery', '1.12.4', 'jquery.min.js'),

    // Bootstrap CSS + JS
    ('twitter-bootstrap', '5.3.3', 'js/bootstrap.bundle.min.js'),
    ('twitter-bootstrap', '5.3.3', 'css/bootstrap.min.css'),
    ('twitter-bootstrap', '5.3.2', 'js/bootstrap.bundle.min.js'),
    ('twitter-bootstrap', '5.3.2', 'css/bootstrap.min.css'),
    ('twitter-bootstrap', '5.2.3', 'js/bootstrap.bundle.min.js'),
    ('twitter-bootstrap', '5.2.3', 'css/bootstrap.min.css'),
    ('twitter-bootstrap', '5.1.3', 'js/bootstrap.bundle.min.js'),
    ('twitter-bootstrap', '5.1.3', 'css/bootstrap.min.css'),
    ('twitter-bootstrap', '4.6.2', 'js/bootstrap.bundle.min.js'),
    ('twitter-bootstrap', '4.6.2', 'css/bootstrap.min.css'),
    ('twitter-bootstrap', '4.5.2', 'js/bootstrap.bundle.min.js'),
    ('twitter-bootstrap', '4.5.2', 'css/bootstrap.min.css'),
    ('twitter-bootstrap', '3.4.1', 'js/bootstrap.min.js'),
    ('twitter-bootstrap', '3.4.1', 'css/bootstrap.min.css'),
    ('twitter-bootstrap', '3.3.7', 'js/bootstrap.min.js'),
    ('twitter-bootstrap', '3.3.7', 'css/bootstrap.min.css'),

    // Popper.js (Bootstrap dependency)
    ('popper.js', '2.11.8', 'umd/popper.min.js'),
    ('popper.js', '2.11.6', 'umd/popper.min.js'),
    ('popper.js', '1.16.1', 'umd/popper.min.js'),

    // Font Awesome
    ('font-awesome', '6.5.1', 'css/all.min.css'),
    ('font-awesome', '6.4.2', 'css/all.min.css'),
    ('font-awesome', '5.15.4', 'css/all.min.css'),
    ('font-awesome', '4.7.0', 'css/font-awesome.min.css'),

    // Lodash
    ('lodash.js', '4.17.21', 'lodash.min.js'),

    // Moment.js
    ('moment.js', '2.29.4', 'moment.min.js'),
    ('moment.js', '2.30.1', 'moment.min.js'),

    // Axios
    ('axios', '1.6.7', 'axios.min.js'),
    ('axios', '1.6.2', 'axios.min.js'),
    ('axios', '0.21.4', 'axios.min.js'),

    // Animate.css
    ('animate.css', '4.1.1', 'animate.min.css'),

    // Modernizr
    ('modernizr', '2.8.3', 'modernizr.min.js'),

    // Underscore.js
    ('underscore.js', '1.13.6', 'underscore-min.js'),

    // Backbone.js
    ('backbone.js', '1.6.0', 'backbone-min.js'),

    // D3.js
    ('d3', '7.9.0', 'd3.min.js'),
    ('d3', '7.8.5', 'd3.min.js'),

    // Chart.js
    ('Chart.js', '4.4.1', 'chart.umd.min.js'),
    ('Chart.js', '3.9.1', 'chart.min.js'),

    // Vue.js
    ('vue', '3.4.21', 'vue.global.prod.min.js'),
    ('vue', '2.7.16', 'vue.min.js'),
    ('vue', '2.6.14', 'vue.min.js'),

    // React + ReactDOM
    ('react', '18.2.0', 'umd/react.production.min.js'),
    ('react-dom', '18.2.0', 'umd/react-dom.production.min.js'),

    // Angular
    ('angular.js', '1.8.3', 'angular.min.js'),

    // Leaflet
    ('leaflet', '1.9.4', 'leaflet.min.js'),
    ('leaflet', '1.9.4', 'leaflet.min.css'),

    // Highlight.js
    ('highlight.js', '11.9.0', 'highlight.min.js'),
    ('highlight.js', '11.9.0', 'styles/default.min.css'),

    // Swiper
    ('Swiper', '11.0.5', 'swiper-bundle.min.js'),
    ('Swiper', '11.0.5', 'swiper-bundle.min.css'),

    // Normalize.css
    ('normalize', '8.0.1', 'normalize.min.css'),

    // SweetAlert2
    ('limonte-sweetalert2', '11.10.5', 'sweetalert2.all.min.js'),

    // Select2
    ('select2', '4.0.13', 'js/select2.min.js'),
    ('select2', '4.0.13', 'css/select2.min.css'),

    // jQuery UI
    ('jqueryui', '1.13.2', 'jquery-ui.min.js'),
    ('jqueryui', '1.13.2', 'themes/base/jquery-ui.min.css'),

    // Slick carousel
    ('slick-carousel', '1.8.1', 'slick.min.js'),
    ('slick-carousel', '1.8.1', 'slick.min.css'),
    ('slick-carousel', '1.8.1', 'slick-theme.min.css'),

    // Owl Carousel
    ('OwlCarousel2', '2.3.4', 'owl.carousel.min.js'),
    ('OwlCarousel2', '2.3.4', 'assets/owl.carousel.min.css'),

    // Lottie
    ('lottie-player', '2.0.4', 'lottie-player.js'),

    // GSAP
    ('gsap', '3.12.5', 'gsap.min.js'),
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

  /// Per-site counter of CDN requests replaced from the local cache.
  /// Runtime-only (not persisted); resets when the app restarts.
  final Map<String, int> _replacementsPerSite = {};

  /// Record that a CDN request was replaced with a local copy for [siteId].
  void recordReplacement(String siteId) {
    _replacementsPerSite[siteId] = (_replacementsPerSite[siteId] ?? 0) + 1;
  }

  /// Number of CDN requests replaced from cache for a given site.
  int replacementsForSite(String siteId) => _replacementsPerSite[siteId] ?? 0;

  /// Clear the replacement counter for a specific site.
  void clearReplacementsForSite(String siteId) {
    _replacementsPerSite.remove(siteId);
  }

  /// The CDN URL regex patterns as strings, suitable for passing to the
  /// native Android interceptor. Each pattern exposes groups 1/2/3 =
  /// (library, version, file) just like [_CdnPattern].
  List<String> get cdnPatternStrings =>
      _cdnPatterns.map((p) => p.pattern.pattern).toList(growable: false);

  /// Snapshot of the cache index (cacheKey -> absolute file path on disk)
  /// for the native interceptor to serve replacements directly.
  Map<String, String> get cacheIndexSnapshot => Map<String, String>.from(_cache);

  /// Listeners notified whenever the cache index changes (add/remove/clear).
  /// Used by the native interceptor bridge to keep its copy in sync.
  final List<VoidCallback> _cacheChangeListeners = [];

  void addCacheChangeListener(VoidCallback listener) {
    _cacheChangeListeners.add(listener);
  }

  void removeCacheChangeListener(VoidCallback listener) {
    _cacheChangeListeners.remove(listener);
  }

  void _notifyCacheChanged() {
    for (final listener in List<VoidCallback>.from(_cacheChangeListeners)) {
      listener();
    }
  }

  /// Whether the service has been initialized.
  bool get isInitialized => _initialized;

  /// Whether any resources are cached.
  bool get hasCache => _cache.isNotEmpty;

  /// Number of cached resources.
  int get resourceCount => _cache.length;

  /// Total number of popular resources available for pre-download.
  int get popularResourceCount => _popularResources.length;

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
    return _getResourceByKey(key);
  }

  /// Get cached resource by cache key directly.
  Future<Uint8List?> _getResourceByKey(String key) async {
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

  /// Build the cdnjs download URL for a given cache key.
  /// Cache key format: library/version/file
  static String _cdnjsUrl(String cacheKey) {
    return '$_preferredCdnBase/$cacheKey';
  }

  /// Download a resource from cdnjs (preferred source) and cache it locally.
  /// The original CDN URL is NEVER contacted - we always fetch from cdnjs.
  Future<Uint8List?> _downloadAndCache(String cacheKey) async {
    if (!_initialized) return null;
    if (_cache.containsKey(cacheKey)) return _getResourceByKey(cacheKey);

    final url = _cdnjsUrl(cacheKey);
    try {
      final response = await http.get(Uri.parse(url)).timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode != 200) {
        LogService.instance.log('LocalCDN',
            'Download failed: HTTP ${response.statusCode} for $cacheKey');
        return null;
      }

      return await _saveToCache(cacheKey, response.bodyBytes);
    } catch (e) {
      LogService.instance.log('LocalCDN',
          'Download error for $cacheKey: $e', level: LogLevel.error);
      return null;
    }
  }

  /// Save bytes to cache and update index.
  Future<Uint8List?> _saveToCache(String key, Uint8List bytes) async {
    final safeFilename = key
        .replaceAll('/', '__')
        .replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final filePath = '$_cacheDir/$safeFilename';
    try {
      await File(filePath).writeAsBytes(bytes);
      _cache[key] = filePath;
      await _saveCacheIndex();
      return bytes;
    } catch (e) {
      LogService.instance.log('LocalCDN',
          'Cache write error for $key: $e', level: LogLevel.error);
      return null;
    }
  }

  /// Try to get a resource from cache, falling back to download from cdnjs.
  /// This is the primary method used by the webview interceptor.
  /// The original CDN URL is NEVER contacted.
  Future<Uint8List?> getOrFetchResource(String url) async {
    final key = getCacheKey(url);
    if (key == null) return null;

    // Try cache first
    final cached = await _getResourceByKey(key);
    if (cached != null) return cached;

    // Download from cdnjs (not from the original CDN URL)
    return _downloadAndCache(key);
  }

  /// Download all popular resources from cdnjs.
  /// Returns the number of successfully downloaded resources.
  /// Calls [onProgress] with (completed, total) for UI updates.
  Future<int> downloadPopularResources({
    void Function(int completed, int total)? onProgress,
  }) async {
    if (!_initialized) return 0;

    int downloaded = 0;
    final total = _popularResources.length;

    for (int i = 0; i < total; i++) {
      final (lib, ver, file) = _popularResources[i];
      final key = '$lib/$ver/$file';

      // Skip already cached
      if (_cache.containsKey(key)) {
        downloaded++;
        onProgress?.call(i + 1, total);
        continue;
      }

      final result = await _downloadAndCache(key);
      if (result != null) downloaded++;
      onProgress?.call(i + 1, total);
    }

    // Save timestamp
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastUpdatedKey, DateTime.now().toIso8601String());

    LogService.instance.log('LocalCDN',
        'Downloaded $downloaded/$total popular resources');
    return downloaded;
  }

  /// Get the last time resources were downloaded, or null if never.
  Future<DateTime?> getLastUpdated() async {
    final prefs = await SharedPreferences.getInstance();
    final timestamp = prefs.getString(_lastUpdatedKey);
    if (timestamp == null) return null;
    return DateTime.tryParse(timestamp);
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

    // Clear timestamp
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastUpdatedKey);
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

  /// Save cache index to SharedPreferences and notify listeners. Every
  /// mutation to [_cache] should go through this so the native interceptor
  /// bridge can keep its copy in sync.
  Future<void> _saveCacheIndex() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('localcdn_cache_index', jsonEncode(_cache));
    _notifyCacheChanged();
  }

  /// Format cache size as human-readable string.
  static String formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
