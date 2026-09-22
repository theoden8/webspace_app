// The Apple relay path, which the app does not take (PROXY-026).
//
// Apple binds each store's real upstream directly: WKWebsiteDataStore carries
// one proxy configuration per store, and BUG-014 measured that
// delivering distinct upstreams AND distinct credentials per store, so the
// relay is a local hop that buys nothing there. `appleRelayEnabled` defaults
// false and this arm is the only thing that turns it on.
//
// It exists so "kept for parity testing" means something. The implementation
// stays because the two platforms' router behaviour has to stay comparable,
// and an implementation nothing exercises is one that rots between the day it
// is kept and the day someone needs it. The assertion is Android's
// (`proxy_router_attribution_test`): two sites, one relay endpoint, told apart
// by the credential each presents, and each must come out of its own upstream.
// A shared credential cache shows up as one upstream seeing both.
//
// Destinations are `syntheticOrigin()` addresses. An address this machine owns
// is routed over `lo0` and Apple never proxies a loopback-routed destination,
// so an origin bound here reads DIRECT whether or not the proxy was bound --
// the defect that voided BUG-014's first 101 attempts. Nothing routes to a
// synthetic destination, so the upstream fixture answers it and an arrival
// there is the proof.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/container_native.dart';
import 'package:webspace/services/proxy_binding_engine.dart';
import 'package:webspace/services/proxy_router_service.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/settings/proxy.dart';
import 'socks5_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final applies = hostIsIOS || hostIsMacOS;

  const siteA = 'parity-a';
  const siteB = 'parity-b';
  const destA = 0;
  const destB = 1;

  late Socks5Fixture upstreamA;
  late Socks5Fixture upstreamB;
  var containers = false;
  final verdict = <String>[];

  void log(String m) {
    // ignore: avoid_print
    print('[proxy-apple-parity] $m');
  }

  setUpAll(() async {
    if (!applies) return;
    await PlatformInfo.initialize();
    containers = await ContainerNative.instance.isSupported();
    upstreamA = await Socks5Fixture.bind();
    upstreamB = await Socks5Fixture.bind();
    ProxyRouterService.appleRelayEnabled = true;
    log('upstreams ${upstreamA.port}/${upstreamB.port} '
        'proxySupported=${PlatformInfo.isProxySupported} '
        'containers=$containers');
  });

  tearDownAll(() async {
    if (!applies) return;
    log('upstreamA connects=${upstreamA.targets} '
        'upstreamB connects=${upstreamB.targets}');
    log('verdict: containers=$containers, ${verdict.join(", ")}');
    // Put it back: this flag is off in every other arm and in the app, and a
    // leaked true would quietly move them onto a path they do not take.
    ProxyRouterService.appleRelayEnabled = false;
    await ProxyRouterService.instance.deactivate();
    ProxyRouterService.instance.resetForTest();
    await upstreamA.close();
    await upstreamB.close();
  });

  bool saw(Socks5Fixture f, int dest) =>
      f.targets.any((t) => t.startsWith('${syntheticOrigin(dest)}:'));

  Future<bool> waitReal(WidgetTester tester, bool Function() done,
      {required String label,
      Duration timeout = const Duration(seconds: 30)}) async {
    var ok = false;
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        if (done()) {
          ok = true;
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      ok = done();
    });
    log('$label -> ${ok ? "ok" : "timeout"}');
    return ok;
  }

  testWidgets('two sites through one relay endpoint reach their own upstreams',
      (tester) async {
    if (!applies) {
      markTestSkipped('the Apple relay path is an Apple path');
      return;
    }
    expect(PlatformInfo.isProxySupported, isTrue,
        reason: 'proxy support reads unavailable past the floor; '
            'PlatformInfo.initialize() was most likely not awaited');
    expect(ProxyManager.binding, ProxyBinding.perSite,
        reason: 'the Apple relay rides the per-store binding; under the '
            'process-wide one routerRelayProxyFor returns null by design');
    if (!containers) {
      markTestSkipped('no containers: the relay routes per container store');
      return;
    }

    // No bindOverride: Apple has no process-wide rule to point, which is the
    // half of PROXY-026 that is still true. No probe either -- the attribution
    // this arm makes is the origin-side one below, not the PROXY-015
    // self-check, and a probe here would assert the thing under test.
    final port = await tester.runAsync(() => ProxyRouterService.instance.activate(
          perSiteProxies: {
            siteA: UserProxySettings(
              type: ProxyType.SOCKS5,
              address: '127.0.0.1:${upstreamA.port}',
            ),
            siteB: UserProxySettings(
              type: ProxyType.SOCKS5,
              address: '127.0.0.1:${upstreamB.port}',
            ),
          },
        ));
    expect(port, isNotNull,
        reason: 'the relay did not bind, so there is no parity path to test');
    expect(ProxyRouterService.instance.isActive, isTrue);
    log('relay on ${ProxyRouterService.instance.host}:$port');

    Widget pane(String siteId, int dest) => SizedBox(
          width: 200,
          height: 90,
          child: WebViewFactory.createWebView(
            config: WebViewConfig(
              siteId: siteId,
              initialUrl: 'http://${syntheticOrigin(dest)}/$siteId',
              clearUrlEnabled: false,
              dnsBlockEnabled: false,
              contentBlockEnabled: false,
              trackingProtectionEnabled: false,
              localCdnEnabled: false,
            ),
            onControllerCreated: (_) {},
          ),
        );

    // No proxySettings on either config: under router mode the site's own rule
    // is made at the relay, and every store points at the relay instead.
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [pane(siteA, destA), pane(siteB, destB)]),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));

    await waitReal(tester, () => saw(upstreamA, destA) && saw(upstreamB, destB),
        label: 'both panes settled');

    final a = saw(upstreamA, destA);
    final b = saw(upstreamB, destB);
    final crossed = saw(upstreamB, destA) || saw(upstreamA, destB);
    verdict.add('a=${a ? "own" : "no"} b=${b ? "own" : "no"} crossed=$crossed');

    expect(crossed, isFalse,
        reason: 'a site came out of the other site\'s upstream: the relay '
            'attributed by a credential it had already cached, which is the '
            'failure this arm exists to catch');
    expect(a && b, isTrue,
        reason: 'the Apple relay path no longer routes two sites to two '
            'upstreams. The app does not take this path (PROXY-026), so this '
            'is not a user-facing leak -- it means the implementation kept '
            'for parity testing has rotted, and Android\'s router can no '
            'longer be compared against it');
  });
}
