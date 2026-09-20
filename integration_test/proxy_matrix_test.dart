// A hard yes or no on the per-site proxy on Apple (BUG-014, LEAK-003).
//
// Every earlier arm varied more than one thing at a time, so the readings
// could not be compared. `proxy_relay_binding` used HTTP CONNECT to a
// credentialed loopback relay with https origins and its first frame bound
// two sites to two upstreams; `proxy_simultaneous` used SOCKS5 with http
// origins and its first frame bound nothing. Those two differ in delivery,
// in destination scheme, and in relay-vs-direct at once.
//
// This file crosses the three, in one process, with a control that says
// whether the process proxied anything at all:
//
//   delivery     CONNECT (credentialed relay)  |  SOCKS5 (direct)
//   destination  https                         |  http
//   timing       bound and navigated in frame 1
//                bound in frame 1, navigated in a later frame
//                bound and navigated in a later frame
//
// The third timing row is the product question. The app creates a site's
// WebView when the site is activated, which is never frame 1, so if only
// frame 1 can bind then per-site proxies are unreachable as the app is
// built. If a store BOUND in frame 1 still proxies a navigation issued
// later, then pre-creating a hidden WebView per proxied site at startup is
// a fix that keeps lazy navigation.
//
// Attribution is the relay's: `LocalProxyRelay._routeFor` reads only
// `Proxy-Authorization: Basic`, requires an exact user+token match, and
// otherwise answers 407. A pane reaching its own upstream therefore proves
// WebKit sent that store's credential.
//
// Run it more than once per tier: "frame 1" happens once per process, and
// binding has varied between processes in the same run, so a single verdict
// line is one draw.

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
import 'fixture_server.dart';
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
  final origins = <HttpServer>[];
  final ports = <int>[];
  final requests = <String>[];
  late LocalProxyRelay relay;
  late Socks5Fixture controlSocks;
  late HttpServer controlOrigin;
  var controlPort = 0;
  var control = 'not run';
  InternetAddress? routable;
  var originHost = '127.0.0.1';
  var containers = false;
  inapp.InAppWebViewController? preboundController;

  String userFor(int i) => 'ws-matrix-site-$i';
  String tokenFor(int i) => 'token-$i-not-a-secret-in-a-test';
  String urlFor(int i) =>
      '${cells[i].https ? "https" : "http"}://$originHost:${ports[i]}/s$i';

  setUpAll(() async {
    if (!applies) return;
    // Without this `isProxySupported` is false, every arm skips, and the file
    // reports green having measured nothing.
    await PlatformInfo.initialize();
    containers = await ContainerNative.instance.isSupported();
    routable = await nonLoopbackIPv4();
    originHost = routable?.address ?? '127.0.0.1';

    final ctx = generateSelfSignedCert(
      commonName: originHost,
      ipAddresses: {originHost, '127.0.0.1'}.toList(),
    ).serverContext();

    for (var i = 0; i < cells.length; i++) {
      final origin = cells[i].https
          ? await HttpServer.bindSecure(InternetAddress.anyIPv4, 0, ctx)
          : await HttpServer.bind(InternetAddress.anyIPv4, 0);
      origins.add(origin);
      ports.add(origin.port);
      listenFixture(origin, (req) async {
        requests.add('s$i:${req.uri.path}');
        final res = req.response..headers.contentType = ContentType.html;
        res.write('<!doctype html><html><body><p>s$i</p></body></html>');
        await res.close();
      });
      socks.add(await Socks5Fixture.bind());
    }

    controlSocks = await Socks5Fixture.bind();
    controlOrigin = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    controlPort = controlOrigin.port;
    listenFixture(controlOrigin, (req) async {
      requests.add('ctl:${req.uri.path}');
      final res = req.response..headers.contentType = ContentType.html;
      res.write('<!doctype html><html><body><p>ctl</p></body></html>');
      await res.close();
    });

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

    log('run=$runLabel relay=${relay.host}:${relay.port} host=$originHost '
        'origins=${ports.join(",")} socks=${socks.map((s) => s.port).join(",")} '
        'control=$controlPort/${controlSocks.port} '
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
    await controlOrigin.close(force: true);
    for (final s in socks) {
      await s.close();
    }
    for (final o in origins) {
      await o.close(force: true);
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
              url: inapp.WebUri('http://$originHost:$controlPort/ctl')),
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
      if (socks[i].targets.contains(target)) return i;
    }
    return null;
  }

  String classify(int i) {
    final saw = upstreamThatSaw('$originHost:${ports[i]}');
    if (saw == i) return 'own';
    if (saw != null) return 'CROSSED(socks$saw)';
    return requests.any((r) => r.startsWith('s$i:')) ? 'DIRECT' : 'no-load';
  }

  bool settled(int i) =>
      upstreamThatSaw('$originHost:${ports[i]}') != null ||
      requests.any((r) => r.startsWith('s$i:'));

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
    expect(routable, isNotNull,
        reason: 'no non-loopback IPv4 here, and Apple never sends a loopback '
            'destination through a proxy, so nothing could be distinguished');
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
    control = controlSocks.targets.contains('$originHost:$controlPort')
        ? 'proxied'
        : requests.contains('ctl:/ctl')
            ? 'DIRECT'
            : 'no-load';
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
