import 'package:webspace/services/http_auth_engine.dart';
import 'package:webspace/services/url_host.dart';
import 'package:webspace/settings/site_ids.dart';

/// Models the store's contract: one credential per (siteId, host, realm).
class MemoryHttpAuthStore implements HttpAuthCredentialStore {
  final Map<String, HttpAuthCredential> entries = {};
  int lookups = 0;

  static String _key(SiteId siteId,
          {required String host, required String realm}) =>
      '$siteId|$host|$realm';

  @override
  Future<HttpAuthCredential?> lookup(
      SiteId siteId, {required Host host, required String realm}) async {
    lookups++;
    return entries[_key(siteId, host: host, realm: realm)];
  }

  @override
  Future<void> save(SiteId siteId, {required Host host, required String realm,
      required HttpAuthCredential credential}) async {
    entries[_key(siteId, host: host, realm: realm)] = credential;
  }

  @override
  Future<void> remove(SiteId siteId,
      {required Host host, required String realm}) async {
    entries.remove(_key(siteId, host: host, realm: realm));
  }
}
