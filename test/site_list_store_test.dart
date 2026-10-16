import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/settings/site_ids.dart';
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

  // Two site-set commits can run at once (SiteSettingsClosed and
  // SiteSettingsSaved after one Save). They take no lock between them, which
  // would sit in a cycle with the tab gate the commit's own steps take; the
  // save converges instead, since it reads the live list only once the saves
  // before it have written.
  test('two overlapping saves leave the later state, whatever applied between',
      () async {
    SharedPreferences.setMockInitialValues({});
    final a = WebViewModel(initUrl: 'https://a.example.com', name: 'A');
    final b = WebViewModel(initUrl: 'https://b.example.com', name: 'B');
    final models = [a];
    final first = store.save(models);
    models.add(b);
    a.name = 'A renamed';
    final second = store.save(models);
    await Future.wait([first, second]);

    final json = (await SharedPreferences.getInstance())
        .getStringList('webViewModels')!;
    expect([for (final j in json) (jsonDecode(j) as Map)['name']],
        ['A renamed', 'B']);
  });

  test('nothing persisted reads as no sites and nothing to write back',
      () async {
    SharedPreferences.setMockInitialValues({});
    final loaded = await store.load(onChange: () {});
    expect(loaded.sites, isEmpty);
    expect(loaded.needsResave, isFalse);
  });

  // PWD-001, PWD-002
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
    expect(await passwords.loadPassword(ProxyPasswordKey.site(kept.siteId)),
        'secret');
    expect(
        await passwords.loadPassword(ProxyPasswordKey.site(archived.siteId)),
        isNull);

    final loaded = await store.load(onChange: () {});
    expect(loaded.needsResave, isTrue);
    expect(loaded.sites.single.siteId, kept.siteId);
    expect(loaded.sites.single.proxySettings.password, 'secret',
        reason: 'hydrated from secure storage');
  });

  // PWD-003
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
    final siteId = SiteId(legacy['siteId'] as String);
    expect(await passwords.loadPassword(ProxyPasswordKey.site(siteId)),
        'legacy');
    final rewritten = (await SharedPreferences.getInstance())
        .getStringList('webViewModels')!;
    expect(rewritten.join(), isNot(contains('legacy')),
        reason: 'the plaintext copy is stripped from prefs');
  });

  test('a site stored under a reserved key is no site: its legacy password '
      'never reaches the app-wide proxy (PWD-008, SEC-028)', () async {
    final legacy = WebViewModel(initUrl: 'https://a.example.com').toJson()
      ..['siteId'] = ProxyPasswordKey.global
      ..['proxySettings'] = {
        'type': ProxyType.HTTP.index,
        'address': 'proxy.example:8080',
        'password': 'planted',
      };
    SharedPreferences.setMockInitialValues({
      'webViewModels': [jsonEncode(legacy)],
    });

    final loaded = await store.load(onChange: () {});
    expect(loaded.sites.single.siteId, isNot(ProxyPasswordKey.global));
    expect(await passwords.loadPassword(ProxyPasswordKey.global), isNull);
  });
}
