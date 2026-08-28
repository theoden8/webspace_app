// Per-site proxy router end-to-end through the running app (PROXY-013).
//
// Seeds two sites whose proxies differ, launches the real app, and
// watches the two platform channels the router drives:
//
//   org.codeberg.theoden8.webspace/proxy_relay   -> startRouter/setRoutes
//   com.pichillilorenzo/.../proxycontroller      -> setProxyOverride
//
// What runs where:
//
//   * On Android the positive contract is asserted: the router comes up,
//     the process-wide rule points at the loopback relay rather than at
//     any site's proxy, and each site gets its own credential.
//   * Everywhere else the negative contract is asserted, which is not a
//     formality: router mode must not engage on a platform whose engine
//     cannot deliver a per-WebView proxy challenge, because there every
//     site would share one cached credential and route through one
//     another's proxies. Linux CI runs this half.
//
// The concurrency claim itself (two mismatched sites genuinely holding
// tunnels to two upstreams) is proved against real sockets in
// `ProxyRelayRouterTest.kt`; the unload decision that lets them stay
// loaded is proved in `test/site_unload_engine_test.dart`.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/demo_data.dart';
import 'package:webspace/main.dart' as app;
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/proxy_router_service.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/web_view_model.dart';

import 'secure_storage_fake.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const relayChannel =
      MethodChannel('org.codeberg.theoden8.webspace/proxy_relay');
  const proxyChannel = MethodChannel(
    'com.pichillilorenzo/flutter_inappwebview_proxycontroller',
  );

  final relayCalls = <MethodCall>[];
  final proxyCalls = <MethodCall>[];
  const fakeRelayPort = 45671;

  setUpAll(() async {
    isDemoMode = true;
    await installInMemoryKeychainIfUnavailable();

    // Two accounts on one service, each meant to be seen from its own
    // exit IP. This is the pair PROXY-008 could not keep loaded together.
    final siteA = WebViewModel(
      siteId: 'router-a',
      initUrl: 'http://192.0.2.1/',
      name: 'Router A',
      proxySettings: UserProxySettings(
        type: ProxyType.SOCKS5,
        address: '127.0.0.1:9050',
      ),
    );
    final siteB = WebViewModel(
      siteId: 'router-b',
      initUrl: 'http://192.0.2.2/',
      name: 'Router B',
      proxySettings: UserProxySettings(
        type: ProxyType.HTTP,
        address: '198.51.100.7:8080',
      ),
    );
    SharedPreferences.setMockInitialValues({
      'webViewModels': [
        jsonEncode(siteA.toJson()),
        jsonEncode(siteB.toJson()),
      ],
    });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(relayChannel, (call) async {
      relayCalls.add(call);
      return switch (call.method) {
        'startRouter' => fakeRelayPort,
        'setRoutes' => true,
        'isRunning' => true,
        _ => null,
      };
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(proxyChannel, (call) async {
      proxyCalls.add(call);
      return null;
    });
  });

  tearDownAll(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(relayChannel, null);
    messenger.setMockMethodCallHandler(proxyChannel, null);
  });

  testWidgets('the proxy router comes up only where it can be honoured',
      (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 30));

    // Drive the engine so startup work (container probe, model load,
    // router activation) settles. pumpAndSettle deadlocks on a live
    // WebView, so pump in fixed slices.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }

    final started =
        relayCalls.where((c) => c.method == 'startRouter').toList();
    final routeCalls = relayCalls.where((c) => c.method == 'setRoutes').toList();

    if (!hostIsAndroid) {
      expect(
        started,
        isEmpty,
        reason: 'router mode must not engage where the engine cannot '
            'deliver a per-WebView proxy challenge',
      );
      expect(ProxyRouterService.instance.isActive, isFalse);
      return;
    }

    // Android without MULTI_PROFILE keeps the PROXY-008 serialisation:
    // one shared auth cache would route sites through each other.
    if (started.isEmpty) {
      expect(ProxyRouterService.instance.isActive, isFalse,
          reason: 'no container support means no router mode');
      return;
    }

    final realm = (started.last.arguments as Map)['realm'] as String?;
    expect(realm, isNotNull);
    expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(realm!), isTrue,
        reason: 'the realm must be an unguessable hex nonce');

    expect(routeCalls, isNotEmpty, reason: 'routes should be installed');
    final routes =
        (routeCalls.last.arguments as Map)['routes'] as Map;
    expect(routes.length, 2, reason: 'one route per seeded site');
    expect(routes.keys.toSet(), hasLength(2),
        reason: 'two sites must never share a credential');

    final bySite = {
      for (final entry in routes.values.cast<Map>())
        entry['siteId'] as String: entry,
    };
    expect(bySite['router-a']!['type'], 'socks5');
    expect(bySite['router-a']!['port'], 9050);
    expect(bySite['router-b']!['type'], 'http');
    expect(bySite['router-b']!['host'], '198.51.100.7');

    // The process-wide rule points at the relay, NOT at either site's
    // proxy. That is the whole point: it never has to flip again, so
    // mismatched sites stop evicting each other.
    final overrides =
        proxyCalls.where((c) => c.method == 'setProxyOverride').toList();
    expect(overrides, isNotEmpty);
    final settings = ((overrides.last.arguments as Map)['settings'] as Map)
        .cast<String, dynamic>();
    final url = ((settings['proxyRules'] as List).first as Map)['url'] as String;
    expect(url, 'http://127.0.0.1:$fakeRelayPort');
    expect(url, isNot(contains('9050')));
    expect(url, isNot(contains('198.51.100.7')));

    // The credential the WebView will present is not written anywhere the
    // route table can be read back from disk; it exists for this run only.
    expect(ProxyRouterService.instance.credentialFor('router-a'), isNotNull);
    expect(
      ProxyRouterService.instance.credentialFor('router-a'),
      isNot(ProxyRouterService.instance.credentialFor('router-b')),
    );
  });
}
