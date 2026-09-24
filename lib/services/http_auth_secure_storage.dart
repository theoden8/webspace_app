import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:webspace/services/http_auth_engine.dart';
import 'package:webspace/services/log_service.dart';

/// Saved HTTP authentication credentials (HTTPAUTH-004, HTTPAUTH-005).
///
/// Same shape as [ProxyPasswordSecureStorage]: one `flutter_secure_storage`
/// entry holding a JSON map, here `siteId -> [{host, realm, username,
/// password}]`. Nothing about these credentials lives on [WebViewModel], so
/// no `toJson`, backup or QR path can carry them.
///
/// Credentials are never handed to the platform's own credential store
/// (`permanentPersistence: false`): that store is app-wide rather than per
/// site, so one site's saved password would answer another site's
/// challenge for the same host.
class HttpAuthSecureStorage implements HttpAuthCredentialStore {
  static const String _secureStorageKey = 'http_auth_credentials';

  static final HttpAuthSecureStorage instance = HttpAuthSecureStorage();

  final FlutterSecureStorage _secureStorage;
  bool _secureStorageAvailable = true;

  /// Serializes every read-modify-write of the single entry, so a save from
  /// one webview's prompt cannot drop a concurrent save from another's.
  Future<void> _writeLock = Future<void>.value();

  HttpAuthSecureStorage({FlutterSecureStorage? secureStorage})
      : _secureStorage = secureStorage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(
                  accessibility: KeychainAccessibility.first_unlock),
            );

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final result = _writeLock.then((_) => action());
    _writeLock = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<Map<String, List<Map<String, String>>>> _loadAll() async {
    if (!_secureStorageAvailable) return {};
    try {
      final raw = await _secureStorage.read(key: _secureStorageKey);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final out = <String, List<Map<String, String>>>{};
      decoded.forEach((siteId, entries) {
        if (siteId is! String || entries is! List) return;
        final list = <Map<String, String>>[];
        for (final e in entries) {
          if (e is! Map) continue;
          final host = e['host'], realm = e['realm'];
          final username = e['username'], password = e['password'];
          if (host is! String || realm is! String) continue;
          if (username is! String || password is! String) continue;
          list.add({
            'host': host,
            'realm': realm,
            'username': username,
            'password': password,
          });
        }
        if (list.isNotEmpty) out[siteId] = list;
      });
      return out;
    } catch (e) {
      LogService.instance.log(
        'HttpAuthStore',
        'Failed to read saved sign-ins from secure storage: $e',
        level: LogLevel.error,
      );
      _secureStorageAvailable = false;
      return {};
    }
  }

  Future<void> _saveAll(Map<String, List<Map<String, String>>> all) async {
    if (!_secureStorageAvailable) return;
    all.removeWhere((_, entries) => entries.isEmpty);
    try {
      if (all.isEmpty) {
        await _secureStorage.delete(key: _secureStorageKey);
      } else {
        await _secureStorage.write(
          key: _secureStorageKey,
          value: jsonEncode(all),
        );
      }
    } catch (e) {
      LogService.instance.log(
        'HttpAuthStore',
        'Failed to write saved sign-ins to secure storage: $e',
        level: LogLevel.error,
      );
      _secureStorageAvailable = false;
    }
  }

  Future<void> _mutate(
    void Function(Map<String, List<Map<String, String>>> draft) update,
  ) {
    return _synchronized(() async {
      final draft = await _loadAll();
      update(draft);
      await _saveAll(draft);
    });
  }

  static bool _sameSpace(Map<String, String> e, String host, String realm) =>
      e['host'] == host && e['realm'] == realm;

  @override
  Future<HttpAuthCredential?> lookup(
    String siteId,
    String host,
    String realm,
  ) async {
    final entries = (await _loadAll())[siteId];
    if (entries == null) return null;
    for (final e in entries) {
      if (_sameSpace(e, host, realm)) {
        return HttpAuthCredential(
          username: e['username']!,
          password: e['password']!,
        );
      }
    }
    return null;
  }

  @override
  Future<void> save(
    String siteId,
    String host,
    String realm,
    HttpAuthCredential credential,
  ) {
    return _mutate((draft) {
      final entries = draft.putIfAbsent(siteId, () => []);
      entries.removeWhere((e) => _sameSpace(e, host, realm));
      entries.add({
        'host': host,
        'realm': realm,
        'username': credential.username,
        'password': credential.password,
      });
    });
  }

  @override
  Future<void> remove(String siteId, String host, String realm) {
    return _mutate((draft) {
      draft[siteId]?.removeWhere((e) => _sameSpace(e, host, realm));
    });
  }

  /// How many protection spaces [siteId] has a saved credential for.
  Future<int> countForSite(String siteId) async =>
      (await _loadAll())[siteId]?.length ?? 0;

  /// Forget every saved credential for [siteId].
  Future<void> removeSite(String siteId) =>
      _mutate((draft) => draft.remove(siteId));

  /// Drop entries for sites not in [activeSiteIds]. Saved sign-ins are
  /// configuration, so they are measured against every live site, incognito
  /// ones included.
  Future<void> removeOrphaned(Set<String> activeSiteIds) async {
    final removed = <String>[];
    await _mutate((draft) {
      for (final siteId in draft.keys.toList()) {
        if (!activeSiteIds.contains(siteId)) {
          draft.remove(siteId);
          removed.add(siteId);
        }
      }
    });
    if (removed.isNotEmpty) {
      LogService.instance.log(
        'HttpAuthStore',
        'Removed orphaned saved sign-ins for sites: $removed',
        level: LogLevel.info,
        sensitivity: LogSensitivity.sensitive,
      );
    }
  }
}
