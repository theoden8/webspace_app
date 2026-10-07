import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/cookie_secure_storage.dart';
import 'package:webspace/services/proxy_password_secure_storage.dart';
import 'package:webspace/controllers/site_list_store.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/mock_secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProxyPasswordSecureStorage passwords;
  late SiteListStore store;

  setUp(() {
    final secure = MockFlutterSecureStorage();
    passwords = ProxyPasswordSecureStorage(secureStorage: secure);
    store = SiteListStore(
      cookies: CookieSecureStorage(secureStorage: secure),
      proxyPasswords: passwords,
    );
  });

  test('nothing persisted reads as no sites and nothing to write back',
      () async {
    SharedPreferences.setMockInitialValues({});
    final loaded = await store.load(onChange: () {});
    expect(loaded.sites, isEmpty);
    expect(loaded.needsResave, isFalse);
  });

  test('a save reads back without archive-tier sites or proxy passwords in '
      'the site JSON (ARCH-001, PWD-005)', () async {
    SharedPreferences.setMockInitialValues({});
    final kept = WebViewModel(
      initUrl: 'https://a.example.com',
      name: 'A',
      proxySettings: UserProxySettings(
        type: ProxyType.HTTP,
        address: 'proxy.example:8080',
        username: 'u',
        password: 'secret',
      ),
    );
    final archived =
        WebViewModel(initUrl: 'https://b.example.com', isArchiveTier: true);
    await store.save([kept, archived]);

    final json = (await SharedPreferences.getInstance())
        .getStringList('webViewModels')!;
    expect(json, hasLength(1));
    expect(json.single, isNot(contains('secret')));
    expect(await passwords.loadPassword(kept.siteId), 'secret');
    expect(await passwords.loadPassword(archived.siteId), isNull);

    final loaded = await store.load(onChange: () {});
    expect(loaded.needsResave, isTrue);
    expect(loaded.sites.single.siteId, kept.siteId);
    expect(loaded.sites.single.proxySettings.password, 'secret',
        reason: 'hydrated from secure storage');
  });

  test('a legacy plaintext proxy password moves to secure storage and a '
      'malformed site is dropped', () async {
    final legacy = WebViewModel(initUrl: 'https://a.example.com').toJson();
    legacy['proxySettings'] = {
      'type': ProxyType.HTTP.index,
      'address': 'proxy.example:8080',
      'password': 'legacy',
    };
    SharedPreferences.setMockInitialValues({
      'webViewModels': [jsonEncode(legacy), '{not json'],
    });

    final loaded = await store.load(onChange: () {});
    expect(loaded.sites, hasLength(1));
    final siteId = legacy['siteId'] as String;
    expect(await passwords.loadPassword(siteId), 'legacy');
    final rewritten = (await SharedPreferences.getInstance())
        .getStringList('webViewModels')!;
    expect(rewritten.join(), isNot(contains('legacy')),
        reason: 'the plaintext copy is stripped from prefs');
  });
}
