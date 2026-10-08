import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/services/keystore.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/utils/concurrency.dart';

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
/// - proxy library passwords: [savedProxyKey] for a saved proxy's typed
///   password, [savedCredentialsKey] for saved credentials; both owned by
///   `ProxyLibrary`
class ProxyPasswordSecureStorage {
  static const String _secureStorageKey = 'proxy_passwords';

  /// Reserved key used for the app-global outbound proxy. Site-id collisions
  /// are not possible — site ids are generated as random UUID-like strings,
  /// not literal `__global_outbound__`.
  static const String globalProxyKey = '__global_outbound__';

  static const String _savedProxyPrefix = '__saved_proxy__:';
  static const String _savedCredentialsPrefix = '__saved_credentials__:';

  /// Keys for proxy library passwords. The prefixes cannot collide with a
  /// site id for the same reason [globalProxyKey] cannot.
  static String savedProxyKey(String id) => '$_savedProxyPrefix$id';
  static String savedCredentialsKey(String id) =>
      '$_savedCredentialsPrefix$id';

  static bool isLibraryKey(String key) =>
      key.startsWith(_savedProxyPrefix) ||
      key.startsWith(_savedCredentialsPrefix);

  /// Static so it is shared across instances: the app keeps two separate
  /// stores (per-site via `_WebSpacePageState`, global via
  /// `GlobalOutboundProxy`) that both write this key, and an unsynchronized
  /// load-modify-save on one would otherwise clobber a concurrent write from
  /// the other (silently dropping a just-saved proxy password).
  static final SerialQueue _writes = SerialQueue();

  final SecureJsonStore<Map<String, String>> _store;

  ProxyPasswordSecureStorage({FlutterSecureStorage? secureStorage})
      : _store = SecureJsonStore(
          keystore: secureStorage ?? Keystores.credentials,
          key: _secureStorageKey,
          logTag: LogTag.proxyPwdStore,
          decode: _decode,
          encode: (passwords) => passwords,
          isEmpty: (passwords) => passwords.isEmpty,
          onFailure: KeystoreFailurePolicy.stopUsing,
          queue: _writes,
        );

  static Map<String, String> _decode(Object? json) => {
        if (json is Map)
          for (final MapEntry(:key, :value) in json.entries)
            if (key is String && value is String && value.isNotEmpty)
              key: value,
      };

  static Map<String, String> _nonEmpty(Map<String, String?> passwords) => {
        for (final MapEntry(:key, :value) in passwords.entries)
          if (value != null && value.isNotEmpty) key: value,
      };

  /// Every stored password as a `key -> password` map. Empty when there is
  /// none or the keystore is unavailable.
  Future<Map<String, String>> loadAll() => _store.read();

  Future<String?> loadPassword(String key) async => (await loadAll())[key];

  /// Read the stored map, apply [update] to a mutable draft, and write the
  /// result back as one critical section. Set a key to null to delete it.
  Future<void> mutate(void Function(Map<String, String?> draft) update) =>
      _store.update((current) {
        final draft = <String, String?>{...current};
        update(draft);
        return _nonEmpty(draft);
      });

  /// Set or clear the password for a single key. Pass null/empty to delete.
  Future<void> savePassword(String key, String? password) =>
      mutate((draft) => draft[key] = password);

  /// Drop entries for keys not in [activeKeys], after deleting sites or
  /// restoring a backup. The global key and proxy library keys are kept:
  /// they belong to no site, and `ProxyLibrary` collects its own orphans.
  Future<void> removeOrphaned(Set<String> activeKeys) => _store.removeOrphans(
        activeKeys,
        what: 'proxy passwords',
        pinned: (key) => key == globalProxyKey || isLibraryKey(key),
      );

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
    final Map<String, dynamic> decoded;
    try {
      final parsed = jsonDecode(raw);
      if (parsed is! Map<String, dynamic>) return false;
      decoded = parsed;
    } on FormatException {
      return false;
    }
    final password = decoded['password'];
    if (password is! String || password.isEmpty) return false;
    await savePassword(secureKey, password);
    decoded.remove('password');
    await prefs.setString(prefsKey, jsonEncode(decoded));
    LogTag.proxyPwdStore.info(
        'Migrated legacy plaintext password from prefs[$prefsKey] -> secure[$secureKey]',
        sensitive: true);
    return true;
  }
}
