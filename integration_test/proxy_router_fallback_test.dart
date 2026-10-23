// On-device proof that a failed attribution check falls back to PROXY-008
// (PROXY-015). No CI image shares a proxy auth cache across profiles, so the
// probe is crossed on purpose: site A's nonce is fetched from site B's
// container with B's credential, which is exactly what the relay records on
// a device whose profiles share one cache. Router mode must then stand down
// without clearing the process-wide rule, and each site must still reach its
// own upstream, one at a time, through the rule PROXY-008 applies as it
// activates. The unit tier proves the decision against fakes; this proves
// the stand-down on a real WebView, where a rule left pointing at a stopped
// relay would fail every site instead.
//
// Android-only by construction, like the router.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/controllers/site_network_controller.dart';
import 'package:webspace/main.dart' as app;
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/container_native.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/proxy_router_engine.dart';
import 'package:webspace/services/proxy_router_probe.dart';
import 'package:webspace/services/proxy_router_service.dart';
import 'package:webspace/settings/demo_mode.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/proxy_upstreams.dart';
import 'secure_storage_fake.dart';

/// Every request each upstream saw, merged with the app's own proxy,
/// unload and webview log lines, in the order they happened.
String timeline({required RecordingUpstream a, required RecordingUpstream b}) {
  const tags = {
    'Proxy',
    'ProxyRelay',
    'SiteUnload',
    'WebView',
    'WebViewLifecycle',
    'SiteIcon',
    'Startup',
    'Test',
  };
  final events = <(DateTime, String)>[
    for (final (at, line) in a.timeline) (at, 'upstream A <- $line'),
    for (final (at, line) in b.timeline) (at, 'upstream B <- $line'),
    for (final e in LogService.instance.allEntriesMerged)
      if (tags.contains(e.tag)) (e.timestamp, '[${e.tag}] ${e.message}'),
  ]..sort((x, y) => x.$1.compareTo(y.$1));
  return [
    'fallback timeline:',
    for (final (at, what) in events) '${at.toIso8601String()} $what',
  ].join('\n');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late RecordingUpstream upstreamA;
  late RecordingUpstream upstreamB;
  final a = RouterIdentity.ofSite(SiteId('fallback-a'));
  final b = RouterIdentity.ofSite(SiteId('fallback-b'));
  final crossed = <RouterIdentity>[];

  setUpAll(() async {
    isDemoMode = true;
    await installInMemoryKeychainIfUnavailable();

    upstreamA = await RecordingUpstream.start('A');
    upstreamB = await RecordingUpstream.start('B');

    // Each probe runs in the other site's container, answering with that
    // site's credential: the relay sees the wrong identity carry the nonce.
    SiteNetworkController.attributionProbe = (identity, {required url}) {
      crossed.add(identity);
      return runAttributionProbe(identity == a ? b : a, url: url);
    };

    final siteA = WebViewModel(
      siteId: SiteId('fallback-a'),
      initUrl: 'http://a.example.test/',
      name: 'Fallback A',
      proxySettings: UserProxySettings(
        type: ProxyType.HTTP,
        address: '127.0.0.1:${upstreamA.port}',
      ),
    );
    final siteB = WebViewModel(
      siteId: SiteId('fallback-b'),
      initUrl: 'http://b.example.test/',
      name: 'Fallback B',
      proxySettings: UserProxySettings(
        type: ProxyType.HTTP,
        address: '127.0.0.1:${upstreamB.port}',
      ),
    );
    SharedPreferences.setMockInitialValues({
      'webViewModels': [jsonEncode(siteA.toJson()), jsonEncode(siteB.toJson())],
    });
  });

  tearDownAll(() async {
    SiteNetworkController.attributionProbe = runAttributionProbe;
    await upstreamA.close();
    await upstreamB.close();
  });

  testWidgets('a failed attribution check falls back to PROXY-008', (
    tester,
  ) async {
    if (!hostIsAndroid) {
      markTestSkipped('router mode is Android-only');
      return;
    }

    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 30));

    if (!await ContainerNative.instance.isSupported()) {
      markTestSkipped('no MULTI_PROFILE: the router never starts');
      return;
    }
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }

    expect(
      crossed,
      isNotEmpty,
      reason: 'the router must have been brought up and checked',
    );
    expect(
      ProxyRouterService.instance.isActive,
      isFalse,
      reason: 'a device that cannot attribute must not run router mode',
    );
    expect(ProxyRouterService.instance.port, isNull);

    for (final name in ['Fallback A', 'Fallback B']) {
      LogTag.test.info('opening $name');
      await openSiteFromDrawer(tester, name: name);
    }
    // ignore: avoid_print
    print(timeline(a: upstreamA, b: upstreamB));

    expect(
      upstreamA.wasReached,
      isTrue,
      reason:
          'site A must reach its own proxy once the router is down: '
          'a rule left on the stopped relay fails every site '
          '(A=${upstreamA.requestLines}, B=${upstreamB.requestLines})',
    );
    expect(
      upstreamB.wasReached,
      isTrue,
      reason:
          'site B must reach its own proxy once A gives way '
          '(A=${upstreamA.requestLines}, B=${upstreamB.requestLines})',
    );
    expect(
      upstreamA.onlyFor('a.example.test'),
      isTrue,
      reason: 'upstream A saw another site: ${upstreamA.requestLines}',
    );
    expect(
      upstreamB.onlyFor('b.example.test'),
      isTrue,
      reason: 'upstream B saw another site: ${upstreamB.requestLines}',
    );
    expect(
      [...upstreamA.credentials, ...upstreamB.credentials],
      isEmpty,
      reason: 'no router credential outlives the stand-down',
    );
  });
}
