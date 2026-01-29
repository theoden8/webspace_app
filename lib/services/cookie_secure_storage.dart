import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/platform/webview.dart';
import 'package:webspace/demo_data.dart' show isDemoMode;

/// Extracts the domain from a URL string.
/// Returns the host portion of the URL (e.g., "github.com" from "https://github.com/user/repo").
/// If the input is already a plain domain (no scheme), returns it as-is.
String extractDomainFromUrl(String url) {
  if (url.isEmpty) {
    return url;
  }
  try {
    final uri = Uri.parse(url);
    // If host is empty, the input might already be a plain domain
    // (Uri.parse('example.com').host returns empty string)
    if (uri.host.isEmpty) {
      return url;
    }
    return uri.host;
  } catch (e) {
    // If URL parsing fails, return the original string
    return url;
  }
}

/// Service for securely storing cookies using Flutter Secure Storage.
/// Supports migration from SharedPreferences for backward compatibility.
/// Falls back to SharedPreferences if secure storage is unavailable.
/// Cookies are keyed by domain (not full URL) since WebView shares cookies per domain.
class CookieSecureStorage {
  static const String _secureStorageKey = 'secure_cookies';
  static const String _sharedPrefsCookiesKey = 'cookies_fallback';
  static const String _migrationCompleteKey = 'cookies_migrated_to_secure';

  final FlutterSecureStorage _secureStorage;
  bool _secureStorageAvailable = true;

