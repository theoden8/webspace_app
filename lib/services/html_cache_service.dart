import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Service to cache HTML content per site for offline viewing and faster loads.
/// Cache is cleared on app upgrades to ensure fresh content.
class HtmlCacheService {
  static const String _versionKey = 'html_cache_version';
  static const String _cacheDir = 'html_cache';

  static HtmlCacheService? _instance;
  static HtmlCacheService get instance => _instance ??= HtmlCacheService._();

  HtmlCacheService._();

  Directory? _cacheDirectory;

  /// In-memory cache for sync access during build
  final Map<String, String> _memoryCache = {};

  /// Initialize the cache service. Call on app startup.
  Future<void> initialize() async {
    final appDir = await getApplicationDocumentsDirectory();
    _cacheDirectory = Directory('${appDir.path}/$_cacheDir');

    // Clear cache on version upgrade
    await _clearCacheOnUpgrade();

    // Ensure cache directory exists
    if (!await _cacheDirectory!.exists()) {
      await _cacheDirectory!.create(recursive: true);
    }

    // Pre-load all cached HTML into memory for sync access
    await _preloadCache();
  }

  /// Pre-load all cached HTML files into memory
  Future<void> _preloadCache() async {
    if (_cacheDirectory == null || !await _cacheDirectory!.exists()) return;

    try {
      final files = await _cacheDirectory!.list().toList();
      for (final entity in files) {
        if (entity is File && entity.path.endsWith('.html')) {
          final content = await entity.readAsString();
          final newlineIndex = content.indexOf('\n');
          if (newlineIndex != -1) {
            final siteId = entity.path.split('/').last.replaceAll('.html', '');
            final html = content.substring(newlineIndex + 1);
            _memoryCache[siteId] = html;
          }
        }
      }
      if (kDebugMode) {
        debugPrint('[HtmlCache] Pre-loaded ${_memoryCache.length} cached pages');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[HtmlCache] Error pre-loading cache: $e');
      }
    }
  }

  /// Get cached HTML synchronously (from pre-loaded memory cache)
  String? getHtmlSync(String siteId) {
    return _memoryCache[siteId];
  }

  Future<void> _clearCacheOnUpgrade() async {
    final prefs = await SharedPreferences.getInstance();
    final packageInfo = await PackageInfo.fromPlatform();

    final currentVersion = '${packageInfo.version}+${packageInfo.buildNumber}';
    final lastVersion = prefs.getString(_versionKey);

    if (lastVersion != null && lastVersion != currentVersion) {
      // Version changed - clear the HTML cache
      if (_cacheDirectory != null && await _cacheDirectory!.exists()) {
        await _cacheDirectory!.delete(recursive: true);
        if (kDebugMode) {
          debugPrint('[HtmlCache] Cleared cache on upgrade from $lastVersion to $currentVersion');
        }
      }
    }

    await prefs.setString(_versionKey, currentVersion);
  }

  /// Get the cache file path for a site
  File _getCacheFile(String siteId) {
    return File('${_cacheDirectory!.path}/$siteId.html');
  }

  /// Max HTML size to cache (10MB)
  static const int _maxHtmlSize = 10 * 1024 * 1024;

  /// Save HTML content for a site
  Future<void> saveHtml(String siteId, String html, String url) async {
    if (_cacheDirectory == null) return;

    // Skip if HTML is too large
    if (html.length > _maxHtmlSize) {
      if (kDebugMode) {
        debugPrint('[HtmlCache] Skipping save for $siteId - HTML too large (${html.length} bytes > $_maxHtmlSize)');
      }
      return;
    }

    try {
      final file = _getCacheFile(siteId);

      // Store URL as first line, then HTML
      final content = '$url\n$html';
      await file.writeAsString(content);

      // Update memory cache
      _memoryCache[siteId] = html;

      if (kDebugMode) {
        debugPrint('[HtmlCache] Saved ${html.length} bytes for site $siteId');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[HtmlCache] Error saving HTML for $siteId: $e');
      }
    }
  }

  /// Load cached HTML for a site
  /// Returns (url, html) tuple or null if not cached
  Future<(String, String)?> loadHtml(String siteId) async {
    if (_cacheDirectory == null) return null;

    try {
      final file = _getCacheFile(siteId);
      if (!await file.exists()) return null;

      final content = await file.readAsString();
      final newlineIndex = content.indexOf('\n');
      if (newlineIndex == -1) return null;

      final url = content.substring(0, newlineIndex);
      final html = content.substring(newlineIndex + 1);

      if (kDebugMode) {
        debugPrint('[HtmlCache] Loaded ${html.length} bytes for site $siteId');
      }

      return (url, html);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[HtmlCache] Error loading HTML for $siteId: $e');
      }
      return null;
    }
  }

  /// Check if cached HTML exists for a site
  Future<bool> hasCache(String siteId) async {
    if (_cacheDirectory == null) return false;
    final file = _getCacheFile(siteId);
    return file.exists();
  }

  /// Delete cached HTML for a site
  Future<void> deleteCache(String siteId) async {
    if (_cacheDirectory == null) return;
    final file = _getCacheFile(siteId);
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// Delete cached HTML for sites not in the provided set
  Future<void> removeOrphanedCaches(Set<String> activeSiteIds) async {
    if (_cacheDirectory == null || !await _cacheDirectory!.exists()) return;

    final files = await _cacheDirectory!.list().toList();
    for (final entity in files) {
      if (entity is File && entity.path.endsWith('.html')) {
        final filename = entity.path.split('/').last;
        final siteId = filename.replaceAll('.html', '');
        if (!activeSiteIds.contains(siteId)) {
          await entity.delete();
          if (kDebugMode) {
            debugPrint('[HtmlCache] Removed orphaned cache for $siteId');
          }
        }
      }
    }
  }
}
