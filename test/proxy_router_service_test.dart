import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/proxy_relay.dart';
import 'package:webspace/services/proxy_router_engine.dart';
import 'package:webspace/services/proxy_router_service.dart';
import 'package:webspace/settings/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';

/// Lifecycle contract of the per-site proxy router (PROXY-013): what gets
/// installed in the relay, what happens when the relay refuses, and which
/// challenges the service will answer.
///
/// Drives the real service through a fake relay that models the wire
/// contract rather than stubbing it away — an unknown credential is a
/// route the relay does not have, which is what makes the revocation and
/// fail-closed assertions mean anything.
class FakeRelay implements ProxyRelayApi {
  Map<String, Map<String, Object?>> installed = {};
  String? startedRealm;
  int startCalls = 0;
  int stopCalls = 0;

  /// When false, `startRouter` reports a bind failure.
  bool canBind = true;

  /// When false, `setRoutes` rejects the table.
  bool acceptsRoutes = true;

  @override
  Future<int?> startRouter(String realm) async {
    startCalls++;
    if (!canBind) return null;
    startedRealm = realm;
    return 43210;
  }

  @override
  Future<bool> setRoutes(Map<String, Map<String, Object?>> routes) async {
    if (!acceptsRoutes) return false;
    installed = routes;
    return true;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    installed = {};
    startedRealm = null;
  }

  /// The upstream the relay would pick for [credential], or null when the
  /// connection would be answered 502.
  Map<String, Object?>? resolve(String credential) => installed[credential];
}

