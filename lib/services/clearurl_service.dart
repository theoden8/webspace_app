import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A parsed ClearURLs provider that matches URLs and strips tracking parameters.
class ClearUrlProvider {
  final RegExp urlPattern;
  final bool completeProvider;
  final List<RegExp> rules;
  final List<RegExp> rawRules;
  final List<RegExp> exceptions;
  final List<RegExp> redirections;

  ClearUrlProvider({
    required this.urlPattern,
    this.completeProvider = false,
    this.rules = const [],
    this.rawRules = const [],
    this.exceptions = const [],
    this.redirections = const [],
  });
}

/// Singleton service for downloading, caching, parsing, and applying ClearURL rules.
/// Strips tracking parameters (utm_source, fbclid, etc.) from URLs using rules
/// maintained by the ClearURLs open-source project.
class ClearUrlService {
  static const String _rulesFileName = 'clearurl_rules.json';
  static const String _lastUpdatedKey = 'clearurl_last_updated';
  static const String _rulesUrl = 'https://rules2.clearurls.xyz/data.minify.json';

  static ClearUrlService? _instance;
  static ClearUrlService get instance => _instance ??= ClearUrlService._();

  ClearUrlService._();

  List<ClearUrlProvider> _providers = [];

  /// Whether rules have been loaded and are available.
  bool get hasRules => _providers.isNotEmpty;

  /// Initialize the service by loading cached rules from disk (no network).
  /// Call in main() at app startup.
  Future<void> initialize() async {
    try {
      final file = await _getRulesFile();
      if (await file.exists()) {
        final contents = await file.readAsString();
        final json = jsonDecode(contents) as Map<String, dynamic>;
        _parseRules(json);
        if (kDebugMode) {
          debugPrint('[ClearURLs] Loaded ${_providers.length} providers from cache');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[ClearURLs] Error loading cached rules: $e');
      }
    }
  }

  /// Download rules from the ClearURLs server, cache to disk, and parse.
  /// Returns true on success, false on failure.
  Future<bool> downloadRules() async {
    try {
      final response = await http.get(Uri.parse(_rulesUrl)).timeout(
        const Duration(seconds: 15),
      );

      if (response.statusCode != 200) {
        if (kDebugMode) {
          debugPrint('[ClearURLs] Download failed: HTTP ${response.statusCode}');
        }
        return false;
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;

      // Save to disk
      final file = await _getRulesFile();
      await file.writeAsString(response.body);

      // Save timestamp
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastUpdatedKey, DateTime.now().toIso8601String());

      // Parse
      _parseRules(json);

      if (kDebugMode) {
        debugPrint('[ClearURLs] Downloaded and parsed ${_providers.length} providers');
      }

      return true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[ClearURLs] Download error: $e');
      }
      return false;
    }
  }

  /// Get the last time rules were downloaded, or null if never.
  Future<DateTime?> getLastUpdated() async {
    final prefs = await SharedPreferences.getInstance();
    final timestamp = prefs.getString(_lastUpdatedKey);
    if (timestamp == null) return null;
    return DateTime.tryParse(timestamp);
  }

  /// Clean a URL by stripping tracking parameters according to loaded rules.
  /// Returns the cleaned URL, or the original if no changes were made.
  /// Returns an empty string if the URL should be blocked entirely (completeProvider).
  String cleanUrl(String url) {
    if (_providers.isEmpty) return url;

    for (final provider in _providers) {
      if (!provider.urlPattern.hasMatch(url)) continue;

      // Check exceptions - skip this provider if URL matches an exception
      if (provider.exceptions.any((e) => e.hasMatch(url))) continue;

      // Block entirely if completeProvider
      if (provider.completeProvider) return '';

      // Check redirections - extract redirect target
      for (final redirection in provider.redirections) {
        final match = redirection.firstMatch(url);
        if (match != null && match.groupCount >= 1) {
          final target = match.group(1);
          if (target != null && target.isNotEmpty) {
            final decoded = Uri.decodeComponent(target);
            return decoded;
          }
        }
      }

      // Strip query params matching rules
      var uri = Uri.tryParse(url);
      if (uri == null) continue;

      if (uri.queryParameters.isNotEmpty) {
        final cleanedParams = Map<String, String>.from(uri.queryParameters);
        cleanedParams.removeWhere((key, value) {
          return provider.rules.any((rule) => rule.hasMatch(key));
        });

        if (cleanedParams.length != uri.queryParameters.length) {
          if (cleanedParams.isEmpty) {
            // Remove query string entirely
            uri = uri.replace(query: '');
            url = uri.toString();
            // Remove trailing '?' left by empty query
            if (url.endsWith('?')) {
              url = url.substring(0, url.length - 1);
            }
          } else {
            uri = uri.replace(queryParameters: cleanedParams);
            url = uri.toString();
          }
        }
      }

      // Apply rawRules - regex replacements on the full URL string
      for (final rawRule in provider.rawRules) {
        url = url.replaceAll(rawRule, '');
      }
    }

    return url;
  }

  /// Load rules from a parsed JSON map. Exposed for testing.
  @visibleForTesting
  void loadRulesFromJson(Map<String, dynamic> json) {
    _parseRules(json);
  }

  void _parseRules(Map<String, dynamic> json) {
    final providers = <ClearUrlProvider>[];

    final providersRaw = json['providers'];
    if (providersRaw == null || providersRaw is! Map) return;
    final providersJson = Map<String, dynamic>.from(providersRaw);

    for (final entry in providersJson.entries) {
      if (entry.value is! Map) continue;
      final data = Map<String, dynamic>.from(entry.value as Map);


      final urlPatternStr = data['urlPattern'] as String?;
      if (urlPatternStr == null || urlPatternStr.isEmpty) continue;

      try {
        final urlPattern = RegExp(urlPatternStr, caseSensitive: false);
        final completeProvider = data['completeProvider'] as bool? ?? false;

        final rules = _parseRegexList(data['rules'] as List<dynamic>?);
        final rawRules = _parseRegexList(data['rawRules'] as List<dynamic>?);
        final exceptions = _parseRegexList(data['exceptions'] as List<dynamic>?);
        final redirections = _parseRegexList(data['redirections'] as List<dynamic>?);

        providers.add(ClearUrlProvider(
          urlPattern: urlPattern,
          completeProvider: completeProvider,
          rules: rules,
          rawRules: rawRules,
          exceptions: exceptions,
          redirections: redirections,
        ));
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[ClearURLs] Error parsing provider "${entry.key}": $e');
        }
      }
    }

    _providers = providers;
  }

  List<RegExp> _parseRegexList(List<dynamic>? list) {
    if (list == null) return [];
    final result = <RegExp>[];
    for (final item in list) {
      if (item is String && item.isNotEmpty) {
        try {
          result.add(RegExp(item, caseSensitive: false));
        } catch (e) {
          if (kDebugMode) {
            debugPrint('[ClearURLs] Invalid regex "$item": $e');
          }
        }
      }
    }
    return result;
  }

  Future<File> _getRulesFile() async {
    final appDir = await getApplicationDocumentsDirectory();
    return File('${appDir.path}/$_rulesFileName');
  }
}