  CookieSecureStorage({FlutterSecureStorage? secureStorage})
      : _secureStorage = secureStorage ?? const FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true),
          iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
        );

  /// Loads cookies for all sites.
  /// First tries secure storage, then falls back to SharedPreferences.
  /// Returns a map of site URL to list of cookies.
  Future<Map<String, List<Cookie>>> loadCookies() async {
    // Try loading from secure storage first
    final secureCookies = await _loadFromSecureStorage();
    if (secureCookies.isNotEmpty) {
      return secureCookies;
    }

    // Fall back to SharedPreferences (both legacy webViewModels and fallback key)
    final prefsCookies = await _loadFromSharedPreferences();
    if (prefsCookies.isNotEmpty) {
      // Try to migrate to secure storage (will use fallback if secure storage fails)
      await saveCookies(prefsCookies);
      await _markMigrationComplete();
    }

    return prefsCookies;
  }

  /// Saves cookies to secure storage.
  /// Falls back to SharedPreferences if secure storage is unavailable.
  Future<void> saveCookies(Map<String, List<Cookie>> cookiesByUrl) async {
    if (isDemoMode) return; // Don't persist in demo mode
    final Map<String, List<Map<String, dynamic>>> jsonMap = {};
    cookiesByUrl.forEach((url, cookies) {
      jsonMap[url] = cookies.map((c) => c.toJson()).toList();
    });

    final jsonString = jsonEncode(jsonMap);

    if (_secureStorageAvailable) {
      try {
        await _secureStorage.write(key: _secureStorageKey, value: jsonString);
        return;
      } catch (e) {
        // Secure storage failed, mark as unavailable and use fallback
        debugPrint('Secure storage unavailable: $e');
        _secureStorageAvailable = false;
      }
    }

    // Fallback to SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sharedPrefsCookiesKey, jsonString);
  }

  /// Saves cookies for a single site URL.
  /// The URL is converted to a domain key before storing.
  Future<void> saveCookiesForUrl(String url, List<Cookie> cookies) async {
    if (isDemoMode) return; // Don't persist in demo mode
    final domain = extractDomainFromUrl(url);
    final existingCookies = await loadCookies();
    existingCookies[domain] = cookies;
    await saveCookies(existingCookies);
  }

  /// Removes cookies for domains not in the provided set of active domains.
  /// This cleans up orphaned cookies after sites are deleted or settings are imported.
  Future<void> removeOrphanedCookies(Set<String> activeDomains) async {
    if (isDemoMode) return; // Don't persist in demo mode
    final allCookies = await loadCookies();
    final domainsToRemove = allCookies.keys
        .where((domain) => !activeDomains.contains(domain))
        .toList();

    if (domainsToRemove.isEmpty) {
      return;
    }

    for (final domain in domainsToRemove) {
      allCookies.remove(domain);
    }

    await saveCookies(allCookies);
    debugPrint('Removed orphaned cookies for domains: $domainsToRemove');
  }

  /// Clears all stored cookies from both secure storage and fallback.
  Future<void> clearCookies() async {
    if (isDemoMode) return; // Don't persist in demo mode
    try {
      await _secureStorage.delete(key: _secureStorageKey);
    } catch (e) {
      debugPrint('Failed to clear secure storage cookies: $e');
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_sharedPrefsCookiesKey);
    } catch (e) {
      debugPrint('Failed to clear fallback cookies: $e');
    }
  }

  /// Clears cookies from SharedPreferences after migration.
  /// This should be called after confirming cookies are safely in secure storage.
  Future<void> clearSharedPreferencesCookies() async {
    if (isDemoMode) return; // Don't persist in demo mode
    final prefs = await SharedPreferences.getInstance();
    final webViewModelsJson = prefs.getStringList('webViewModels');

    if (webViewModelsJson == null) return;

    // Update each model to remove cookies from SharedPreferences
    final updatedModels = webViewModelsJson.map((modelJson) {
      final json = jsonDecode(modelJson) as Map<String, dynamic>;
      json['cookies'] = []; // Clear cookies from SharedPreferences data
      return jsonEncode(json);
    }).toList();

    await prefs.setStringList('webViewModels', updatedModels);
  }

  Future<Map<String, List<Cookie>>> _loadFromSecureStorage() async {
    // Try secure storage first
    if (_secureStorageAvailable) {
      try {
        final jsonString = await _secureStorage.read(key: _secureStorageKey);
        if (jsonString != null && jsonString.isNotEmpty) {
          return _parseJsonCookies(jsonString);
        }
      } catch (e) {
        // Secure storage failed, mark as unavailable
        debugPrint('Secure storage unavailable for reading: $e');
        _secureStorageAvailable = false;
      }
    }

    // Try SharedPreferences fallback key
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(_sharedPrefsCookiesKey);
      if (jsonString != null && jsonString.isNotEmpty) {
        return _parseJsonCookies(jsonString);
      }
    } catch (e) {
      debugPrint('Failed to read cookies fallback: $e');
    }

    return {};
  }

  Map<String, List<Cookie>> _parseJsonCookies(String jsonString) {
    final jsonMap = jsonDecode(jsonString) as Map<String, dynamic>;
    final Map<String, List<Cookie>> result = {};

    jsonMap.forEach((key, cookiesJson) {
      final cookiesList = (cookiesJson as List<dynamic>)
          .map((c) => cookieFromJson(c as Map<String, dynamic>))
          .toList();

      // Convert URL keys to domain keys for backward compatibility
      final domain = extractDomainFromUrl(key);

      // Merge cookies if multiple URL keys resolve to the same domain
      if (result.containsKey(domain)) {
        final existingNames = result[domain]!.map((c) => c.name).toSet();
        for (final cookie in cookiesList) {
          if (!existingNames.contains(cookie.name)) {
            result[domain]!.add(cookie);
            existingNames.add(cookie.name);
          }
        }
      } else {
        result[domain] = cookiesList;
      }
    });

    return result;
  }

  Future<Map<String, List<Cookie>>> _loadFromSharedPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final webViewModelsJson = prefs.getStringList('webViewModels');

      if (webViewModelsJson == null) {
        return {};
      }

      final Map<String, List<Cookie>> result = {};

      for (final modelJson in webViewModelsJson) {
        final json = jsonDecode(modelJson) as Map<String, dynamic>;
        final initUrl = json['initUrl'] as String?;
        final cookiesJson = json['cookies'] as List<dynamic>?;

        if (initUrl != null && cookiesJson != null && cookiesJson.isNotEmpty) {
          // Use domain as key instead of full URL (migration to new format)
          final domain = extractDomainFromUrl(initUrl);
          final cookies = cookiesJson
              .map((c) => cookieFromJson(c as Map<String, dynamic>))
              .toList();

          // Merge cookies if multiple sites share the same domain
          if (result.containsKey(domain)) {
            final existingNames = result[domain]!.map((c) => c.name).toSet();
            for (final cookie in cookies) {
              if (!existingNames.contains(cookie.name)) {
                result[domain]!.add(cookie);
                existingNames.add(cookie.name);
              }
            }
          } else {
            result[domain] = cookies;
          }
        }
      }

      return result;
    } catch (e) {
      return {};
    }
  }

  Future<void> _markMigrationComplete() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_migrationCompleteKey, true);
  }

  Future<bool> isMigrationComplete() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_migrationCompleteKey) ?? false;
  }
}
