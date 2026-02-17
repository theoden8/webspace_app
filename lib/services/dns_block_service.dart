import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Level names for DNS blocklist severity levels (0-5).
const List<String> dnsBlockLevelNames = [
  'Off',
  'Light',
  'Normal',
  'Pro',
  'Pro++',
  'Ultimate',
];

/// Domain list file names for each level (index 0 is unused since level 0 = Off).
const List<String?> _levelFiles = [
  null, // 0: Off
  'domains/light.txt', // 1: Light
  'domains/multi.txt', // 2: Normal
  'domains/pro.txt', // 3: Pro
  'domains/pro.plus.txt', // 4: Pro++
  'domains/ultimate.txt', // 5: Ultimate
];

/// Mirror base URLs tried in order on failure.
const List<String> _mirrorBaseUrls = [
  'https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/',
  'https://gitlab.com/hagezi/mirror/-/raw/main/dns-blocklists/',
  'https://codeberg.org/hagezi/mirror2/raw/branch/main/dns-blocklists/',
];

/// Singleton service for downloading, caching, and querying Hagezi DNS blocklists.
/// Blocks navigation to ad/malware/tracker domains at the webview level.
class DnsBlockService {
  static const String _cacheFileName = 'dns_blocklist.txt';
  static const String _levelKey = 'dns_block_level';
  static const String _lastUpdatedKey = 'dns_block_last_updated';

  static DnsBlockService? _instance;
  static DnsBlockService get instance => _instance ??= DnsBlockService._();

  DnsBlockService._();

  Set<String> _blockedDomains = {};
  int _level = 0;

  /// Whether a blocklist is loaded and active.
  bool get hasBlocklist => _blockedDomains.isNotEmpty;

  /// The currently downloaded blocklist level (0-5).
  int get level => _level;

  /// Number of domains in the current blocklist.
  int get domainCount => _blockedDomains.length;

  /// Initialize the service by loading the cached domain file from disk (no network).
  /// Call in main() at app startup.
  Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _level = prefs.getInt(_levelKey) ?? 0;

      if (_level > 0) {
        final file = await _getCacheFile();
        if (await file.exists()) {
          final contents = await file.readAsString();
          _parseDomains(contents);
          if (kDebugMode) {
            debugPrint('[DnsBlock] Loaded ${_blockedDomains.length} domains from cache (level $_level)');
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[DnsBlock] Error loading cached blocklist: $e');
      }
    }
  }

  /// Download the domain list for the given level (0-5).
  /// Tries each mirror URL in order. Level 0 clears the blocklist.
  /// Returns true on success, false on failure.
  Future<bool> downloadList(int level) async {
    if (level < 0 || level > 5) return false;

    if (level == 0) {
      _blockedDomains = {};
      _level = 0;
      try {
        final file = await _getCacheFile();
        if (await file.exists()) {
          await file.delete();
        }
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(_levelKey, 0);
        await prefs.remove(_lastUpdatedKey);
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[DnsBlock] Error clearing blocklist: $e');
        }
      }
      return true;
    }

    final filePath = _levelFiles[level];
    if (filePath == null) return false;

    for (final baseUrl in _mirrorBaseUrls) {
      try {
        final url = '$baseUrl$filePath';
        if (kDebugMode) {
          debugPrint('[DnsBlock] Trying mirror: $url');
        }

        final response = await http.get(Uri.parse(url)).timeout(
          const Duration(seconds: 15),
        );

        if (response.statusCode != 200) {
          if (kDebugMode) {
            debugPrint('[DnsBlock] Mirror failed: HTTP ${response.statusCode}');
          }
          continue;
        }

        // Save to disk
        final file = await _getCacheFile();
        await file.writeAsString(response.body);

        // Parse domains
        _parseDomains(response.body);
        _level = level;

        // Save level and timestamp
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(_levelKey, level);
        await prefs.setString(_lastUpdatedKey, DateTime.now().toIso8601String());

        if (kDebugMode) {
          debugPrint('[DnsBlock] Downloaded ${_blockedDomains.length} domains (level $level)');
        }

        return true;
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[DnsBlock] Mirror error: $e');
        }
        continue;
      }
    }

    if (kDebugMode) {
      debugPrint('[DnsBlock] All mirrors failed for level $level');
    }
    return false;
  }

  /// Check if a URL should be blocked. Synchronous hot path.
  /// Extracts host, checks exact match, then walks up domain hierarchy.
  bool isBlocked(String url) {
    if (_blockedDomains.isEmpty) return false;

    final uri = Uri.tryParse(url);
    if (uri == null) return false;

    final host = uri.host;
    if (host.isEmpty) return false;

    // Exact match
    if (_blockedDomains.contains(host)) return true;

    // Walk up domain hierarchy: sub.tracker.net → tracker.net
    final parts = host.split('.');
    for (int i = 1; i < parts.length - 1; i++) {
      if (_blockedDomains.contains(parts.sublist(i).join('.'))) return true;
    }

    return false;
  }

  /// Get the last time the blocklist was downloaded, or null if never.
  Future<DateTime?> getLastUpdated() async {
    final prefs = await SharedPreferences.getInstance();
    final timestamp = prefs.getString(_lastUpdatedKey);
    if (timestamp == null) return null;
    return DateTime.tryParse(timestamp);
  }

  /// Load domains from a raw string. Exposed for testing.
  @visibleForTesting
  void loadDomainsFromString(String data) {
    _parseDomains(data);
  }

  void _parseDomains(String data) {
    final domains = <String>{};
    for (final line in data.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      domains.add(trimmed);
    }
    _blockedDomains = domains;
  }

  Future<File> _getCacheFile() async {
    final appDir = await getApplicationDocumentsDirectory();
    return File('${appDir.path}/$_cacheFileName');
  }
}