void main() {
  // ProxyRelay's singleton installs a method-call handler at
  // construction, so the service's default field needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeRelay relay;
  late ProxyRouterService service;

  UserProxySettings proxy(ProxyType type, String? address) =>
      UserProxySettings(type: type, address: address);

  setUp(() {
    GlobalOutboundProxy.setForTest(UserProxySettings(type: ProxyType.DEFAULT));
    relay = FakeRelay();
    service = ProxyRouterService.instance;
    service.resetForTest();
    service.setRelayForTest(relay);
  });

  tearDown(() => service.resetForTest());

  group('activation', () {
    test('installs one route per site and reports the relay port', () async {
      final port = await service.activate(perSiteProxies: {
        'a': proxy(ProxyType.SOCKS5, '127.0.0.1:9050'),
        'b': proxy(ProxyType.HTTP, '10.0.0.1:8080'),
      });

      expect(port, 43210);
      expect(service.isActive, isTrue);
      expect(relay.installed, hasLength(2));
      expect(
        relay.resolve(service.credentialFor('a')!)!['type'],
        'socks5',
      );
      expect(relay.resolve(service.credentialFor('b')!)!['host'], '10.0.0.1');
    });

    test('a bind failure leaves the service inactive', () async {
      relay.canBind = false;
      final port = await service.activate(
        perSiteProxies: {'a': proxy(ProxyType.HTTP, '10.0.0.1:8080')},
      );

      // Null means "fall back to the PROXY-008 unload", never "clear the
      // override" — an inactive router must not look active.
      expect(port, isNull);
      expect(service.isActive, isFalse);
      expect(service.credentialFor('a'), isNull);
    });

    test('a rejected route table leaves the service inactive', () async {
      relay.acceptsRoutes = false;
      final port = await service.activate(
        perSiteProxies: {'a': proxy(ProxyType.HTTP, '10.0.0.1:8080')},
      );

      expect(port, isNull);
      expect(service.isActive, isFalse);
    });

    test('the realm handed to the relay is the one the service answers on',
        () async {
      await service.activate(perSiteProxies: const {});
      expect(relay.startedRealm, isNotNull);
      expect(relay.startedRealm, service.realm);
      expect(
        service.ownsChallenge(host: '127.0.0.1', realm: relay.startedRealm),
        isTrue,
      );
    });
  });

  group('challenge ownership', () {
    test('refuses every challenge before activation', () {
      expect(service.ownsChallenge(host: '127.0.0.1', realm: 'anything'),
          isFalse);
    });

    test("refuses a site's own 401 once active", () async {
      await service.activate(
        perSiteProxies: {'a': proxy(ProxyType.HTTP, '10.0.0.1:8080')},
      );
      expect(
        service.ownsChallenge(host: 'bank.example.com', realm: service.realm),
        isFalse,
      );
    });

    test('refuses every challenge again after deactivation', () async {
      await service.activate(perSiteProxies: const {});
      final realm = service.realm;
      await service.deactivate();

      expect(service.isActive, isFalse);
      expect(service.ownsChallenge(host: '127.0.0.1', realm: realm), isFalse);
      expect(relay.stopCalls, 1);
    });
  });

  group('route refresh', () {
    test('a deleted site loses its route', () async {
      await service.activate(perSiteProxies: {
        'a': proxy(ProxyType.HTTP, '10.0.0.1:8080'),
        'b': proxy(ProxyType.HTTP, '10.0.0.2:8080'),
      });
      final credentialB = service.credentialFor('b')!;

      await service.refreshRoutes(
        perSiteProxies: {'a': proxy(ProxyType.HTTP, '10.0.0.1:8080')},
      );

      expect(relay.installed, hasLength(1));
      expect(
        relay.resolve(credentialB),
        isNull,
        reason: "a deleted site's credential must stop routing",
      );
    });

    test('a changed proxy repoints the same credential', () async {
      await service.activate(
        perSiteProxies: {'a': proxy(ProxyType.HTTP, '10.0.0.1:8080')},
      );
      final credential = service.credentialFor('a')!;

      await service.refreshRoutes(
        perSiteProxies: {'a': proxy(ProxyType.SOCKS5, '127.0.0.1:9050')},
      );

      expect(service.credentialFor('a'), credential);
      expect(relay.resolve(credential)!['type'], 'socks5');
      expect(relay.resolve(credential)!['port'], 9050);
    });

    test('a site with a malformed proxy is dropped, never sent direct',
        () async {
      await service.activate(perSiteProxies: {
        'good': proxy(ProxyType.HTTP, '10.0.0.1:8080'),
        'broken': proxy(ProxyType.HTTP, 'no-port-here'),
      });

      expect(relay.resolve(service.credentialFor('good')!), isNotNull);
      expect(
        relay.resolve(service.credentialFor('broken')!),
        isNull,
        reason: 'a site whose proxy will not parse must fail closed',
      );
      expect(
        relay.installed.values.any((r) => r['siteId'] == 'broken'),
        isFalse,
      );
    });

    test('refreshing before activation is a no-op', () async {
      expect(
        await service.refreshRoutes(
          perSiteProxies: {'a': proxy(ProxyType.HTTP, '10.0.0.1:8080')},
        ),
        isFalse,
      );
      expect(relay.installed, isEmpty);
    });
  });

  group('credential secrecy', () {
    test('a credential is never reused across sites', () async {
      await service.activate(perSiteProxies: {
        for (var i = 0; i < 25; i++) 'site-$i': proxy(ProxyType.DEFAULT, null),
      });
      expect(relay.installed.keys.toSet(), hasLength(25));
    });

    test('the wire table carries no token beyond the map key', () async {
      await service.activate(
        perSiteProxies: {'a': proxy(ProxyType.HTTP, '10.0.0.1:8080')},
      );
      final credential = service.credentialFor('a')!;
      final entry = relay.resolve(credential)!;
      // The upstream half of the entry is the user's own proxy config.
      // The site's token must not be duplicated into it, or an upstream
      // that echoes its config would disclose it.
      expect(entry.values.whereType<String>(), isNot(contains(credential)));
    });

    test('a fresh service run mints a different realm', () async {
      await service.activate(perSiteProxies: const {});
      final first = service.realm;
      service.resetForTest();
      await service.activate(perSiteProxies: const {});
      expect(service.realm, isNot(first));
    });

    test('router mode is gated on Android AND container support', () {
      // Two independent gates, and this is where the negative contract
      // lives now that the integration tier runs Android-only. Off
      // Android the engine cannot deliver a per-WebView proxy challenge
      // at all; on Android without MULTI_PROFILE every site shares one
      // auth cache. Either way the app must stay on PROXY-008.
      expect(ProxyRouterService.isSupported(useContainers: false), isFalse);
      if (!hostIsAndroid) {
        expect(
          ProxyRouterService.isSupported(useContainers: true),
          isFalse,
          reason: 'router mode must not engage off Android',
        );
      }
    });
  });

  test('the credential the service issues is the relay map key', () async {
    await service.activate(
      perSiteProxies: {'acme': proxy(ProxyType.DEFAULT, null)},
    );
    final credential = service.credentialFor('acme')!;
    expect(relay.installed.containsKey(credential), isTrue);

    final decoded = utf8.decode(base64.decode(credential));
    expect(decoded, startsWith('ws-acme:'));
    final token = decoded.substring('ws-acme:'.length);
    expect(token, hasLength(32));
    expect(
      ProxyRouterEngine.credentialFor(siteId: 'acme', token: token),
      credential,
    );
  });
}
