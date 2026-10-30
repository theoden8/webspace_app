// On-device proof that a failed attribution check fails closed (PROXY-013,
// PROXY-015). No CI image shares a proxy auth cache across profiles, so the
// probe is crossed on purpose: site A's nonce is fetched from site B's
// container with B's credential, which is exactly what the relay records on
// a device whose profiles share one cache. Router mode must then stand down
// for the run and take the process-wide rule off the relay: there is no
// fallback to one rule where the WebView gives each site a profile. Each
// proxied site shows the block and reaches no upstream, and a site with no
// proxy still loads, directly. Only the WebView's navigations count: the
// app's own icon fetches go to each site's proxy from Dart either way. The
// unit tier proves the decision against
// fakes; this proves it on a real WebView, where a rule left pointing at a
// stopped relay would fail the direct site too.
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
import 'package:webspace/widgets/unproxied_block.dart';

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
  late RecordingUpstream originC;
  final a = RouterIdentity.ofSite(SiteId('fallback-a'));
  final b = RouterIdentity.ofSite(SiteId('fallback-b'));
  final crossed = <RouterIdentity>[];

  setUpAll(() async {
    isDemoMode = true;
    await installInMemoryKeychainIfUnavailable();

    upstreamA = await RecordingUpstream.start('A');
    upstreamB = await RecordingUpstream.start('B');
    // Not a proxy: the origin a site with no proxy loads straight from.
    originC = await RecordingUpstream.start('C');

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
    final siteC = WebViewModel(
      siteId: SiteId('fallback-c'),
      initUrl: 'http://127.0.0.1:${originC.port}/',
      name: 'Direct C',
    );
    SharedPreferences.setMockInitialValues({
      'webViewModels': [
        for (final site in [siteA, siteB, siteC]) jsonEncode(site.toJson()),
      ],
    });
  });

  tearDownAll(() async {
    SiteNetworkController.attributionProbe = runAttributionProbe;
    await upstreamA.close();
    await upstreamB.close();
    await originC.close();
  });

  testWidgets('a failed attribution check fails closed (PROXY-013)', (
    tester,
  ) async {
    if (!hostIsAndroid) {
      markTestSkipped('router mode is Android-only');
      return;
    }

    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 30));

    if (!await ContainerNative.instance.isSupported()) {
      markTestSkipped('no MULTI_PROFILE: one rule carries each proxy');
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
    expect(ProxyRouterService.instance.failed, isTrue,
        reason: 'not tried again this run');
    expect(ProxyRouterService.instance.port, isNull);

    for (final name in ['Fallback A', 'Fallback B']) {
      LogTag.test.info('opening $name');
      await openSiteFromDrawer(tester, name: name);
      expect(
        find.byType(UnproxiedNavigationBlock),
        findsOneWidget,
        reason: '$name has a proxy no relay carries: it shows the block',
      );
    }
    LogTag.test.info('opening Direct C');
    await openSiteFromDrawer(tester, name: 'Direct C');
    if (upstreamA.navigations.isNotEmpty ||
        upstreamB.navigations.isNotEmpty ||
        originC.navigations.isEmpty) {
      // ignore: avoid_print
      print(timeline(a: upstreamA, b: upstreamB));
    }

    // The app's icon fetches still reach each site's own proxy from Dart,
    // which is where they belong; what must reach nothing is the WebView.
    expect(
      originC.navigations,
      isNotEmpty,
      reason: 'a site with no proxy goes direct: a rule left on the stopped '
          'relay would fail it. Without this, nothing below says the proxied '
          'sites made no navigation (C=${originC.requestLines})',
    );
    expect(
      [...upstreamA.navigations, ...upstreamB.navigations],
      isEmpty,
      reason: 'a proxied site must reach nothing once the router is down: '
          'there is no one rule to fall back to '
          '(A=${upstreamA.navigations}, B=${upstreamB.navigations})',
    );
    expect(
      [...upstreamA.credentials, ...upstreamB.credentials],
      isEmpty,
      reason: 'no router credential outlives the stand-down',
    );
  });
}
