import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:webspace/services/keystore.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/url_host.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/settings/demo_mode.dart';
import 'package:webspace/utils/concurrency.dart';
import 'package:webspace/services/cookie_manager.dart';

/// Service for securely storing cookies using Flutter Secure Storage.
/// Supports migration from SharedPreferences for backward compatibility.
///
/// isSecure=true cookies live only in the keystore, and are lost rather
/// than written in plaintext when it is unavailable; the rest live in
/// SharedPreferences.
///
/// Storage is keyed by siteId for per-site cookie isolation. This allows
/// multiple sites on the same domain to have separate cookie contexts.
/// Legacy data (keyed by domain) is supported for migration.
class CookieSecureStorage {
  static const String _secureStorageKey = 'secure_cookies';
  static const String _sharedPrefsCookiesKey = 'cookies_fallback';
  static const String _migrationCompleteKey = 'cookies_migrated_to_secure';

  /// Serializes every cookie-store mutation. Static so it is shared across
  /// instances that write the same keys: a whole-map `saveCookies` rebuilt
  /// from an in-memory snapshot must not interleave with a per-site
  /// `saveCookiesForSite`, or one clobbers the other (dropped session, or an
  /// archive-tier cookie re-persisted into app-tier storage — ARCH-001).
  static final SerialQueue _writes = SerialQueue();

  final SecureJsonStore<Map<String, List<Cookie>>> _secure;

  CookieSecureStorage({FlutterSecureStorage? secureStorage})
      : _secure = SecureJsonStore(
          keystore: secureStorage ?? Keystores.credentials,
          key: _secureStorageKey,
          logTag: LogTag.cookieStorage,
          decode: _decodeCookies,
          encode: _encodeCookies,
          isEmpty: (cookies) => cookies.isEmpty,
          onFailure: KeystoreFailurePolicy.stopUsing,
          queue: _writes,
        );

  /// Loads cookies for all sites from both storages:
  /// - isSecure=true cookies from Flutter Secure Storage
  /// - isSecure=false cookies from SharedPreferences
  /// Returns a merged map of site URL to list of cookies.
  Future<Map<String, List<Cookie>>> loadCookies() async {
    final Map<String, List<Cookie>> result = {};

    final secureCookies = await _secure.read();
    secureCookies.forEach((url, cookies) {
      result[url] = List.from(cookies);
    });

    final nonSecureCookies = await _loadNonSecureCookiesOnly();
    nonSecureCookies.forEach((url, cookies) {
      if (result.containsKey(url)) {
        result[url]!.addAll(cookies);
      } else {
        result[url] = List.from(cookies);
      }
    });

    if (result.isEmpty) {
      final legacyCookies = await _loadLegacyFromSharedPreferences();
      if (legacyCookies.isNotEmpty) {
        // Unlocked: loadCookies runs inside the locked compound mutators
        // below, so calling the locked saveCookies here would self-deadlock.
        await _saveCookiesUnlocked(legacyCookies);
        await _markMigrationComplete();
        return legacyCookies;
      }
    }

    return result;
  }

  /// Saves cookies with appropriate storage based on isSecure flag:
  /// - isSecure=true cookies → Flutter Secure Storage only
  /// - isSecure=false cookies → SharedPreferences
  Future<void> saveCookies(Map<String, List<Cookie>> cookiesByUrl) {
    return _writes.run(() => _saveCookiesUnlocked(cookiesByUrl));
  }

  /// Build the full app-tier cookie map INSIDE the write lock, then persist
  /// it. Use this (instead of building the map before `saveCookies`) when the
  /// map is derived from live model state that a concurrent mutation can
  /// change — specifically an archive move flipping `isArchiveTier` then
  /// clearing the site's app-tier entry. Building before the lock lets a save
  /// whose snapshot predates the flip land its whole-map write after the
  /// clear, re-persisting the archive-tier session into app-tier storage
  /// (ARCH-001). `build` runs synchronously at lock-acquisition time, after
  /// any already-committed flip+clear, so the snapshot is always consistent.
  Future<void> saveCookiesBuilt(Map<String, List<Cookie>> Function() build) {
    return _writes.run(() => _saveCookiesUnlocked(build()));
  }

