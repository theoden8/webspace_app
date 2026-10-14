import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/proxy_password_secure_storage.dart';
import 'package:webspace/services/proxy_router_engine.dart';
import 'package:webspace/services/tor_engine.dart';
import 'package:webspace/services/tor_geoip.dart';
import 'package:webspace/settings/proxy_ids.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';

/// Every key that shares a namespace with site ids, which no site id may
/// equal (PWD-008, SEC-028).
final _reserved = <String>[
  ProxyPasswordKey.global,
  ProxyPasswordKey.savedProxy(SavedProxyId('a')),
  ProxyPasswordKey.credentials(CredentialsId('a')),
  RouterIdentity.shared,
  kTorAppGlobalTag,
  kTorGeoIpTag,
];

void main() {
  test('no reserved key reads as a site id', () {
    for (final key in _reserved) {
      expect(SiteId.parse(key), isNull, reason: key);
    }
  });

  test('a minted id reads back as itself', () {
    for (var i = 0; i < 100; i++) {
      final id = SiteId.mint();
      expect(SiteId.parse(id), id);
    }
  });

  test('a stored site named after a reserved key gets a fresh id', () {
    for (final key in _reserved) {
      final m = WebViewModel.fromJson(
        {'initUrl': 'https://a.test/', 'siteId': key},
        stateSetterF: () {},
      );
      expect(m.siteId, isNot(key), reason: key);
      expect(SiteId.parse(m.siteId), m.siteId, reason: key);
    }
  });
}
