import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/platform/unified_webview.dart';

/// Service for securely storing cookies using Flutter Secure Storage.
/// Supports migration from SharedPreferences for backward compatibility.
class CookieSecureStorage {
  static const String _secureStorageKey = 'secure_cookies';
  static const String _migrationCompleteKey = 'cookies_migrated_to_secure';

  final FlutterSecureStorage _secureStorage;

  CookieSecureStorage({FlutterSecureStorage? secureStorage})
      : _secureStorage = secureStorage ?? const FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true),
          iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
        );

  /// Loads cookies for all sites.
  /// First tries secure storage, then falls back to SharedPreferences.
  /// Returns a map of site URL to list of cookies.
  Future<Map<String, List<UnifiedCookie>>> loadCookies() async {
    // Try loading from secure storage first
    final secureCookies = await _loadFromSecureStorage();
    if (secureCookies.isNotEmpty) {
      return secureCookies;
    }

    // Fall back to SharedPreferences
    final prefsCookies = await _loadFromSharedPreferences();
    if (prefsCookies.isNotEmpty) {
      // Migrate to secure storage
      await saveCookies(prefsCookies);
      await _markMigrationComplete();
    }

    return prefsCookies;
  }

  /// Saves cookies to secure storage.
  /// Always saves to secure storage, never to SharedPreferences.
  Future<void> saveCookies(Map<String, List<UnifiedCookie>> cookiesByUrl) async {
    final Map<String, List<Map<String, dynamic>>> jsonMap = {};
    cookiesByUrl.forEach((url, cookies) {
      jsonMap[url] = cookies.map((c) => c.toJson()).toList();
    });

    final jsonString = jsonEncode(jsonMap);
    await _secureStorage.write(key: _secureStorageKey, value: jsonString);
  }

  /// Saves cookies for a single site URL.
  Future<void> saveCookiesForUrl(String url, List<UnifiedCookie> cookies) async {
    final existingCookies = await loadCookies();
    existingCookies[url] = cookies;
    await saveCookies(existingCookies);
  }

  /// Clears all stored cookies from secure storage.
  Future<void> clearCookies() async {
    await _secureStorage.delete(key: _secureStorageKey);
  }

  /// Clears cookies from SharedPreferences after migration.
  /// This should be called after confirming cookies are safely in secure storage.
  Future<void> clearSharedPreferencesCookies() async {
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

  Future<Map<String, List<UnifiedCookie>>> _loadFromSecureStorage() async {
    try {
      final jsonString = await _secureStorage.read(key: _secureStorageKey);
      if (jsonString == null || jsonString.isEmpty) {
        return {};
      }

      final jsonMap = jsonDecode(jsonString) as Map<String, dynamic>;
      final Map<String, List<UnifiedCookie>> result = {};

      jsonMap.forEach((url, cookiesJson) {
        final cookiesList = (cookiesJson as List<dynamic>)
            .map((c) => UnifiedCookie.fromJson(c as Map<String, dynamic>))
            .toList();
        result[url] = cookiesList;
      });

      return result;
    } catch (e) {
      // If there's an error reading secure storage, return empty
      return {};
    }
  }

  Future<Map<String, List<UnifiedCookie>>> _loadFromSharedPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final webViewModelsJson = prefs.getStringList('webViewModels');

      if (webViewModelsJson == null) {
        return {};
      }

      final Map<String, List<UnifiedCookie>> result = {};

      for (final modelJson in webViewModelsJson) {
        final json = jsonDecode(modelJson) as Map<String, dynamic>;
        final initUrl = json['initUrl'] as String?;
        final cookiesJson = json['cookies'] as List<dynamic>?;

        if (initUrl != null && cookiesJson != null && cookiesJson.isNotEmpty) {
          result[initUrl] = cookiesJson
              .map((c) => UnifiedCookie.fromJson(c as Map<String, dynamic>))
              .toList();
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
