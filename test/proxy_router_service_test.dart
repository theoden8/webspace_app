import 'dart:async';
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/proxy_relay.dart';
import 'package:webspace/services/proxy_router_engine.dart';
import 'package:webspace/services/proxy_router_service.dart';
import 'package:webspace/services/router_attribution.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/services/http_auth_challenge.dart';
import 'package:webspace/services/http_auth_engine.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/proxy.dart';

import 'helpers/fake_auth_caches.dart';
import 'helpers/memory_http_auth_store.dart';

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

  @override
  String? get lastError => canBind ? null : 'FAKE_BIND_FAILED: no';

  /// When false, `setRoutes` rejects the table.
  bool acceptsRoutes = true;

  /// The address the fake reports binding. A random 127/8 one, as the
  /// real relay picks, so nothing can quietly assume 127.0.0.1.
  static const String boundHost = '127.63.9.212';

  @override
  Future<({String host, int port})?> startRouter(String realm) async {
    startCalls++;
    if (!canBind) return null;
    startedRealm = realm;
    return (host: boundHost, port: 43210);
  }

  @override
  Future<bool> setRoutes(Map<String, Map<String, Object?>> routes) async {
    if (!acceptsRoutes) return false;
    installed = routes;
    return true;
  }

  /// nonce -> siteId, as the relay would have observed it.
  Map<String, String> probes = {};
  int clearProbeCalls = 0;

  @override
  Future<Map<String, String>> probeResults() async => probes;

  @override
  Future<void> clearProbeResults() async {
    clearProbeCalls++;
    probes = {};
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    installed = {};
    startedRealm = null;
    probes = {};
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

  UserProxySettings proxy(ProxyType type, {required String? address}) =>
      UserProxySettings(type: type, address: address);

  setUp(() {
    GlobalOutboundProxy.setInMemory(UserProxySettings(type: ProxyType.DEFAULT));
    relay = FakeRelay();
    service = ProxyRouterService.instance;
    service.resetForTest();
    service.setRelayForTest(relay);
  });

  tearDown(() {
    service.resetForTest();
    DeveloperModeService.instance.debugSet(on: false);
    AppPref.proxyRouter.debugValue = AppPref.proxyRouter.fallback;
  });

  group('activation', () {
    test('installs one route per site and reports the relay port', () async {
      final port = await service.activate(perSiteProxies: {
        RouterIdentity.ofSite(SiteId('a')): proxy(ProxyType.SOCKS5, address: '127.0.0.1:9050'),
        RouterIdentity.ofSite(SiteId('b')): proxy(ProxyType.HTTP, address: '10.0.0.1:8080'),
      });

      expect(port, 43210);
      expect(service.isActive, isTrue);
      expect(relay.installed, hasLength(2));
      expect(
        relay.resolve(service.credentialFor(RouterIdentity.ofSite(SiteId('a')))!)!['type'],
        'socks5',
      );
      expect(relay.resolve(service.credentialFor(RouterIdentity.ofSite(SiteId('b')))!)!['host'], '10.0.0.1');
    });

    test('the override is bound before the probe runs (PROXY-015)', () async {
      // The probe's own traffic travels the process-wide proxy. Bound
      // after the probe, it resolves its own hostname directly, never
      // reaches the relay, and attribution fails on every device --
      // router mode then can never activate anywhere.
      final order = <String>[];
      final port = await service.activate(
        perSiteProxies: {RouterIdentity.ofSite(SiteId('a')): proxy(ProxyType.HTTP, address: '10.0.0.1:8080')},
        bindOverride: (h, {required port}) async {
          order.add('bind');
          return true;
        },
        probe: (identity, {required url}) async {
          order.add('probe');
          relay.probes[FakeAuthCaches.nonceOf(url)] = identity;
        },
      );

      expect(order, ['bind', 'probe']);
      expect(port, isNotNull);
      expect(service.isActive, isTrue);
    });

    test('a failed override bind leaves the service inactive', () async {
      final port = await service.activate(
        perSiteProxies: {RouterIdentity.ofSite(SiteId('a')): proxy(ProxyType.HTTP, address: '10.0.0.1:8080')},
        bindOverride: (h, {required port}) async => false,
      );

      expect(port, isNull);
      expect(service.isActive, isFalse);
    });

    test('a bind failure leaves the service inactive', () async {
      relay.canBind = false;
      final port = await service.activate(
        perSiteProxies: {RouterIdentity.ofSite(SiteId('a')): proxy(ProxyType.HTTP, address: '10.0.0.1:8080')},
      );

      // Null means "fall back to the PROXY-008 unload", never "clear the
      // override" — an inactive router must not look active.
      expect(port, isNull);
      expect(service.isActive, isFalse);
      expect(service.credentialFor(RouterIdentity.ofSite(SiteId('a'))), isNull);
    });

    test('a rejected route table leaves the service inactive', () async {
      relay.acceptsRoutes = false;
      final port = await service.activate(
        perSiteProxies: {RouterIdentity.ofSite(SiteId('a')): proxy(ProxyType.HTTP, address: '10.0.0.1:8080')},
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
        service.ownsChallenge(
            host: FakeRelay.boundHost, realm: relay.startedRealm),
        isTrue,
      );
      // Being on loopback is not enough. The relay binds a random address
      // in 127/8 precisely so that naming it costs more than knowing the
      // feature exists, and the answer is pinned to the one it bound.
      expect(
        service.ownsChallenge(host: '127.0.0.1', realm: relay.startedRealm),
        isFalse,
      );
    });
  });

  group('challenge ownership', () {
    test('refuses every challenge before activation', () {
      expect(
          service.ownsChallenge(host: FakeRelay.boundHost, realm: 'anything'),
          isFalse);
    });

    test("refuses a site's own 401 once active", () async {
      await service.activate(
        perSiteProxies: {RouterIdentity.ofSite(SiteId('a')): proxy(ProxyType.HTTP, address: '10.0.0.1:8080')},
      );
      expect(
        service.ownsChallenge(host: 'bank.example.com', realm: service.realm),
        isFalse,
      );
    });

    test('refuses every challenge again after a stand-down', () async {
      await service.activate(
        perSiteProxies: const {},
        bindOverride: (h, {required port}) async => false,
      );

      expect(service.isActive, isFalse);
      expect(
        service.ownsChallenge(
            host: FakeRelay.boundHost, realm: relay.startedRealm),
        isFalse,
      );
      expect(relay.stopCalls, 1);
    });
  });

  // Android's callback carries only host and realm, so the relay's 407 and a
  // site's 401 meet in one funnel; the router answers first and alone.
  group('the challenge funnel (HTTPAUTH-001)', () {
    final site = RouterIdentity.ofSite(SiteId('a'));
    late MemoryHttpAuthStore store;
    late List<HttpAuthPromptRequest> prompts;

    setUp(() async {
      await service.activate(perSiteProxies: {
        site: proxy(ProxyType.HTTP, address: '10.0.0.1:8080'),
      });
      store = MemoryHttpAuthStore();
      prompts = [];
    });

    Future<inapp.HttpAuthResponse?> challenge({required String host,
            required String? realm}) =>
        answerHttpAuthChallenge(
          routerIdentity: site,
          session: HttpAuthSession(
            siteId: SiteId('a'),
            siteUrl: 'https://nas.example.com/',
            memory: HttpAuthMemory.readWrite,
            store: store,
            prompt: (request) async {
              prompts.add(request);
              return const HttpAuthPromptResult(
                  username: 'user', password: 'typed');
            },
          ),
          challenge: inapp.HttpAuthenticationChallenge(
            previousFailureCount: 0,
            protectionSpace: inapp.URLProtectionSpace(host: host, realm: realm),
          ),
        );

    test("the relay's challenge never reaches the user", () async {
      final answer =
          await challenge(host: FakeRelay.boundHost, realm: service.realm);
      expect(answer?.username, service.usernameFor(site));
      expect(answer?.password, service.tokenFor(site));
      expect(answer?.permanentPersistence, isFalse);
      expect(prompts, isEmpty, reason: 'no sign-in dialog opens');
      expect(store.lookups, 0, reason: 'no saved sign-in is read');
    });

    test("a site's challenge is not answered with the router token",
        () async {
      final answer =
          await challenge(host: 'nas.example.com', realm: 'Basic realm');
      expect(prompts, hasLength(1), reason: "the site's session decides it");
      expect(answer?.password, 'typed');
      expect(answer?.password, isNot(service.tokenFor(site)));
    });
  });

  group('route refresh', () {
    test('a deleted site loses its route', () async {
      await service.activate(perSiteProxies: {
        RouterIdentity.ofSite(SiteId('a')): proxy(ProxyType.HTTP, address: '10.0.0.1:8080'),
        RouterIdentity.ofSite(SiteId('b')): proxy(ProxyType.HTTP, address: '10.0.0.2:8080'),
      });
      final credentialB = service.credentialFor(RouterIdentity.ofSite(SiteId('b')))!;

      await service.refreshRoutes(
        perSiteProxies: {RouterIdentity.ofSite(SiteId('a')): proxy(ProxyType.HTTP, address: '10.0.0.1:8080')},
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
        perSiteProxies: {RouterIdentity.ofSite(SiteId('a')): proxy(ProxyType.HTTP, address: '10.0.0.1:8080')},
      );
      final credential = service.credentialFor(RouterIdentity.ofSite(SiteId('a')))!;

      await service.refreshRoutes(
        perSiteProxies: {
          RouterIdentity.ofSite(SiteId('a')): proxy(ProxyType.SOCKS5, address: '127.0.0.1:9050')
        },
      );

      expect(service.credentialFor(RouterIdentity.ofSite(SiteId('a'))), credential);
      expect(relay.resolve(credential)!['type'], 'socks5');
      expect(relay.resolve(credential)!['port'], 9050);
    });

    test('a site with a malformed proxy is dropped, never sent direct',
        () async {
      await service.activate(perSiteProxies: {
        RouterIdentity.ofSite(SiteId('good')): proxy(ProxyType.HTTP, address: '10.0.0.1:8080'),
        RouterIdentity.ofSite(SiteId('broken')): proxy(ProxyType.HTTP, address: 'no-port-here'),
      });

      expect(relay.resolve(service.credentialFor(RouterIdentity.ofSite(SiteId('good')))!), isNotNull);
      expect(
        relay.resolve(service.credentialFor(RouterIdentity.ofSite(SiteId('broken')))!),
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
          perSiteProxies: {
            RouterIdentity.ofSite(SiteId('a')): proxy(ProxyType.HTTP, address: '10.0.0.1:8080')
          },
        ),
        isFalse,
      );
      expect(relay.installed, isEmpty);
    });
  });

  group('credential secrecy', () {
    test('a credential is never reused across sites', () async {
      await service.activate(perSiteProxies: {
        for (var i = 0; i < 25; i++)
          RouterIdentity.ofSite(SiteId('site-$i')):
              proxy(ProxyType.DEFAULT, address: null),
      });
      expect(relay.installed.keys.toSet(), hasLength(25));
    });

    test('the wire table carries no token beyond the map key', () async {
      await service.activate(
        perSiteProxies: {RouterIdentity.ofSite(SiteId('a')): proxy(ProxyType.HTTP, address: '10.0.0.1:8080')},
      );
      final credential = service.credentialFor(RouterIdentity.ofSite(SiteId('a')))!;
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

    test('router mode is gated on Android AND containers AND its switch '
        '(PROXY-013)', () {
      // Three independent gates, and this is where the negative contract
      // lives now that the integration tier runs Android-only. Off Android
      // the engine cannot deliver a per-WebView proxy challenge at all; on
      // Android without MULTI_PROFILE every site shares one auth cache; and
      // the Proxy router switch in App settings > Network is the user's way
      // back. Any one of them failing must leave the app on PROXY-008.
      // Developer mode is none of them.
      //
      // Asserted on the decision rather than on `isSupported`, because
      // this suite runs off Android: there `hostIsAndroid` answers false
      // first and every further assertion passes without meaning it. That
      // `isSupported` reads the switch is test/js/proxy_router_gate.test.js.
      for (final useContainers in [true, false]) {
        for (final switchOn in [true, false]) {
          final why = 'containers=$useContainers switch=$switchOn';
          expect(
            ProxyRouterService.isSupportedWhen(
              isAndroid: true,
              useContainers: useContainers,
              switchOn: switchOn,
            ),
            useContainers && switchOn,
            reason: why,
          );
          // Apple does not run the relay. Each container store binds its
          // real upstream directly, which BUG-014 measured delivering
          // distinct upstreams and distinct credentials per store, so the
          // relay would be a hop that buys nothing. The implementation stays
          // reachable for parity testing and nothing else, so the Apple
          // branch is off unless a test opts in.
          expect(
            ProxyRouterService.isSupportedWhen(
              isAndroid: false,
              isApple: true,
              useContainers: useContainers,
              switchOn: switchOn,
            ),
            isFalse,
            reason: 'apple must not run the relay by default: $why',
          );
          // Opted in, it is the Android decision again, so the parity path
          // is still exercisable and the other two conditions still gate it.
          expect(
            ProxyRouterService.isSupportedWhen(
              isAndroid: false,
              isApple: true,
              appleRelayEnabled: true,
              useContainers: useContainers,
              switchOn: switchOn,
            ),
            useContainers && switchOn,
            reason: 'apple parity path: $why',
          );
          expect(
            ProxyRouterService.isSupportedWhen(
              isAndroid: false,
              useContainers: useContainers,
              switchOn: switchOn,
            ),
            isFalse,
            reason: 'router mode must not engage on a platform that is '
                'neither Android nor Apple, and omitting isApple must not '
                'widen the gate',
          );
        }
      }

      // And the wiring: the composed calls must agree with the decision on
      // whatever host this runs on. Written against the decision rather
      // than against a platform, because the earlier form asserted "off
      // Android, unsupported" and that was only ever true while the gate
      // was Android-only -- it passed on Linux and failed on the macOS
      // runner the moment Apple joined (PROXY-026).
      expect(AppPref.proxyRouter.value, isTrue,
          reason: 'the router runs by default where the WebView can');
      expect(ProxyRouterService.isSupported(useContainers: false), isFalse,
          reason: 'containers are ANDed in, so no containers is no router '
              'on every platform');
      final onThisHost = ProxyRouterService.isSupportedWhen(
        isAndroid: hostIsAndroid,
        isApple: hostIsIOS || hostIsMacOS,
        appleRelayEnabled: ProxyRouterService.appleRelayEnabled,
        useContainers: true,
        switchOn: true,
      );
      for (final developerMode in [true, false]) {
        DeveloperModeService.instance.debugSet(on: developerMode);
        expect(ProxyRouterService.isSupported(useContainers: true), onThisHost,
            reason: 'developer mode is not a gate (on=$developerMode)');
      }
      expect(ProxyRouterService.canRunHere(useContainers: true), onThisHost,
          reason: 'the switch is listed exactly where the router could run '
              'with it on');

      AppPref.proxyRouter.debugValue = false;
      expect(ProxyRouterService.isSupported(useContainers: true), isFalse,
          reason: 'the switch off keeps PROXY-008');
      expect(ProxyRouterService.canRunHere(useContainers: true), onThisHost,
          reason: 'the row stays listed with its switch off, or it could '
              'never be turned back on');
      expect(ProxyRouterService.appleRelayEnabled, isFalse,
          reason: 'the Apple relay ships off; a test that flips it must put '
              'it back, or every later assertion here is about a path the '
              'app does not take');
    });
  });

  test('the credential the service issues is the relay map key', () async {
    await service.activate(
      perSiteProxies: {RouterIdentity.ofSite(SiteId('acme')): proxy(ProxyType.DEFAULT, address: null)},
    );
    final credential = service.credentialFor(RouterIdentity.ofSite(SiteId('acme')))!;
    expect(relay.installed.containsKey(credential), isTrue);

    final decoded = utf8.decode(base64.decode(credential));
    expect(decoded, startsWith('ws-acme:'));
    final token = decoded.substring('ws-acme:'.length);
    expect(token, hasLength(32));
    expect(
      ProxyRouterEngine.credentialFor(
          identity: RouterIdentity.ofSite(SiteId('acme')), token: token),
      credential,
    );
  });

  group('attribution self-test (PROXY-015)', () {
    /// A device that behaves: each container presents its own credential,
    /// so every nonce comes back stamped with its own identity.
    FakeAuthCaches honestDevice() => FakeAuthCaches(
        record: ({required nonce, required identity}) => relay.probes[nonce] = identity);

    /// The device this whole check exists for: one shared proxy auth
    /// cache, so whichever site authenticated first has its credential
    /// replayed for every container probed after it, and nothing errors
    /// anywhere.
    FakeAuthCaches sharedAuthCacheDevice() => FakeAuthCaches.shared(
        record: ({required nonce, required identity}) => relay.probes[nonce] = identity);

    final a = RouterIdentity.ofSite(SiteId('a'));
    final b = RouterIdentity.ofSite(SiteId('b'));
    final c = RouterIdentity.ofSite(SiteId('c'));
    final d = RouterIdentity.ofSite(SiteId('d'));

    Future<inapp.HttpAuthResponse?> relayChallenge(RouterIdentity identity) =>
        answerHttpAuthChallenge(
          routerIdentity: identity,
          session: null,
          challenge: inapp.HttpAuthenticationChallenge(
            previousFailureCount: 0,
            protectionSpace: inapp.URLProtectionSpace(
                host: FakeRelay.boundHost, realm: service.realm),
          ),
        );

    test('activates when every container presents its own credential',
        () async {
      final port = await service.activate(
        perSiteProxies: {
          RouterIdentity.ofSite(SiteId('a')): proxy(ProxyType.SOCKS5, address: '127.0.0.1:9050'),
          RouterIdentity.ofSite(SiteId('b')): proxy(ProxyType.HTTP, address: '10.0.0.1:8080'),
        },
        probe: honestDevice().probe,
      );

      expect(port, 43210);
      expect(service.isActive, isTrue);
      expect(relay.clearProbeCalls, 1,
          reason: 'stale observations must not satisfy a fresh check');
    });

    test('REFUSES to activate when the device mixes credentials up',
        () async {
      // This is the silent-leak device. Without the check it would look
      // exactly like success: routes installed, relay bound, pages load.
      final port = await service.activate(
        perSiteProxies: {
          RouterIdentity.ofSite(SiteId('a')): proxy(ProxyType.SOCKS5, address: '127.0.0.1:9050'),
          RouterIdentity.ofSite(SiteId('b')): proxy(ProxyType.HTTP, address: '10.0.0.1:8080'),
        },
        probe: sharedAuthCacheDevice().probe,
      );

      expect(port, isNull);
      expect(service.isActive, isFalse,
          reason: 'a device that cannot attribute must fall back to PROXY-008');
      expect(service.credentialFor(RouterIdentity.ofSite(SiteId('a'))), isNull);
      expect(relay.stopCalls, greaterThan(0),
          reason: 'the relay must not be left listening after a failed check');
    });

    /// The grid takes taps while the launch's checks run, and the relay
    /// already owns the rule. Placed as routed then, two sites on different
    /// proxies stayed loaded, and a check that failed stood the relay down
    /// with both on one rule; the launch's own activation, which a tap
    /// skips, was the only cleanup. The residency plan reads
    /// [ProxyRouterService.routesPerSite], so a tap in that window unloads
    /// the other route as under PROXY-008.
    test('sites route apart only once the launch checks pass (BUG-037)',
        () async {
      final gate = Completer<void>();
      final device = honestDevice()..gates[a] = gate;
      final launch = service.activate(
        perSiteProxies: {
          for (final id in [a, b])
            id: proxy(ProxyType.HTTP, address: '10.0.0.1:8080'),
        },
        probe: device.probe,
      );
      await pumpEventQueue();
      expect(service.isActive, isTrue,
          reason: 'the relay owns the rule while it checks');
      expect(service.routesPerSite, isFalse,
          reason: 'a site opened now is placed as under PROXY-008');

      gate.complete();
      expect(await launch, 43210);
      expect(service.routesPerSite, isTrue);
    });

    test('a launch whose checks fail never routes sites apart (BUG-037)',
        () async {
      final gate = Completer<void>();
      final device = sharedAuthCacheDevice()..gates[a] = gate;
      final launch = service.activate(
        perSiteProxies: {
          for (final id in [a, b])
            id: proxy(ProxyType.HTTP, address: '10.0.0.1:8080'),
        },
        probe: device.probe,
      );
      await pumpEventQueue();
      expect(service.routesPerSite, isFalse);

      gate.complete();
      expect(await launch, isNull);
      expect(service.isActive, isFalse);
      expect(service.routesPerSite, isFalse);
    });

    test('refuses when any site fails to report at all', () async {
      final port = await service.activate(
        perSiteProxies: {
          RouterIdentity.ofSite(SiteId('a')): proxy(ProxyType.HTTP, address: '10.0.0.1:8080'),
          RouterIdentity.ofSite(SiteId('b')): proxy(ProxyType.HTTP, address: '10.0.0.2:8080'),
        },
        // b's probe never arrives, asked twice.
        probe: (honestDevice()..silent[b] = 2).probe,
      );

      expect(port, isNull,
          reason: 'an unproven site is treated exactly like a failed one');
      expect(service.isActive, isFalse);
    });

    test('refuses when the probe itself throws', () async {
      final port = await service.activate(
        perSiteProxies: {RouterIdentity.ofSite(SiteId('a')): proxy(ProxyType.HTTP, address: '10.0.0.1:8080')},
        probe: (_, {required url}) async =>
            throw PlatformException(code: 'no webview'),
      );
      expect(port, isNull);
      expect(service.isActive, isFalse);
    });

    test('probe URLs are unique per site and use the reserved suffix',
        () async {
      final urls = <String>[];
      await service.activate(
        perSiteProxies: {
          for (var i = 0; i < 5; i++)
            RouterIdentity.ofSite(SiteId('site-$i')):
              proxy(ProxyType.DEFAULT, address: null),
        },
        probe: (identity, {required url}) async {
          urls.add(url);
          relay.probes[FakeAuthCaches.nonceOf(url)] = identity;
        },
      );
      await pumpEventQueue();
      expect(urls.toSet(), hasLength(5));
      for (final u in urls) {
        expect(u, startsWith('http://'));
        expect(u, contains(ProxyRouterEngine.probeSuffix));
      }
    });

    test('the launch waits for two checks; a site waits for its own',
        () async {
      final device = honestDevice();
      final gate = Completer<void>();
      device.gates[d] = gate;
      final port = await service.activate(
        perSiteProxies: {
          for (final id in [a, b, c, d])
            id: proxy(ProxyType.HTTP, address: '10.0.0.1:8080'),
        },
        probe: device.probe,
      );
      expect(port, 43210, reason: "d's check does not hold the launch");
      expect(device.started.take(2), [a, b]);

      inapp.HttpAuthResponse? answer;
      var answered = false;
      unawaited(relayChallenge(d).then((r) {
        answer = r;
        answered = true;
      }));
      await pumpEventQueue();
      expect(answered, isFalse,
          reason: "d presents nothing before its check has run");
      gate.complete();
      await pumpEventQueue();
      expect(answered, isTrue);
      expect(answer?.password, service.tokenFor(d));
    });

    test(
        "the launch's site leads the proof; the rest wait for its page",
        () async {
      final device = honestDevice();
      final settled = Completer<void>();
      final port = await service.activate(
        perSiteProxies: {
          for (final id in [a, b, c, d])
            id: proxy(ProxyType.HTTP, address: '10.0.0.1:8080'),
        },
        probe: device.probe,
        launch: RouterLaunch(
          presents: Future.value(c),
          settled: settled.future,
        ),
      );
      expect(port, 43210);
      expect(device.started, [c, a],
          reason: 'the launched webview waits for no third check');
      expect(await relayChallenge(c).then((r) => r?.password),
          service.tokenFor(c));

      await pumpEventQueue();
      expect(device.started, [c, a],
          reason: 'no queued probe loads beside the launched page');
      settled.complete();
      await pumpEventQueue();
      expect(device.started.toSet(), {a, b, c, d});
    });

    test('a late failed check stops routing both identities it names',
        () async {
      // c caches with a: the proof of a and b cannot see it, c's own check
      // does, and neither a nor c can be told apart from then on.
      final device = FakeAuthCaches(
        record: ({required nonce, required identity}) => relay.probes[nonce] = identity,
        profileOf: (identity) => identity == c ? a : identity,
      );
      await service.activate(
        perSiteProxies: {
          for (final id in [a, b, c])
            id: proxy(ProxyType.HTTP, address: '10.0.0.1:8080'),
        },
        probe: device.probe,
      );
      final credentialA = service.credentialFor(a)!;
      await pumpEventQueue();

      expect(service.isActive, isTrue,
          reason: 'loaded sites keep the route they run on');
      expect(relay.resolve(credentialA), isNull,
          reason: "a's credential fails closed, wherever it is cached");
      expect(relay.installed.values.map((r) => r['siteId']), [b]);
      expect(await relayChallenge(a), isNull);
      expect(await relayChallenge(c), isNull);
      expect((await relayChallenge(b))?.password, service.tokenFor(b));
    });

    test('an identity new to the run is checked before it is presented',
        () async {
      final device = honestDevice();
      await service.activate(
        perSiteProxies: {
          a: proxy(ProxyType.HTTP, address: '10.0.0.1:8080'),
          b: proxy(ProxyType.HTTP, address: '10.0.0.2:8080'),
        },
        probe: device.probe,
      );
      expect(await relayChallenge(RouterIdentity.shared), isNull,
          reason: 'an identity the relay does not route is never answered');

      await service.refreshRoutes(perSiteProxies: {
        a: proxy(ProxyType.HTTP, address: '10.0.0.1:8080'),
        b: proxy(ProxyType.HTTP, address: '10.0.0.2:8080'),
        d: proxy(ProxyType.HTTP, address: '10.0.0.4:8080'),
        RouterIdentity.shared: proxy(ProxyType.DEFAULT, address: null),
      });
      await pumpEventQueue();
      expect(device.started, containsAll([d, RouterIdentity.shared]),
          reason: 'checked as it appears, before anything asks');
      final answer = await relayChallenge(RouterIdentity.shared);
      expect(answer?.password, service.tokenFor(RouterIdentity.shared));
    });

    test('no probe supplied means no check (the test-only path)', () async {
      final port = await service.activate(
        perSiteProxies: {RouterIdentity.ofSite(SiteId('a')): proxy(ProxyType.HTTP, address: '10.0.0.1:8080')},
      );
      expect(port, 43210);
      expect(relay.clearProbeCalls, 0);
    });
  });
}
