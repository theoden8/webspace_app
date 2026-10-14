import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/services/keystore.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/settings/proxy_ids.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/utils/concurrency.dart';

/// Whose password an entry of the store holds: a site's, the app-wide
/// proxy's, or a proxy library entry's. The reserved keys cannot equal a
/// site's, since no site id begins with `__` (PWD-008).
extension type const ProxyPasswordKey._(String raw) implements String {
  ProxyPasswordKey.site(SiteId site) : raw = site;

  static const global = ProxyPasswordKey._('__global_outbound__');

  ProxyPasswordKey.savedProxy(SavedProxyId id) : raw = '$_savedProxyPrefix$id';

  ProxyPasswordKey.credentials(CredentialsId id)
      : raw = '$_savedCredentialsPrefix$id';

  static const String _savedProxyPrefix = '__saved_proxy__:';
  static const String _savedCredentialsPrefix = '__saved_credentials__:';

  /// Owned by `ProxyLibrary`, which collects its own orphans.
  bool get isLibrary =>
      raw.startsWith(_savedProxyPrefix) ||
      raw.startsWith(_savedCredentialsPrefix);
}

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
/// Keyed by [ProxyPasswordKey].
class ProxyPasswordSecureStorage {
  static const String _secureStorageKey = 'proxy_passwords';

  /// Static so it is shared across instances: the app keeps two separate
  /// stores (per-site via `_WebSpacePageState`, global via
  /// `GlobalOutboundProxy`) that both write this key, and an unsynchronized
  /// load-modify-save on one would otherwise clobber a concurrent write from
  /// the other (silently dropping a just-saved proxy password).
  static final SerialQueue _writes = SerialQueue();

  final SecureJsonStore<Map<ProxyPasswordKey, String>> _store;

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

  // Every key was written as a ProxyPasswordKey.
  static Map<ProxyPasswordKey, String> _decode(Object? json) => {
        if (json is Map)
          for (final MapEntry(:key, :value) in json.entries)
            if (key is String && value is String && value.isNotEmpty)
              ProxyPasswordKey._(key): value,
      };

  static Map<ProxyPasswordKey, String> _nonEmpty(
          Map<ProxyPasswordKey, String?> passwords) => {
        for (final MapEntry(:key, :value) in passwords.entries)
          if (value != null && value.isNotEmpty) key: value,
      };

  /// Every stored password as a `key -> password` map. Empty when there is
  /// none or the keystore is unavailable.
  Future<Map<ProxyPasswordKey, String>> loadAll() => _store.read();

  Future<String?> loadPassword(ProxyPasswordKey key) async =>
      (await loadAll())[key];

  /// Read the stored map, apply [update] to a mutable draft, and write the
  /// result back as one critical section. Set a key to null to delete it.
  Future<void> mutate(
          void Function(Map<ProxyPasswordKey, String?> draft) update) =>
      _store.update((current) {
        final draft = <ProxyPasswordKey, String?>{...current};
        update(draft);
        return _nonEmpty(draft);
      });

  /// Set or clear the password for a single key. Pass null/empty to delete.
  Future<void> savePassword(ProxyPasswordKey key,
          {required String? password}) =>
      mutate((draft) => draft[key] = password);

  /// Drop the sites' entries for sites not in [activeSites], after deleting
  /// sites or restoring a backup. The global key and proxy library keys are
  /// kept: they belong to no site, and `ProxyLibrary` collects its own
  /// orphans.
  Future<void> removeOrphaned(Set<SiteId> activeSites) => _store.removeOrphans(
        activeSites,
        what: 'proxy passwords',
        pinned: (key) => key == ProxyPasswordKey.global || key.isLibrary,
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
    required ProxyPasswordKey secureKey,
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
    await savePassword(secureKey, password: password);
    decoded.remove('password');
    await prefs.setString(prefsKey, jsonEncode(decoded));
    LogTag.proxyPwdStore.info(
        'Migrated legacy plaintext password from prefs[$prefsKey] -> secure[$secureKey]',
        sensitive: true);
    return true;
  }
}
