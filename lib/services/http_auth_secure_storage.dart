import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:webspace/services/http_auth_engine.dart';
import 'package:webspace/services/keystore.dart';
import 'package:webspace/utils/concurrency.dart';

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

  /// Per instance: every webview's prompt goes through [instance], so its
  /// queue already keeps one save from dropping a concurrent other.
  final SecureJsonStore<Map<String, List<_Saved>>> _store;

  HttpAuthSecureStorage({FlutterSecureStorage? secureStorage})
      : _store = SecureJsonStore(
          keystore: secureStorage ?? Keystores.credentials,
          key: _secureStorageKey,
          logTag: 'HttpAuthStore',
          decode: _decode,
          encode: (all) => {
            for (final MapEntry(:key, :value) in all.entries)
              key: [for (final saved in value) saved.toJson()],
          },
          isEmpty: (all) => all.isEmpty,
          onFailure: KeystoreFailurePolicy.stopUsing,
          queue: SerialQueue(),
        );

  static Map<String, List<_Saved>> _decode(Object? json) {
    final out = <String, List<_Saved>>{};
    if (json is! Map) return out;
    for (final MapEntry(:key, :value) in json.entries) {
      if (key is! String || value is! List) continue;
      final list = [
        for (final e in value)
          if (e
              case {
                'host': final String host,
                'realm': final String realm,
                'username': final String username,
                'password': final String password,
              })
            _Saved(host, realm,
                HttpAuthCredential(username: username, password: password)),
      ];
      if (list.isNotEmpty) out[key] = list;
    }
    return out;
  }

  Future<void> _mutate(
    void Function(Map<String, List<_Saved>> draft) update,
  ) =>
      _store.update((draft) {
        update(draft);
        return draft..removeWhere((_, entries) => entries.isEmpty);
      });

  @override
  Future<HttpAuthCredential?> lookup(
    String siteId,
    String host,
    String realm,
  ) async {
    for (final saved in (await _store.read())[siteId] ?? const <_Saved>[]) {
      if (saved.covers(host, realm)) return saved.credential;
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
      draft.putIfAbsent(siteId, () => [])
        ..removeWhere((e) => e.covers(host, realm))
        ..add(_Saved(host, realm, credential));
    });
  }

  @override
  Future<void> remove(String siteId, String host, String realm) {
    return _mutate((draft) {
      draft[siteId]?.removeWhere((e) => e.covers(host, realm));
    });
  }

  /// How many protection spaces [siteId] has a saved credential for.
  Future<int> countForSite(String siteId) async =>
      (await _store.read())[siteId]?.length ?? 0;

  /// Forget every saved credential for [siteId].
  Future<void> removeSite(String siteId) =>
      _mutate((draft) => draft.remove(siteId));

  /// Drop entries for sites not in [activeSiteIds]. Saved sign-ins are
  /// configuration, so they are measured against every live site, incognito
  /// ones included.
  Future<void> removeOrphaned(Set<String> activeSiteIds) =>
      _store.removeOrphans(activeSiteIds, what: 'saved sign-ins');
}

/// One protection space's saved credential.
class _Saved {
  _Saved(this.host, this.realm, this.credential);

  final String host;
  final String realm;
  final HttpAuthCredential credential;

  bool covers(String host, String realm) =>
      this.host == host && this.realm == realm;

  Map<String, String> toJson() => {
        'host': host,
        'realm': realm,
        'username': credential.username,
        'password': credential.password,
      };
}
