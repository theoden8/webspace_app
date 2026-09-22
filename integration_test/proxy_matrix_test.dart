// Delivery crossed against destination scheme: direct SOCKS5 and a
// credentialed CONNECT relay, each against http and https destinations, plus
// a pre-bound store navigated later. One cell per combination, one upstream
// each, so a crossed circuit is named rather than counted.
//
// Destinations are `syntheticOrigin()` addresses. An address this machine owns
// is routed over `lo0` and Apple never proxies a loopback-routed destination,
// so an origin bound here reads DIRECT whether or not the proxy was bound --
// the defect that voided BUG-014's first 101 attempts. Nothing routes to a
// synthetic destination, so the fixture answers it and an arrival there is the
// proof.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/container_native.dart';
import 'package:webspace/services/local_proxy_relay.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/settings/proxy.dart';
import 'self_signed_cert.dart';
import 'socks5_fixture.dart';

/// One cell of the matrix.
class Cell {
  Cell(this.name, {required this.connect, required this.https});

  final String name;
  final bool connect;
  final bool https;
  String verdict = 'not run';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final applies = hostIsIOS || hostIsMacOS;
  final runLabel = Platform.environment['WEBSPACE_MATRIX_RUN'] ?? '1';

  void log(String m) {
    // ignore: avoid_print
    print('[proxy-matrix] $m');
  }

  // 0,1  frame-1 CONNECT https   (simultaneity: two sites, two upstreams)
  // 2    frame-1 SOCKS5  https   (delivery comparison)
  // 3    frame-1 SOCKS5  http    (destination comparison)
  // 4    bound frame 1, navigated later, CONNECT https  (the candidate fix)
  // 5    built and navigated later, CONNECT https
  // 6    built and navigated later, SOCKS5  https
  final cells = [
    Cell('f1-connect-https-a', connect: true, https: true),
    Cell('f1-connect-https-b', connect: true, https: true),
    Cell('f1-socks-https', connect: false, https: true),
    Cell('f1-socks-http', connect: false, https: false),
    Cell('prebound-connect-https', connect: true, https: true),
    Cell('late-connect-https', connect: true, https: true),
    Cell('late-socks-https', connect: false, https: true),
  ];
  const preboundIndex = 4;

  final socks = <Socks5Fixture>[];
  // Destinations, not origins on this machine: macOS routes an address the
  // host owns over `lo0` and Apple never proxies a loopback-routed
  // destination, so an origin bound here reads DIRECT whether or not the
  // proxy was bound (BUG-014 caution 1). Nothing routes to a
  // `syntheticOrigin`, and the upstream fixture terminates TLS for the https
  // cells itself, so an arrival there IS the proof.
  late LocalProxyRelay relay;
  late Socks5Fixture controlSocks;
  var control = 'not run';
  var containers = false;
  inapp.InAppWebViewController? preboundController;

  String userFor(int i) => 'ws-matrix-site-$i';
  String tokenFor(int i) => 'token-$i-not-a-secret-in-a-test';
  String urlFor(int i) =>
      '${cells[i].https ? "https" : "http"}://${syntheticOrigin(i)}/s$i';

  setUpAll(() async {
    if (!applies) return;
    // Without this `isProxySupported` is false, every arm skips, and the file
    // reports green having measured nothing.
    await PlatformInfo.initialize();
    containers = await ContainerNative.instance.isSupported();
    final ctx = generateSelfSignedCert(
      commonName: syntheticOrigin(0),
      ipAddresses: [
        for (var i = 0; i <= cells.length; i++) syntheticOrigin(i),
        '127.0.0.1',
      ],
    ).serverContext();

    for (var i = 0; i < cells.length; i++) {
      final fixture = await Socks5Fixture.bind();
      if (cells[i].https) fixture.syntheticTls = ctx;
      socks.add(fixture);
    }

    controlSocks = await Socks5Fixture.bind();

    relay = LocalProxyRelay(realm: 'webspace-matrix');
    expect(await relay.start(), isTrue,
        reason: 'the relay carries half the matrix; if it cannot bind there '
            'is nothing to measure');
    relay.setRoutes({
      for (var i = 0; i < cells.length; i++)
        userFor(i): LocalProxyRoute(
          siteId: 'site-$i',
          token: tokenFor(i),
          upstream: UserProxySettings(
            type: ProxyType.SOCKS5,
            address: '${InternetAddress.loopbackIPv4.address}:${socks[i].port}',
          ),
        ),
    });

    log('run=$runLabel relay=${relay.host}:${relay.port} '
        'destinations=${List.generate(cells.length, syntheticOrigin).join(",")} '
        'socks=${socks.map((s) => s.port).join(",")} '
        'control=${syntheticOrigin(cells.length)}/${controlSocks.port} '
        'proxySupported=${PlatformInfo.isProxySupported} containers=$containers');
  });

  tearDownAll(() async {
    if (!applies) return;
    for (var i = 0; i < cells.length; i++) {
      log('socks$i (${cells[i].name}) connects=${socks[i].targets}');
    }
    log('run=$runLabel verdict: containers=$containers control=$control '
        '${[for (final c in cells) "${c.name}=${c.verdict}"].join(" ")}');
    await relay.stop();
    await controlSocks.close();
    for (final s in socks) {
      await s.close();
    }
  });

