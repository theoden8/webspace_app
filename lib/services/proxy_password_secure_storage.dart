import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/services/log_service.dart';

/// Secure storage for proxy authentication passwords.
///
/// Mirrors the design of [CookieSecureStorage]: the canonical at-rest store
/// is `flutter_secure_storage` (Keychain on iOS/macOS, EncryptedSharedPrefs
/// on Android, libsecret on Linux). The non-secret fields of
/// [UserProxySettings] (type, address, username) continue to live in
/// SharedPreferences alongside the rest of the per-site / global settings;
/// only the password is held here.
///
/// All passwords for the app are kept under a single secure-storage entry
/// (a JSON map of `key -> password`) rather than one entry per site. This
/// matches the cookie storage pattern and minimises secure-storage round
/// trips on save (each `write` is a synchronous platform call on every
/// platform we support).
///
/// Storage keys:
/// - per-site proxy password: keyed by the site's `siteId`
/// - global outbound-proxy password: keyed by [globalProxyKey]
class ProxyPasswordSecureStorage {
  static const String _secureStorageKey = 'proxy_passwords';

  /// Reserved key used for the app-global outbound proxy. Site-id collisions
  /// are not possible — site ids are generated as random UUID-like strings,
  /// not literal `__global_outbound__`.
  static const String globalProxyKey = '__global_outbound__';

  final FlutterSecureStorage _secureStorage;
  bool _secureStorageAvailable = true;

  ProxyPasswordSecureStorage({FlutterSecureStorage? secureStorage})
      : _secureStorage = secureStorage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(
                  accessibility: KeychainAccessibility.first_unlock),
            );

  /// Loads every stored password as a `key -> password` map. Empty when
  /// secure storage has nothing for us, or when secure storage is
  /// unavailable on this platform.
  Future<Map<String, String>> loadAll() async {
    if (!_secureStorageAvailable) return {};
    try {
      final raw = await _secureStorage.read(key: _secureStorageKey);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k as String, v as String));
      }
    } catch (e) {
      LogService.instance.log(
        'ProxyPwdStore',
        'Failed to read proxy passwords from secure storage: $e',
        level: LogLevel.error,
      );
      _secureStorageAvailable = false;
    }
    return {};
  }

  /// Loads the password for a single key. Returns null when absent.
  Future<String?> loadPassword(String key) async {
    final all = await loadAll();
    return all[key];
  }

  /// Replace the entire `key -> password` map in secure storage.
  /// Empty values are stripped; an empty resulting map deletes the entry.
  Future<void> saveAll(Map<String, String?> passwords) async {
    if (!_secureStorageAvailable) return;
    final filtered = <String, String>{};
    passwords.forEach((k, v) {
      if (v != null && v.isNotEmpty) filtered[k] = v;
    });
    try {
      if (filtered.isEmpty) {
        await _secureStorage.delete(key: _secureStorageKey);
      } else {
        await _secureStorage.write(
          key: _secureStorageKey,
          value: jsonEncode(filtered),
        );
      }
    } catch (e) {
      LogService.instance.log(
        'ProxyPwdStore',
        'Failed to write proxy passwords to secure storage: $e',
        level: LogLevel.error,
      );
      _secureStorageAvailable = false;
    }
  }

  /// Set or clear the password for a single key. Pass null/empty to delete.
  Future<void> savePassword(String key, String? password) async {
    final all = await loadAll();
    if (password == null || password.isEmpty) {
      all.remove(key);
    } else {
      all[key] = password;
    }
    await saveAll(all);
  }

  /// Drop entries for keys not present in [activeKeys]. Mirrors
  /// [CookieSecureStorage.removeOrphanedCookies] — call after deleting sites
  /// or restoring a backup so we don't accumulate stale passwords for sites
  /// that no longer exist.
  Future<void> removeOrphaned(Set<String> activeKeys) async {
    final all = await loadAll();
    final removed = <String>[];
    for (final key in all.keys.toList()) {
      // Always preserve the global key; it's not tied to a site.
      if (key == globalProxyKey) continue;
      if (!activeKeys.contains(key)) {
        all.remove(key);
        removed.add(key);
      }
    }
    if (removed.isNotEmpty) {
      await saveAll(all);
      LogService.instance.log(
        'ProxyPwdStore',
        'Removed orphaned proxy passwords for keys: $removed',
        level: LogLevel.info,
      );
    }
  }

  /// One-shot migration helper: pull plaintext passwords out of a JSON map
  /// that came from SharedPreferences (e.g. an old `webViewModels` entry's
  /// `proxySettings` field, or the legacy `globalOutboundProxy` JSON), move
  /// them to secure storage, and rewrite the prefs entry without the
  /// password. Idempotent — running it again on already-migrated data is a
  /// no-op.
  ///
  /// Returns true when at least one password was migrated.
  Future<bool> migrateLegacyPassword({
    required SharedPreferences prefs,
    required String prefsKey,
    required String secureKey,
  }) async {
    final raw = prefs.getString(prefsKey);
    if (raw == null || raw.isEmpty) return false;
    Map<String, dynamic> decoded;
    try {
      final parsed = jsonDecode(raw);
      if (parsed is! Map<String, dynamic>) return false;
      decoded = parsed;
    } catch (_) {
      return false;
    }
    final password = decoded['password'];
    if (password is! String || password.isEmpty) return false;
    await savePassword(secureKey, password);
    decoded.remove('password');
    await prefs.setString(prefsKey, jsonEncode(decoded));
    LogService.instance.log(
      'ProxyPwdStore',
      'Migrated legacy plaintext password from prefs[$prefsKey] -> secure[$secureKey]',
      level: LogLevel.info,
    );
    return true;
  }
}
