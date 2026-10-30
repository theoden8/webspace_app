import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/controllers/site_network_controller.dart';
import 'package:webspace/services/process_route.dart';
import 'package:webspace/services/proxy_binding_engine.dart';
import 'package:webspace/services/proxy_router_probe.dart';
import 'package:webspace/services/proxy_router_service.dart';
import 'package:webspace/services/webview_proxy.dart'
    show PlatformInfo, ProxyManager;
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/fake_auth_caches.dart';
import 'helpers/fake_proxy_relay.dart';
import 'helpers/real_app.dart';

/// Two sites on different proxies, opened one after the other in the real
/// app, under each binding Android can run.
///
/// With per-site profiles the relay carries both for the whole run: both
/// stay loaded, each routed to its own upstream, and no rule ever names a
/// site's proxy (PROXY-013). Without them one rule carries one site's own
/// proxy at a time, so opening the second unloads the first (PROXY-008).
/// CI runs Dart tests on Linux and macOS hosts, so each binding is pinned.
void main() {
  const proxyChannel = MethodChannel(
    'com.pichillilorenzo/flutter_inappwebview_proxycontroller',
  );
  /// The proxy URLs each `setProxyOverride` named, in order.
  final rulesWritten = <String>[];
  late FakeRelay relay;

  setUp(() async {
    rulesWritten.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(proxyChannel, (call) async {
      if (call.method != 'setProxyOverride') return null;
      if (call.arguments
          case {'settings': {'proxyRules': final List<Object?> proxyRules}}) {
        rulesWritten.add([
          for (final rule in proxyRules)
            if (rule case {'url': final String url}) url,
        ].join(' '));
      }
      return null;
    });
    await PlatformInfo.initialize();
    relay = FakeRelay();
    ProxyRouterService.instance
      ..resetForTest()
      ..setRelayForTest(relay);
    SiteNetworkController.attributionProbe = FakeAuthCaches(
      record: ({required nonce, required identity}) =>
          relay.probes[nonce] = identity,
    ).probe;
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(proxyChannel, null);
    ProxyManager.pinBindingForTest(null);
    ProxyRouterService.instance.resetForTest();
    SiteNetworkController.attributionProbe = runAttributionProbe;
  });

  UserProxySettings http(String address) =>
      UserProxySettings(type: ProxyType.HTTP, address: address);

  Future<void> openBoth(WidgetTester tester) async {
    await pumpRealApp(
      tester,
      sites: [
        WebViewModel(
          initUrl: 'https://one.test',
          name: 'One',
          proxySettings: http('127.0.0.1:18081'),
        ),
        WebViewModel(
          initUrl: 'https://two.test',
          name: 'Two',
          proxySettings: http('127.0.0.1:18082'),
        ),
      ],
    );
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'One');
    await attachWebViews(tester);
    await openSiteFromDrawer(tester, name: 'Two');
    await attachWebViews(tester);
  }

  testWidgets('with per-site profiles both stay loaded through the relay '
      '(PROXY-013)', (tester) async {
    ProxyManager.pinBindingForTest(ProxyBinding.routed);
    await openBoth(tester);

    expect(ProxyRouterService.instance.isActive, isTrue,
        reason: 'the launch started the router, with no switch to ask');
    expect(appSite('One').webview, isNotNull,
        reason: 'Two\'s proxy unloaded One, as one rule for the process would');
    expect(appSite('Two').webview, isNotNull);
    final upstreams = {
      for (final route in relay.installed.values) '${route['host']}:${route['port']}',
    };
    expect(upstreams, containsAll(['127.0.0.1:18081', '127.0.0.1:18082']),
        reason: 'each site routed to its own upstream');
    expect(rulesWritten, isEmpty,
        reason: 'no rule names a site\'s proxy where the relay carries them');
    expect(ProcessRoute.instance.occupants, isEmpty,
        reason: 'nothing claims the one rule');
  });

  testWidgets('without per-site profiles opening the second unloads the first '
      '(PROXY-008)', (tester) async {
    ProxyManager.pinBindingForTest(ProxyBinding.processWide);
    await openBoth(tester);

    expect(relay.startCalls, 0, reason: 'the router never starts here');
    expect(appSite('One').webview, isNull,
        reason: 'one rule carries one proxy, so One gives way to Two');
    expect(appSite('Two').webview, isNotNull);
    expect(rulesWritten.last, contains('127.0.0.1:18082'),
        reason: 'the rule names the site on screen\'s own proxy');
  });
}
