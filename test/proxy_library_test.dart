import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/proxy_binding_engine.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/settings/proxy_ids.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/proxy_form_engine.dart';
import 'package:webspace/services/proxy_password_secure_storage.dart';
import 'package:webspace/services/settings_backup.dart';
import 'package:webspace/services/settings_import_engine.dart';
import 'package:webspace/services/site_settings_qr_codec.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/services/proxy_library.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/mock_secure_storage.dart';
import 'package:webspace/services/webview_proxy.dart';

/// Two gateways of one provider, an account that works on both, a session
/// login for one of them, a saved proxy built from shared entries, and a
/// plain one with both halves typed.
ProxyLibraryData _library() => ProxyLibraryData(
      gateways: [
        SavedGateway(
            id: GatewayId('us'), name: 'US', type: ProxyType.SOCKS5, address: 'us.gw:1080'),
        SavedGateway(
            id: GatewayId('de'), name: 'DE', type: ProxyType.SOCKS5, address: 'de.gw:1080'),
      ],
      credentials: [
        SavedCredentials(
            id: CredentialsId('alice'),
            name: 'Alice',
            username: 'alice',
            password: 'alice-secret',
            gatewayIds: {GatewayId('us'), GatewayId('de')}),
        SavedCredentials(
            id: CredentialsId('mail'),
            name: 'Mail session',
            username: 'alice-session-mail',
            password: 'mail-secret',
            gatewayIds: {GatewayId('de')}),
      ],
      proxies: [
        SavedProxy(
          id: SavedProxyId('work'),
          name: 'Work VPN',
          settings: UserProxySettings(
              type: ProxyType.GATEWAY, gatewayId: GatewayId('us'), credentialsId: CredentialsId('alice')),
        ),
        SavedProxy(
          id: SavedProxyId('plain'),
          name: 'Plain',
          settings: UserProxySettings(
            type: ProxyType.HTTP,
            address: '10.0.0.1:3128',
            username: 'u',
            password: 'plain-secret',
          ),
        ),
      ],
    );

UserProxySettings _proxy(SavedProxyId id) =>
    UserProxySettings(type: ProxyType.SAVED, savedProxyId: id);