  inapp.InAppWebViewSettings settingsFor(int i) => inapp.InAppWebViewSettings(
        containerId: 'ws-matrix-$runLabel-$i',
        proxySettings: inapp.ProxySettings(
          proxyRules: [
            if (cells[i].connect)
              inapp.ProxyRule(
                url: 'http://${relay.host}:${relay.port}',
                username: userFor(i),
                password: tokenFor(i),
              )
            else
              inapp.ProxyRule(url: 'socks5://127.0.0.1:${socks[i].port}'),
          ],
          bypassRules: [],
        ),
      );

  Widget pane(int i, {String? url}) => SizedBox(
        width: 160,
        height: 60,
        child: inapp.InAppWebView(
          key: ValueKey('matrix-$i'),
          initialUrlRequest: inapp.URLRequest(url: inapp.WebUri(url ?? urlFor(i))),
          initialSettings: settingsFor(i),
          onWebViewCreated: (c) {
            if (i == preboundIndex) preboundController = c;
          },
          onReceivedServerTrustAuthRequest: (controller, challenge) async =>
              inapp.ServerTrustAuthResponse(
                  action: inapp.ServerTrustAuthResponseAction.PROCEED),
        ),
      );

  Widget controlPane() => SizedBox(
        width: 160,
        height: 60,
        child: inapp.InAppWebView(
          key: const ValueKey('matrix-control'),
          initialUrlRequest: inapp.URLRequest(
              url: inapp.WebUri('http://${syntheticOrigin(cells.length)}/ctl')),
          initialSettings: inapp.InAppWebViewSettings(
            containerId: 'ws-matrix-$runLabel-control',
            proxySettings: inapp.ProxySettings(
              proxyRules: [
                inapp.ProxyRule(url: 'socks5://127.0.0.1:${controlSocks.port}')
              ],
              bypassRules: [],
            ),
          ),
        ),
      );

  int? upstreamThatSaw(String target) {
    for (var i = 0; i < socks.length; i++) {
      if (socks[i].targets.any((t) => t.startsWith('$target:'))) return i;
    }
    return null;
  }

  /// Nothing routes to a synthetic destination, so a cell that reached no
  /// upstream went direct and could not have loaded.
  String classify(int i) {
    final saw = upstreamThatSaw(syntheticOrigin(i));
    if (saw == i) return 'own';
    if (saw != null) return 'CROSSED(socks$saw)';
    return 'DIRECT-or-failed';
  }

  bool settled(int i) => upstreamThatSaw(syntheticOrigin(i)) != null;

  Future<void> waitReal(WidgetTester tester, bool Function() done,
      {required String label, Duration timeout = const Duration(seconds: 25)}) async {
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
  }

  bool usable() {
    if (!applies) {
      markTestSkipped('the per-WebView proxy is an Apple path');
      return false;
    }
    expect(PlatformInfo.isProxySupported, isTrue,
        reason: 'proxy support reads unavailable past the floor; '
            'PlatformInfo.initialize() was most likely not awaited');
    return true;
  }

  // Frame 1 carries every cell that must be bound there, including the
  // prebound one, which navigates to about:blank now and to its origin in
  // the later frame. Its store is therefore created and configured here.
  testWidgets('frame 1: the delivery and destination cross', (tester) async {
    if (!usable()) return;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Column(children: [
            pane(0),
            pane(1),
            pane(2),
            pane(3),
            pane(preboundIndex, url: 'about:blank'),
            controlPane(),
          ]),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));
    await waitReal(tester, () => [0, 1, 2, 3].every(settled),
        label: 'frame-1 panes');
    for (final i in [0, 1, 2, 3]) {
      cells[i].verdict = classify(i);
    }
    control = controlSocks.targets
            .any((t) => t.startsWith('${syntheticOrigin(cells.length)}:'))
        ? 'proxied'
        : 'DIRECT-or-failed';
    log('frame-1: control=$control '
        '${[for (final i in [0, 1, 2, 3]) "${cells[i].name}=${cells[i].verdict}"].join(" ")}');
  });

  // The product question. The prebound store was created and configured in
  // frame 1; only the navigation happens here. If this proxies while the
  // freshly built panes below do not, the app can pre-create a hidden
  // WebView per proxied site at startup and keep navigating lazily.
  testWidgets('later frame: prebound store vs freshly built stores',
      (tester) async {
    if (!usable()) return;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Column(children: [
            pane(preboundIndex, url: 'about:blank'),
            pane(5),
            pane(6),
          ]),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));

    final controller = preboundController;
    expect(controller, isNotNull,
        reason: 'the prebound pane never reported a controller, so its '
            'navigation could not be issued and its cell means nothing');
    await tester.runAsync(() async {
      await controller!.loadUrl(
          urlRequest: inapp.URLRequest(url: inapp.WebUri(urlFor(preboundIndex))));
    });

    await waitReal(tester, () => [preboundIndex, 5, 6].every(settled),
        label: 'later-frame panes');
    for (final i in [preboundIndex, 5, 6]) {
      cells[i].verdict = classify(i);
    }
    log('later-frame: '
        '${[for (final i in [preboundIndex, 5, 6]) "${cells[i].name}=${cells[i].verdict}"].join(" ")}');

    // Reported, not asserted. Every cell here is an open question -- that is
    // what the file is for -- and a process that proxied nothing (control
    // DIRECT in frame 1) produces the same null reading as a delivery that
    // does not work. The tier summary reads the verdict lines across runs.
    expect(control, isNot('no-load'),
        reason: 'the frame-1 control never loaded at all, so this process '
            'measured nothing and its verdict line must not be counted');
  });
}
