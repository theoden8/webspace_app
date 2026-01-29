import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/webview.dart';
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
///
/// Storage is keyed by siteId for per-site cookie isolation. This allows
/// multiple sites on the same domain to have separate cookie contexts.
/// Legacy data (keyed by domain) is supported for migration.
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

  /// Loads cookies for all sites from both storages:
  /// - isSecure=true cookies from Flutter Secure Storage
  /// - isSecure=false cookies from SharedPreferences
  /// Returns a merged map of site URL to list of cookies.
  Future<Map<String, List<Cookie>>> loadCookies() async {
    final Map<String, List<Cookie>> result = {};

    // Load secure cookies from Flutter Secure Storage
    final secureCookies = await _loadSecureCookiesOnly();
    secureCookies.forEach((url, cookies) {
      result[url] = List.from(cookies);
    });

    // Load non-secure cookies from SharedPreferences
    final nonSecureCookies = await _loadNonSecureCookiesOnly();
    nonSecureCookies.forEach((url, cookies) {
      if (result.containsKey(url)) {
        result[url]!.addAll(cookies);
      } else {
        result[url] = List.from(cookies);
      }
    });

    // Handle legacy migration if needed
    if (result.isEmpty) {
      final legacyCookies = await _loadLegacyFromSharedPreferences();
      if (legacyCookies.isNotEmpty) {
        await saveCookies(legacyCookies);
        await _markMigrationComplete();
        return legacyCookies;
      }
    }

    return result;
  }

  /// Saves cookies with appropriate storage based on isSecure flag:
  /// - isSecure=true cookies → Flutter Secure Storage only
  /// - isSecure=false cookies → SharedPreferences
  Future<void> saveCookies(Map<String, List<Cookie>> cookiesByUrl) async {
    if (isDemoMode) return; // Don't persist in demo mode

    // Split cookies by security flag
    final Map<String, List<Map<String, dynamic>>> secureJsonMap = {};
    final Map<String, List<Map<String, dynamic>>> nonSecureJsonMap = {};

    cookiesByUrl.forEach((url, cookies) {
      final secureCookies = cookies.where((c) => c.isSecure == true).toList();
      final nonSecureCookies = cookies.where((c) => c.isSecure != true).toList();

      if (secureCookies.isNotEmpty) {
        secureJsonMap[url] = secureCookies.map((c) => c.toJson()).toList();
      }
      if (nonSecureCookies.isNotEmpty) {
        nonSecureJsonMap[url] = nonSecureCookies.map((c) => c.toJson()).toList();
      }
    });

    // Save secure cookies to Flutter Secure Storage
    if (_secureStorageAvailable && secureJsonMap.isNotEmpty) {
      try {
        await _secureStorage.write(
          key: _secureStorageKey,
          value: jsonEncode(secureJsonMap),
        );
      } catch (e) {
        // Secure storage failed - secure cookies are lost (intentional)
        debugPrint('Secure storage unavailable, secure cookies not persisted: $e');
        _secureStorageAvailable = false;
      }
    } else if (secureJsonMap.isEmpty && _secureStorageAvailable) {
      // Clear secure storage if no secure cookies
      try {
        await _secureStorage.delete(key: _secureStorageKey);
      } catch (e) {
        debugPrint('Failed to clear secure storage: $e');
      }
    }

    // Save non-secure cookies to SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    if (nonSecureJsonMap.isNotEmpty) {
      await prefs.setString(_sharedPrefsCookiesKey, jsonEncode(nonSecureJsonMap));
    } else {
      await prefs.remove(_sharedPrefsCookiesKey);
    }
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

  /// Loads cookies for a specific site by siteId.
  /// Returns an empty list if no cookies are stored for this site.
  Future<List<Cookie>> loadCookiesForSite(String siteId) async {
    final allCookies = await loadCookies();
    return allCookies[siteId] ?? [];
  }

  /// Saves cookies for a specific site by siteId.
  Future<void> saveCookiesForSite(String siteId, List<Cookie> cookies) async {
    if (isDemoMode) return; // Don't persist in demo mode
    final existingCookies = await loadCookies();
    if (cookies.isEmpty) {
      existingCookies.remove(siteId);
    } else {
      existingCookies[siteId] = cookies;
    }
    await saveCookies(existingCookies);
  }

  /// Removes cookies for siteIds not in the provided set of active siteIds.
  /// This cleans up orphaned cookies after sites are deleted or settings are imported.
  Future<void> removeOrphanedCookies(Set<String> activeSiteIds) async {
    if (isDemoMode) return; // Don't persist in demo mode
    final allCookies = await loadCookies();
    final siteIdsToRemove = allCookies.keys
        .where((siteId) => !activeSiteIds.contains(siteId))
        .toList();

    if (siteIdsToRemove.isEmpty) {
      return;
    }

    for (final siteId in siteIdsToRemove) {
      allCookies.remove(siteId);
    }

    await saveCookies(allCookies);
    debugPrint('Removed orphaned cookies for siteIds: $siteIdsToRemove');
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

  /// Load only secure cookies from Flutter Secure Storage
  Future<Map<String, List<Cookie>>> _loadSecureCookiesOnly() async {
    if (!_secureStorageAvailable) return {};

    try {
      final jsonString = await _secureStorage.read(key: _secureStorageKey);
      if (jsonString != null && jsonString.isNotEmpty) {
        return _parseJsonCookies(jsonString);
      }
    } catch (e) {
      debugPrint('Secure storage unavailable for reading: $e');
      _secureStorageAvailable = false;
    }
    return {};
  }

  /// Load only non-secure cookies from SharedPreferences
  Future<Map<String, List<Cookie>>> _loadNonSecureCookiesOnly() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(_sharedPrefsCookiesKey);
      if (jsonString != null && jsonString.isNotEmpty) {
        return _parseJsonCookies(jsonString);
      }
    } catch (e) {
      debugPrint('Failed to read non-secure cookies: $e');
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

  /// Load legacy cookies from webViewModels in SharedPreferences (migration only)
  Future<Map<String, List<Cookie>>> _loadLegacyFromSharedPreferences() async {
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