  Future<void> _saveCookiesUnlocked(Map<String, List<Cookie>> cookiesByUrl) async {
    if (isDemoMode) return;

    final Map<String, List<Cookie>> secure = {};
    final Map<String, List<Cookie>> nonSecure = {};
    cookiesByUrl.forEach((url, cookies) {
      final secureCookies = cookies.where((c) => c.isSecure == true).toList();
      final nonSecureCookies = cookies.where((c) => c.isSecure != true).toList();
      if (secureCookies.isNotEmpty) secure[url] = secureCookies;
      if (nonSecureCookies.isNotEmpty) nonSecure[url] = nonSecureCookies;
    });

    await _secure.write(secure);

    final prefs = await SharedPreferences.getInstance();
    if (nonSecure.isNotEmpty) {
      await prefs.setString(
          _sharedPrefsCookiesKey, jsonEncode(_encodeCookies(nonSecure)));
    } else {
      await prefs.remove(_sharedPrefsCookiesKey);
    }
  }

  /// Returns an empty list if no cookies are stored for this site.
  Future<List<Cookie>> loadCookiesForSite(String siteId) async {
    final allCookies = await loadCookies();
    return allCookies[siteId] ?? [];
  }

  Future<void> saveCookiesForSite(String siteId,
      {required List<Cookie> cookies}) {
    if (isDemoMode) return Future.value();
    return _writes.run(() async {
      final existingCookies = await loadCookies();
      if (cookies.isEmpty) {
        existingCookies.remove(siteId);
      } else {
        existingCookies[siteId] = cookies;
      }
      await _saveCookiesUnlocked(existingCookies);
    });
  }

  /// Removes cookies for siteIds not in the provided set of active siteIds.
  /// This cleans up orphaned cookies after sites are deleted or settings are imported.
  Future<void> removeOrphanedCookies(Set<String> activeSiteIds) async {
    if (isDemoMode) return;
    final siteIdsToRemove = <String>[];
    await _writes.run(() async {
      final allCookies = await loadCookies();
      siteIdsToRemove.addAll(allCookies.keys
          .where((siteId) => !activeSiteIds.contains(siteId)));
      if (siteIdsToRemove.isEmpty) return;
      for (final siteId in siteIdsToRemove) {
        allCookies.remove(siteId);
      }
      await _saveCookiesUnlocked(allCookies);
    });
    if (siteIdsToRemove.isEmpty) return;
    LogTag.cookieStorage.info(
        'Removed orphaned cookies for siteIds: $siteIdsToRemove',
        sensitive: true);
  }

  /// Clears all stored cookies from both secure storage and fallback.
  Future<void> clearCookies() async {
    if (isDemoMode) return;
    await _secure.delete();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_sharedPrefsCookiesKey);
  }

  Future<Map<String, List<Cookie>>> _loadNonSecureCookiesOnly() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_sharedPrefsCookiesKey);
    if (jsonString == null || jsonString.isEmpty) return {};
    try {
      return _decodeCookies(jsonDecode(jsonString));
    } on FormatException {
      LogTag.cookieStorage.error(
          'Non-secure cookies are not JSON; reading them as empty');
      return {};
    }
  }

  static Object _encodeCookies(Map<String, List<Cookie>> cookiesByUrl) => {
        for (final MapEntry(:key, :value) in cookiesByUrl.entries)
          key: [for (final cookie in value) cookie.toJson()],
      };

  /// Keys written by older builds were URLs; they read back as domains, and
  /// cookies of one name under two keys that fold together keep the first.
  static Map<String, List<Cookie>> _decodeCookies(Object? json) {
    final Map<String, List<Cookie>> result = {};
    if (json is! Map) return result;
    for (final MapEntry(:key, :value) in json.entries) {
      if (key is! String || value is! List) continue;
      _mergeByName(result,
          domain: extractDomain(key), cookies: _cookieList(value));
    }
    return result;
  }

  static List<Cookie> _cookieList(List<Object?> json) => [
        for (final c in json) ?tryCookieFromJson(c),
      ];

  static void _mergeByName(
    Map<String, List<Cookie>> into, {
    required String domain,
    required List<Cookie> cookies,
  }) {
    final existing = into[domain];
    if (existing == null) {
      into[domain] = cookies;
      return;
    }
    final names = existing.map((c) => c.name).toSet();
    existing.addAll(cookies.where((c) => names.add(c.name)));
  }

  /// Load legacy cookies from webViewModels in SharedPreferences (migration only)
  Future<Map<String, List<Cookie>>> _loadLegacyFromSharedPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final webViewModelsJson = prefs.getStringList('webViewModels');
    if (webViewModelsJson == null) return {};

    final Map<String, List<Cookie>> result = {};
    for (final modelJson in webViewModelsJson) {
      final Object? json;
      try {
        json = jsonDecode(modelJson);
      } on FormatException {
        continue;
      }
      if (json case {'initUrl': final String initUrl, 'cookies': final List<Object?> cookies}
          when cookies.isNotEmpty) {
        _mergeByName(result,
            domain: extractDomain(initUrl), cookies: _cookieList(cookies));
      }
    }
    return result;
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
