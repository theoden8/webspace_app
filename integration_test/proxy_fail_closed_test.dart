// Does a refused proxy leak to the origin? (LEAK-003, BUG-014 gap 2)
//
// This is the one proxy question a single machine cannot answer. It needs a
// destination that is BOTH proxyable -- so not an address this host owns,
// which macOS routes over lo0 and never proxies -- AND reachable directly, so
// that a leak is visible at all. Every other arm here uses `syntheticOrigin()`,
// which has no route and therefore cannot show a leak; a real origin on this
// machine is never proxied and therefore cannot show the proxy working.
//
// A CI service container is both. The Linux job runs inside a container, so a
// service beside it answers on the bridge network at an address this job does
// not own. `WEBSPACE_LEAK_ORIGIN` carries it; without it there is no second
// host and the arm says so rather than asserting something it cannot see.
//
// The leak signal is the page itself. The origin is directly reachable, so a
// load that bypassed the refused proxy SUCCEEDS and the body arrives. Nothing
// has to read the origin's logs.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/settings/proxy.dart';
import 'socks5_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final origin = Platform.environment['WEBSPACE_LEAK_ORIGIN'];
  late Socks5Fixture socks;
  late int deadPort;
  final verdict = <String>[];

  void log(String m) {
    // ignore: avoid_print
    print('[proxy-fail-closed] $m');
  }

  setUpAll(() async {
    if (origin == null || origin.isEmpty) return;
    await PlatformInfo.initialize();
    socks = await Socks5Fixture.bind();
    // Claimed then released: a connection there is refused rather than
    // filtered, so a bound proxy fails fast instead of timing out and the
    // arm cannot pass merely by being slow.
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    deadPort = probe.port;
    await probe.close();
    log('origin=$origin socks=${socks.port} refused=$deadPort '
        'proxySupported=${PlatformInfo.isProxySupported}');
  });

  tearDownAll(() async {
    if (origin == null || origin.isEmpty) return;
    log('socks connects=${socks.targets}');
    log('verdict: ${verdict.join(", ")}');
    await socks.close();
  });

  var generation = 0;
  WebViewController? controller;

  Future<void> mount(WidgetTester tester,
      {required String siteId,
      required String path,
      UserProxySettings? proxySettings}) async {
    final key = ValueKey('failclosed-${generation++}');
    controller = null;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 320,
          height: 240,
          child: KeyedSubtree(
            key: key,
            child: WebViewFactory.createWebView(
              config: WebViewConfig(
                siteId: siteId,
                initialUrl: 'http://$origin$path',
                proxySettings: proxySettings,
                clearUrlEnabled: false,
                dnsBlockEnabled: false,
                contentBlockEnabled: false,
                trackingProtectionEnabled: false,
                localCdnEnabled: false,
              ),
              onControllerCreated: (c) => controller = c,
            ),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// Whether the origin's page actually rendered. The origin serves nginx's
  /// default page, so its marker is what tells a load that arrived from one
  /// that was cancelled, failed or timed out.
  Future<bool> pageArrived(WidgetTester tester,
      {Duration timeout = const Duration(seconds: 20)}) async {
    var arrived = false;
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        final c = controller;
        if (c != null) {
          final body = await c.nativeController
              .evaluateJavascript(source: 'document.body ? document.body.innerText : ""')
              .catchError((Object _) => null);
          if (body != null && '$body'.toLowerCase().contains('nginx')) {
            arrived = true;
            return;
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    });
    return arrived;
  }

  testWidgets('a site whose proxy refuses connections does not reach the origin',
      (tester) async {
    if (origin == null || origin.isEmpty) {
      markTestSkipped(
        'no WEBSPACE_LEAK_ORIGIN: this arm needs an origin on a host this '
        'machine does not own (a CI service container). BUG-014 gap 2.',
      );
      return;
    }
    expect(PlatformInfo.isProxySupported, isTrue,
        reason: 'proxy support reads unavailable; PlatformInfo.initialize() '
            'was most likely not awaited');

    // Control 1: the origin is reachable at all. Without this a refused proxy
    // that reached nothing would be indistinguishable from an origin that was
    // never up, which is the shape gap 5 warns about.
    await mount(tester, siteId: 'fc-direct', path: '/direct');
    final direct = await pageArrived(tester);
    verdict.add('direct=${direct ? "arrived" : "absent"}');
    expect(direct, isTrue,
        reason: 'the unproxied control never reached the origin, so a leak '
            'below could not have been seen either and nothing here is '
            'evidence');

    // Control 2: the origin is proxyable. If the stack refuses to proxy this
    // destination, "no leak" below is free and means nothing.
    await mount(tester,
        siteId: 'fc-proxied',
        path: '/proxied',
        proxySettings: UserProxySettings(
          type: ProxyType.SOCKS5,
          address: '127.0.0.1:${socks.port}',
        ));
    final proxied = await pageArrived(tester);
    final askedFor = socks.targets.isNotEmpty;
    verdict.add('proxied=${proxied ? "arrived" : "absent"} asked=$askedFor');
    expect(askedFor, isTrue,
        reason: 'the fixture proxy was never asked for this destination, so '
            'the stack does not proxy it and the refusal below proves '
            'nothing. Fixture saw: ${socks.targets}');

    // The question. A refused proxy must fail the load, not quietly go round.
    await mount(tester,
        siteId: 'fc-refused',
        path: '/leak-probe',
        proxySettings: UserProxySettings(
          type: ProxyType.SOCKS5,
          address: '127.0.0.1:$deadPort',
        ));
    final leaked = await pageArrived(tester);
    verdict.add('refused=${leaked ? "LEAKED" : "failed-closed"}');
    expect(leaked, isFalse,
        reason: 'a site whose proxy refuses connections reached the origin '
            'anyway, over the device address. A bound proxy cannot do that, '
            'so the per-site proxy was not in force for this load and the '
            'user got the leak the feature exists to prevent');
  });
}