UserProxySettings _gateway(GatewayId id, {CredentialsId? credentialsId}) =>
    UserProxySettings(
        type: ProxyType.GATEWAY, gatewayId: id, credentialsId: credentialsId);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    ProxyLibrary.setInMemory(_library());
    GlobalOutboundProxy.resetForTest();
  });

  tearDown(() {
    ProxyLibrary.resetForTest();
    GlobalOutboundProxy.resetForTest();
  });

  group('resolution (PROXY-030)', () {
    test('a saved proxy of shared entries takes both', () {
      final route = resolveEffectiveProxy(_proxy(SavedProxyId('work')), siteId: null);
      expect(route.type, ProxyType.SOCKS5);
      expect(route.address, 'us.gw:1080');
      expect(route.username, 'alice');
      expect(route.password, 'alice-secret');
    });

    test('a plain saved proxy is just its fields', () {
      final route = resolveEffectiveProxy(_proxy(SavedProxyId('plain')), siteId: null);
      expect(route.type, ProxyType.HTTP);
      expect(route.address, '10.0.0.1:3128');
      expect(route.password, 'plain-secret');
    });

    test('a site picks a gateway and credentials that list it', () {
      final route = resolveEffectiveProxy(
        _gateway(GatewayId('de'), credentialsId: CredentialsId('mail')),
        siteId: null,
      );
      expect(route.address, 'de.gw:1080');
      expect(route.username, 'alice-session-mail');
    });

    test('a site on a saved gateway can type its own credentials', () {
      final route = resolveEffectiveProxy(UserProxySettings(
        type: ProxyType.GATEWAY,
        gatewayId: GatewayId('de'),
        username: 'typed',
        password: 'typed-secret',
      ), siteId: null);
      expect(route.address, 'de.gw:1080');
      expect(route.username, 'typed');
    });

    test('a plain typed proxy is untouched', () {
      final own = UserProxySettings(type: ProxyType.SOCKS5, address: 'a:1');
      expect(identical(resolveEffectiveProxy(own, siteId: null), own), isTrue);
    });

    test('an edit to a shared entry reaches everything that uses it', () {
      final lib = _library();
      lib.gateway(GatewayId('us'))!.address = 'us2.gw:1080';
      lib.credentialsById(CredentialsId('alice'))!.password = 'rotated';
      ProxyLibrary.setInMemory(lib);
      final route = resolveEffectiveProxy(_proxy(SavedProxyId('work')), siteId: null);
      expect(route.address, 'us2.gw:1080');
      expect(route.password, 'rotated');
    });

    test('a DEFAULT site inherits an app-wide proxy from the library', () {
      GlobalOutboundProxy.setInMemory(_gateway(GatewayId('de'), credentialsId: CredentialsId('mail')));
      final route =
          resolveEffectiveProxy(UserProxySettings(type: ProxyType.DEFAULT),
              siteId: null);
      expect(route.address, 'de.gw:1080');
      expect(route.username, 'alice-session-mail');
    });
  });

  group('fails closed, never through the global or direct', () {
    setUp(() {
      GlobalOutboundProxy.setInMemory(
          UserProxySettings(type: ProxyType.HTTP, address: '1.2.3.4:8080'));
    });

    void blocked(UserProxySettings s, {required LibraryProblem problem}) {
      final resolved = resolveLibrary(s);
      expect(resolved.problem, problem);
      expect(resolved.route.type, ProxyType.SAVED);
      expect(resolveEffectiveProxy(s, siteId: null).address, isNull);
      expect(const DefaultOutboundHttpFactory().clientFor(s),
          isA<OutboundClientBlocked>());
      expect(
        userProxyToInappProxy(resolveEffectiveProxy(s, siteId: null)),
        isNull,
      );
    }

    test('a missing saved proxy', () {
      blocked(_proxy(SavedProxyId('gone')), problem: LibraryProblem.proxyMissing);
    });

    test('a missing gateway', () {
      blocked(_gateway(GatewayId('gone')), problem: LibraryProblem.gatewayMissing);
    });

    test('missing credentials', () {
      blocked(_gateway(GatewayId('de'), credentialsId: CredentialsId('gone')),
          problem: LibraryProblem.credentialsMissing);
    });

    test('credentials paired with a gateway they do not list', () {
      blocked(_gateway(GatewayId('us'), credentialsId: CredentialsId('mail')),
          problem: LibraryProblem.credentialsMismatch);
    });

    test('saved credentials on a typed gateway', () {
      blocked(
        UserProxySettings(
            type: ProxyType.SOCKS5, address: 'x:1', credentialsId: CredentialsId('alice')),
        problem: LibraryProblem.credentialsMismatch,
      );
    });

    test('a saved proxy whose gateway was deleted', () {
      final lib = _library()..removeGateway(GatewayId('us'));
      ProxyLibrary.setInMemory(lib);
      blocked(_proxy(SavedProxyId('work')), problem: LibraryProblem.gatewayMissing);
      expect(lib.credentialsById(CredentialsId('alice'))!.gatewayIds, {'de'});
    });

    test('a reference keeps no leftover manual address', () {
      final s = _gateway(GatewayId('gone'))..address = '9.9.9.9:1080';
      expect(resolveEffectiveProxy(s, siteId: null).address, isNull);
    });
  });

  group('Android serialisation (PROXY-008)', () {
    Set<int> unload(List<UserProxySettings> proxies) {
      final sites = [
        for (final p in proxies)
          WebViewModel(initUrl: 'https://example.com/', proxySettings: p),
      ];
      return SiteUnloadEngine.indicesToUnloadForProxyMismatch(
        targetIndex: 0,
        sites: sites,
        models: sites,
        loadedIndices: {for (var i = 1; i < proxies.length; i++) i},
        topology: ProxyTopology.of(
            binding: ProxyBinding.processWide, routerActive: false,
            sharesDefaultSession: (_) => false),
      );
    }

    test('sites on one saved proxy load together', () {
      expect(unload([_proxy(SavedProxyId('work')), _proxy(SavedProxyId('work'))]), isEmpty);
    });

    test('a saved proxy and its own entries picked directly are one route', () {
      expect(
          unload([_proxy(SavedProxyId('work')), _gateway(GatewayId('us'), credentialsId: CredentialsId('alice'))]),
          isEmpty);
    });

    test('one gateway with different credentials is two routes', () {
      expect(
          unload([
            _gateway(GatewayId('de'), credentialsId: CredentialsId('mail')),
            _gateway(GatewayId('de'), credentialsId: CredentialsId('alice')),
          ]),
          {1});
    });
  });

  group('serialisation', () {
    test('site references round-trip', () {
      final back = UserProxySettings.fromJson(
          _gateway(GatewayId('de'), credentialsId: CredentialsId('mail')).toJson());
      expect(back.type, ProxyType.GATEWAY);
      expect(back.gatewayId, 'de');
      expect(back.credentialsId, 'mail');
    });

    test('the library round-trips without a password (PWD-005)', () {
      final encoded = _library().encode();
      expect(encoded, isNot(contains('secret')));
      final back = ProxyLibraryData.decode(encoded);
      expect(back.gateways.map((g) => g.id), ['us', 'de']);
      expect(back.credentials.first.gatewayIds, {'us', 'de'});
      expect(back.proxies.first.settings.credentialsId, 'alice');
    });

    test('a password written into a backup is not read (BACKUP-011)', () {
      final raw = jsonEncode({
        'credentials': [
          {'id': 'c', 'username': 'u', 'password': 'p', 'gatewayIds': ['g']},
        ],
        'proxies': [
          {
            'id': 'x',
            'proxy': {'type': ProxyType.HTTP.index, 'address': 'a:1', 'password': 'p'},
          },
        ],
      });
      final lib = ProxyLibraryData.decode(raw);
      expect(lib.credentials.single.password, isNull);
      expect(lib.proxies.single.settings.password, isNull);
    });

    test('unusable entries are dropped', () {
      final raw = jsonEncode({
        'gateways': [
          {'id': 'tor', 'type': ProxyType.TOR.index},
          {'id': 'ok', 'type': ProxyType.HTTP.index, 'address': 'h:1'},
          {'id': 'ok', 'type': ProxyType.HTTP.index, 'address': 'dup:1'},
          {'type': ProxyType.HTTP.index},
        ],
        'proxies': [
          {'id': 'loop', 'proxy': {'type': ProxyType.SAVED.index}},
          {'id': 'tor', 'proxy': {'type': ProxyType.TOR.index}},
          {'id': 'gw', 'proxy': {'type': ProxyType.GATEWAY.index, 'gatewayId': 'ok'}},
        ],
        'credentials': 'not a list',
      });
      final lib = ProxyLibraryData.decode(raw);
      expect(lib.gateways.map((g) => g.address), ['h:1']);
      expect(lib.proxies.map((p) => p.id), ['gw']);
      expect(lib.credentials, isEmpty);
    });

    test('a malformed value reads as an empty library', () {
      expect(ProxyLibraryData.decode('{not json').isEmpty, isTrue);
      expect(ProxyLibraryData.decode('[]').isEmpty, isTrue);
      expect(ProxyLibraryData.decode(null).isEmpty, isTrue);
      expect(ProxyLibraryData.decode(AppPref.proxyLibrary.fallback).isEmpty,
          isTrue);
    });
  });

  group('storage (PWD-007)', () {
    late ProxyPasswordSecureStorage passwords;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      passwords =
          ProxyPasswordSecureStorage(secureStorage: MockFlutterSecureStorage());
      ProxyLibrary.setPasswordStoreForTest(passwords);
    });

    Future<String?> stored(ProxyPasswordKey key) => passwords.loadPassword(key);

    test('passwords go to secure storage, the rest to prefs', () async {
      await ProxyLibrary.update(_library());
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AppPref.proxyLibrary.key), isNot(contains('secret')));
      expect(await stored(ProxyPasswordKey.credentials(CredentialsId('alice'))),
          'alice-secret');
      expect(await stored(ProxyPasswordKey.savedProxy(SavedProxyId('plain'))),
          'plain-secret');
    });

    test('initialize hydrates every password', () async {
      await ProxyLibrary.update(_library());
      ProxyLibrary.resetForTest();
      await ProxyLibrary.initialize();
      expect(ProxyLibrary.credentialsById(CredentialsId('mail'))!.password, 'mail-secret');
      expect(ProxyLibrary.proxy(SavedProxyId('plain'))!.settings.password, 'plain-secret');
    });

    test('deleting an entry deletes its password', () async {
      await ProxyLibrary.update(_library());
      final lib = ProxyLibrary.data..credentials.removeWhere((c) => c.id == 'mail');
      await ProxyLibrary.update(lib);
      expect(await stored(ProxyPasswordKey.credentials(CredentialsId('mail'))),
          isNull);
      expect(await stored(ProxyPasswordKey.credentials(CredentialsId('alice'))),
          'alice-secret');
    });

    test('an orphaned password is collected on startup', () async {
      await passwords.savePassword(
          ProxyPasswordKey.credentials(CredentialsId('stale')),
          password: 'x');
      await ProxyLibrary.initialize();
      expect(await stored(ProxyPasswordKey.credentials(CredentialsId('stale'))),
          isNull);
    });

    test('site orphan cleanup leaves library passwords alone', () async {
      await ProxyLibrary.update(_library());
      await passwords.removeOrphaned({SiteId('some-site')});
      expect(await stored(ProxyPasswordKey.credentials(CredentialsId('alice'))),
          'alice-secret');
      expect(await stored(ProxyPasswordKey.savedProxy(SavedProxyId('plain'))),
          'plain-secret');
    });

    test('an import drops every library password', () async {
      await ProxyLibrary.update(_library());
      await ProxyLibrary.reloadAfterImport();
      expect(ProxyLibrary.credentialsById(CredentialsId('alice'))!.password, isNull);
      expect(await stored(ProxyPasswordKey.credentials(CredentialsId('alice'))),
          isNull);
    });
  });

  group('the proxy form (PROXY-019)', () {
    final stored = UserProxySettings(
      type: ProxyType.SOCKS5,
      address: '127.0.0.1:1080',
      username: 'old-user',
      password: 'old-pass',
    );

    test('a saved gateway hides the address, typed credentials are shown', () {
      final out = applyProxyForm(
        stored: stored,
        fields: ProxyFormFields(
          type: ProxyType.GATEWAY,
          gatewayId: GatewayId('de'),
          address: 'hidden:1',
          username: 'new-user',
        ),
      );
      expect(out.gatewayId, 'de');
      expect(out.address, '127.0.0.1:1080');
      expect(out.username, 'new-user');
      expect(out.password, isNull);
    });

    test('saved credentials hide the typed ones', () {
      final out = applyProxyForm(
        stored: stored,
        fields: ProxyFormFields(
          type: ProxyType.GATEWAY,
          gatewayId: GatewayId('de'),
          credentialsId: CredentialsId('mail'),
          username: 'hidden',
        ),
      );
      expect(out.credentialsId, 'mail');
      expect(out.username, 'old-user');
      expect(out.password, 'old-pass');
    });

    test('a typed gateway drops saved credentials', () {
      final out = applyProxyForm(
        stored: _gateway(GatewayId('de'), credentialsId: CredentialsId('mail')),
        fields: const ProxyFormFields(type: ProxyType.SOCKS5, address: 'a:1'),
      );
      expect(out.credentialsId, isNull);
      expect(out.gatewayId, 'de');
    });

    test('a saved proxy keeps everything else for the way back', () {
      final out = applyProxyForm(
        stored: _gateway(GatewayId('de'), credentialsId: CredentialsId('mail')),
        fields: ProxyFormFields(type: ProxyType.SAVED, savedProxyId: SavedProxyId('work')),
      );
      expect(out.savedProxyId, 'work');
      expect(out.gatewayId, 'de');
      expect(out.credentialsId, 'mail');
    });
  });

  group('sharing a site by QR', () {
    Map<String, dynamic> shared(UserProxySettings proxy) =>
        SiteSettingsQrCodec.shareableSubset(
            WebViewModel(initUrl: 'https://example.com/', proxySettings: proxy)
                .toJson());

    test('a library route travels resolved, without ids or passwords', () {
      final out = shared(_gateway(GatewayId('de'), credentialsId: CredentialsId('mail')));
      final proxy = out['proxySettings'] as Map<String, dynamic>;
      expect(proxy['type'], ProxyType.SOCKS5.index);
      expect(proxy['address'], 'de.gw:1080');
      expect(proxy['username'], 'alice-session-mail');
      expect(proxy.containsKey('gatewayId'), isFalse);
      expect(proxy.containsKey('credentialsId'), isFalse);
      expect(jsonEncode(out), isNot(contains('secret')));
    });

    test('an unresolved route shares no proxy', () {
      expect(shared(_proxy(SavedProxyId('gone'))).containsKey('proxySettings'), isFalse);
    });

    test('a received payload naming the library is refused', () {
      for (final type in [ProxyType.SAVED, ProxyType.GATEWAY]) {
        final uri = SiteSettingsQrCodec.encode({
          'initUrl': 'https://example.com/',
          'proxySettings': {'type': type.index, 'gatewayId': 'de'},
        });
        expect(SiteSettingsQrCodec.decode(uri), isNull, reason: '$type');
      }
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

    test('an app-wide proxy from the library shows its address', () {
      final b = backup({
        AppPref.globalOutboundProxy.key: jsonEncode(_proxy(SavedProxyId('work')).toJson()),
        AppPref.proxyLibrary.key: _library().encode(),
      });
      expect(backupGlobalProxyAddress(b), 'us.gw:1080');
    });
  });

  group('what uses an entry', () {
    test('counts use through a saved proxy', () {
      final lib = _library();
      expect(
          usesLibraryEntry(_proxy(SavedProxyId('work')),
              entry: GatewayEntry(GatewayId('us')), lib: lib),
          isTrue);
      expect(
          usesLibraryEntry(_proxy(SavedProxyId('work')),
              entry: CredentialsEntry(CredentialsId('alice')), lib: lib),
          isTrue);
      expect(
          usesLibraryEntry(_proxy(SavedProxyId('work')),
              entry: GatewayEntry(GatewayId('de')), lib: lib),
          isFalse);
      expect(
          usesLibraryEntry(_gateway(GatewayId('de'), credentialsId: CredentialsId('mail')),
              entry: CredentialsEntry(CredentialsId('mail')), lib: lib),
          isTrue);
    });
  });
}
