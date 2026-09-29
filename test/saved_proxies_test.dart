import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/proxy_form_engine.dart';
import 'package:webspace/services/proxy_password_secure_storage.dart';
import 'package:webspace/services/settings_backup.dart';
import 'package:webspace/services/settings_import_engine.dart';
import 'package:webspace/services/site_settings_qr_codec.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/services/webview.dart' show userProxyToInappProxy;
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/saved_proxies.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/mock_secure_storage.dart';

SavedProxy _vpn({String password = 'vpn-secret'}) => SavedProxy(
      id: 'vpn',
      name: 'Work VPN',
      settings: UserProxySettings(
        type: ProxyType.SOCKS5,
        address: '10.8.0.1:1080',
        username: 'alice',
        password: password,
      ),
    );

UserProxySettings _names(String id) =>
    UserProxySettings(type: ProxyType.SAVED, savedProxyId: id);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SavedProxies.setInMemory([_vpn()]);
    GlobalOutboundProxy.resetForTest();
  });

  tearDown(() {
    SavedProxies.resetForTest();
    GlobalOutboundProxy.resetForTest();
  });

  group('resolution (PROXY-029)', () {
    test('a site naming a saved proxy takes its configuration', () {
      final route = resolveEffectiveProxy(_names('vpn'));
      expect(route.type, ProxyType.SOCKS5);
      expect(route.address, '10.8.0.1:1080');
      expect(route.username, 'alice');
      expect(route.password, 'vpn-secret');
    });

    test('an edit to the saved proxy moves every site that names it', () {
      final a = _names('vpn');
      final b = _names('vpn');
      SavedProxies.setInMemory([
        _vpn()..settings.address = '10.9.0.1:1080',
      ]);
      expect(resolveEffectiveProxy(a).address, '10.9.0.1:1080');
      expect(resolveEffectiveProxy(b).address, '10.9.0.1:1080');
    });

    test('a missing saved proxy fails closed, never through the global', () {
      GlobalOutboundProxy.setForTest(
          UserProxySettings(type: ProxyType.HTTP, address: '1.2.3.4:8080'));
      final route = resolveEffectiveProxy(_names('gone'));
      expect(route.type, ProxyType.SAVED);
      expect(route.address, isNull);
    });

    test('a DEFAULT site inherits a global that names a saved proxy', () {
      GlobalOutboundProxy.setForTest(_names('vpn'));
      final route =
          resolveEffectiveProxy(UserProxySettings(type: ProxyType.DEFAULT));
      expect(route.type, ProxyType.SOCKS5);
      expect(route.address, '10.8.0.1:1080');
    });

    test('a saved proxy does not reach a site that sets its own proxy', () {
      final own = UserProxySettings(
        type: ProxyType.HTTP,
        address: '5.6.7.8:3128',
        savedProxyId: 'vpn',
      );
      expect(resolveEffectiveProxy(own).address, '5.6.7.8:3128');
    });

    test('an unresolved reference ignores the manual address it kept', () {
      final stale = UserProxySettings(
        type: ProxyType.SAVED,
        savedProxyId: 'gone',
        address: '9.9.9.9:1080',
      );
      expect(resolveEffectiveProxy(stale).address, isNull);
    });
  });

  group('a site parting from its saved proxy (PROXY-029)', () {
    test('its own address keeps the saved type and credentials', () {
      final route = resolveEffectiveProxy(UserProxySettings(
        type: ProxyType.SAVED,
        savedProxyId: 'vpn',
        ownAddress: true,
        address: 'de.gw.example:1080',
        username: 'ignored',
      ));
      expect(route.type, ProxyType.SOCKS5);
      expect(route.address, 'de.gw.example:1080');
      expect(route.username, 'alice');
      expect(route.password, 'vpn-secret');
    });

    test('its own credentials keep the saved address', () {
      final route = resolveEffectiveProxy(UserProxySettings(
        type: ProxyType.SAVED,
        savedProxyId: 'vpn',
        ownCredentials: true,
        address: 'ignored:1',
        username: 'alice-session-mail',
        password: 'site-secret',
      ));
      expect(route.address, '10.8.0.1:1080');
      expect(route.username, 'alice-session-mail');
      expect(route.password, 'site-secret');
    });

    test('an own address left empty fails closed', () {
      final route = resolveEffectiveProxy(UserProxySettings(
        type: ProxyType.SAVED,
        savedProxyId: 'vpn',
        ownAddress: true,
      ));
      expect(route.address, isNull);
      expect(const DefaultOutboundHttpFactory().clientFor(route),
          isA<OutboundClientBlocked>());
    });

    test('an edit to the saved proxy still reaches what the site kept', () {
      final site = UserProxySettings(
        type: ProxyType.SAVED,
        savedProxyId: 'vpn',
        ownCredentials: true,
        username: 'mine',
      );
      SavedProxies.setInMemory([_vpn()..settings.address = '10.9.0.1:1080']);
      expect(resolveEffectiveProxy(site).address, '10.9.0.1:1080');
      expect(resolveEffectiveProxy(site).username, 'mine');
    });

    test('the flags round-trip and are only written when set', () {
      final json = UserProxySettings(
        type: ProxyType.SAVED,
        savedProxyId: 'vpn',
        ownCredentials: true,
      ).toJson();
      expect(json['ownCredentials'], true);
      expect(json.containsKey('ownAddress'), isFalse);
      final back = UserProxySettings.fromJson(json);
      expect(back.ownCredentials, isTrue);
      expect(back.ownAddress, isFalse);
    });

    test('a non-bool flag reads as off', () {
      final back = UserProxySettings.fromJson(
          {'type': ProxyType.SAVED.index, 'ownAddress': 'yes'});
      expect(back.ownAddress, isFalse);
    });

    test('a saved proxy entry cannot carry the flags itself', () {
      final raw = jsonEncode([
        {
          'id': 'x',
          'name': 'X',
          'proxy': {
            'type': ProxyType.HTTP.index,
            'address': 'a:1',
            'ownAddress': true,
            'ownCredentials': true,
          },
        },
      ]);
      final p = decodeSavedProxies(raw).single.settings;
      expect(p.ownAddress, isFalse);
      expect(p.ownCredentials, isFalse);
    });

    test('Android keeps sites with different credentials apart', () {
      final models = [
        WebViewModel(
          initUrl: 'https://mail.example.com/',
          proxySettings: UserProxySettings(
            type: ProxyType.SAVED,
            savedProxyId: 'vpn',
            ownCredentials: true,
            username: 'alice-session-mail',
          ),
        ),
        WebViewModel(initUrl: 'https://chat.example.com/', proxySettings: _names('vpn')),
      ];
      expect(
        SiteUnloadEngine.indicesToUnloadForProxyMismatch(
          targetIndex: 0,
          models: models,
          loadedIndices: {1},
          proxyIsGlobal: true,
        ),
        {1},
      );
    });

    test('a shared site carries its own username, never a password', () {
      final model = WebViewModel(
        initUrl: 'https://example.com/',
        proxySettings: UserProxySettings(
          type: ProxyType.SAVED,
          savedProxyId: 'vpn',
          ownCredentials: true,
          username: 'alice-session-mail',
          password: 'site-secret',
        ),
      );
      final shared = SiteSettingsQrCodec.shareableSubset(model.toJson());
      final proxy = shared['proxySettings'] as Map<String, dynamic>;
      expect(proxy['address'], '10.8.0.1:1080');
      expect(proxy['username'], 'alice-session-mail');
      expect(jsonEncode(shared), isNot(contains('secret')));
    });
  });

  group('every seam fails closed on a missing saved proxy', () {
    test('Dart HTTP blocks', () {
      final client = const DefaultOutboundHttpFactory().clientFor(_names('gone'));
      expect(client, isA<OutboundClientBlocked>());
    });

    test('Dart HTTP resolves a global handed over unresolved', () {
      final client = const DefaultOutboundHttpFactory().clientFor(_names('vpn'));
      expect(client, isA<OutboundClientReady>());
      (client as OutboundClientReady).client.close();
    });

    test('the native binding has no rule to install', () {
      expect(userProxyToInappProxy(_names('gone')), isNull);
    });

    test('the native binding installs the saved proxy', () {
      final rule = userProxyToInappProxy(_names('vpn'))!.proxyRules!.single;
      expect(rule.url, contains('socks5://'));
      expect(rule.url, contains('10.8.0.1:1080'));
    });
  });

  group('Android serialisation (PROXY-008)', () {
    List<WebViewModel> sites(List<UserProxySettings> proxies) => [
          for (final p in proxies)
            WebViewModel(initUrl: 'https://example.com/', proxySettings: p),
        ];

    test('two sites on one saved proxy load together', () {
      final models = sites([_names('vpn'), _names('vpn')]);
      expect(
        SiteUnloadEngine.indicesToUnloadForProxyMismatch(
          targetIndex: 0,
          models: models,
          loadedIndices: {1},
          proxyIsGlobal: true,
        ),
        isEmpty,
      );
    });

    test('a saved proxy and a direct site do not', () {
      final models = sites([
        _names('vpn'),
        UserProxySettings(type: ProxyType.DEFAULT),
      ]);
      expect(
        SiteUnloadEngine.indicesToUnloadForProxyMismatch(
          targetIndex: 0,
          models: models,
          loadedIndices: {1},
          proxyIsGlobal: true,
        ),
        {1},
      );
    });
  });

  group('serialisation', () {
    test('a site reference round-trips', () {
      final back = UserProxySettings.fromJson(_names('vpn').toJson());
      expect(back.type, ProxyType.SAVED);
      expect(back.savedProxyId, 'vpn');
    });

    test('the list never carries a password (PWD-005)', () {
      final encoded = encodeSavedProxies([_vpn()]);
      expect(encoded, isNot(contains('vpn-secret')));
      expect(decodeSavedProxies(encoded).single.settings.address,
          '10.8.0.1:1080');
    });

    test('a password written into the list is not read (BACKUP-011)', () {
      final raw = jsonEncode([
        {
          'id': 'x',
          'name': 'X',
          'proxy': {'type': ProxyType.HTTP.index, 'address': 'a:1', 'password': 'p'},
        },
      ]);
      expect(decodeSavedProxies(raw).single.settings.password, isNull);
    });

    test('unusable entries are dropped', () {
      final raw = jsonEncode([
        {'id': 'tor', 'name': 'T', 'proxy': {'type': ProxyType.TOR.index}},
        {'id': 'def', 'name': 'D', 'proxy': {'type': ProxyType.DEFAULT.index}},
        {'id': 'loop', 'name': 'L', 'proxy': {'type': ProxyType.SAVED.index}},
        {'name': 'no id', 'proxy': {'type': ProxyType.HTTP.index}},
        {'id': 'ok', 'name': 'OK', 'proxy': {'type': ProxyType.HTTPS.index, 'address': 'h:1'}},
        {'id': 'ok', 'name': 'dup', 'proxy': {'type': ProxyType.HTTP.index, 'address': 'h:2'}},
        'not a map',
      ]);
      final decoded = decodeSavedProxies(raw);
      expect(decoded.map((p) => p.id), ['ok']);
      expect(decoded.single.name, 'OK');
    });

    test('a malformed value reads as none', () {
      expect(decodeSavedProxies('{not json'), isEmpty);
      expect(decodeSavedProxies('{}'), isEmpty);
      expect(decodeSavedProxies(null), isEmpty);
    });

    test('the list is registered for backups', () {
      expect(kExportedAppPrefs[kSavedProxiesKey], kSavedProxiesDefault);
    });
  });

  group('storage (PWD-007)', () {
    late MockFlutterSecureStorage secure;
    late ProxyPasswordSecureStorage passwords;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      secure = MockFlutterSecureStorage();
      passwords = ProxyPasswordSecureStorage(secureStorage: secure);
      SavedProxies.setPasswordStoreForTest(passwords);
    });

    test('the password goes to secure storage, the rest to prefs', () async {
      await SavedProxies.update([_vpn()]);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kSavedProxiesKey), isNot(contains('vpn-secret')));
      expect(
        await passwords
            .loadPassword(ProxyPasswordSecureStorage.savedProxyKey('vpn')),
        'vpn-secret',
      );
    });

    test('initialize hydrates the password', () async {
      await SavedProxies.update([_vpn()]);
      SavedProxies.resetForTest();
      await SavedProxies.initialize();
      expect(SavedProxies.byId('vpn')!.settings.password, 'vpn-secret');
    });

    test('deleting a saved proxy deletes its password', () async {
      await SavedProxies.update([_vpn()]);
      await SavedProxies.update([]);
      expect(
        await passwords
            .loadPassword(ProxyPasswordSecureStorage.savedProxyKey('vpn')),
        isNull,
      );
    });

    test('an orphaned password is collected on startup', () async {
      await passwords.savePassword(
          ProxyPasswordSecureStorage.savedProxyKey('stale'), 'x');
      await SavedProxies.initialize();
      expect(
        await passwords
            .loadPassword(ProxyPasswordSecureStorage.savedProxyKey('stale')),
        isNull,
      );
    });

    test('site orphan cleanup leaves saved proxy passwords alone', () async {
      await SavedProxies.update([_vpn()]);
      await passwords.removeOrphaned({'some-site'});
      expect(
        await passwords
            .loadPassword(ProxyPasswordSecureStorage.savedProxyKey('vpn')),
        'vpn-secret',
      );
    });

    test('an import drops every saved proxy password', () async {
      await SavedProxies.update([_vpn()]);
      await SavedProxies.reloadAfterImport();
      expect(SavedProxies.byId('vpn')!.settings.password, isNull);
      expect(
        await passwords
            .loadPassword(ProxyPasswordSecureStorage.savedProxyKey('vpn')),
        isNull,
      );
    });
  });

  group('the proxy form (PROXY-019)', () {
    test('picking a saved proxy keeps the manual fields', () {
      final stored = UserProxySettings(
        type: ProxyType.SOCKS5,
        address: '127.0.0.1:1080',
        username: 'u',
        password: 'p',
      );
      final out = applyProxyForm(
        stored: stored,
        fields: const ProxyFormFields(
          type: ProxyType.SAVED,
          address: 'ignored:1',
          savedProxyId: 'vpn',
        ),
      );
      expect(out.type, ProxyType.SAVED);
      expect(out.savedProxyId, 'vpn');
      expect(out.address, '127.0.0.1:1080');
      expect(out.password, 'p');
    });

    test('an override field on screen is the truth', () {
      final stored = UserProxySettings(
        type: ProxyType.SOCKS5,
        address: '127.0.0.1:1080',
        username: 'old-user',
        password: 'old-pass',
      );
      final out = applyProxyForm(
        stored: stored,
        fields: const ProxyFormFields(
          type: ProxyType.SAVED,
          savedProxyId: 'vpn',
          ownCredentials: true,
          address: 'hidden:1',
          username: 'new-user',
          password: '',
        ),
      );
      expect(out.ownCredentials, isTrue);
      expect(out.ownAddress, isFalse);
      expect(out.username, 'new-user');
      expect(out.password, isNull);
      expect(out.address, '127.0.0.1:1080');
    });

    test('switching away keeps the reference for the way back', () {
      final out = applyProxyForm(
        stored: _names('vpn'),
        fields: const ProxyFormFields(type: ProxyType.HTTP, address: 'h:1'),
      );
      expect(out.type, ProxyType.HTTP);
      expect(out.savedProxyId, 'vpn');
    });
  });

  group('sharing a site by QR', () {
    test('the saved proxy travels as its own fields, without a password', () {
      final model =
          WebViewModel(initUrl: 'https://example.com/', proxySettings: _names('vpn'));
      final shared = SiteSettingsQrCodec.shareableSubset(model.toJson());
      final proxy = shared['proxySettings'] as Map<String, dynamic>;
      expect(proxy['type'], ProxyType.SOCKS5.index);
      expect(proxy['address'], '10.8.0.1:1080');
      expect(proxy.containsKey('savedProxyId'), isFalse);
      expect(jsonEncode(shared), isNot(contains('vpn-secret')));
    });

    test('a missing saved proxy shares no proxy', () {
      final model = WebViewModel(
          initUrl: 'https://example.com/', proxySettings: _names('gone'));
      final shared = SiteSettingsQrCodec.shareableSubset(model.toJson());
      expect(shared.containsKey('proxySettings'), isFalse);
    });

    test('a received payload naming a saved proxy is refused', () {
      final uri = SiteSettingsQrCodec.encode({
        'initUrl': 'https://example.com/',
        'proxySettings': {'type': ProxyType.SAVED.index, 'savedProxyId': 'vpn'},
      });
      expect(SiteSettingsQrCodec.decode(uri), isNull);
    });
  });

  group('import planning', () {
    SettingsBackup backup(Map<String, dynamic> prefs) => SettingsBackup(
          version: 1,
          sites: const [],
          webspaces: const [],
          themeMode: 0,
          globalPrefs: prefs,
          exportedAt: DateTime(2026),
        );

    test('an app-wide proxy naming a saved proxy shows its address', () {
      final b = backup({
        kGlobalOutboundProxyKey: jsonEncode(_names('vpn').toJson()),
        kSavedProxiesKey: encodeSavedProxies([_vpn()]),
      });
      expect(backupGlobalProxyAddress(b), '10.8.0.1:1080');
    });
  });
}
