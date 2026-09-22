// The local CONNECT relay in front of per-site SOCKS5 upstreams: each site
// presents its own credential to one relay endpoint and must come out of its
// own upstream. Destinations are `https://`, terminated by the upstream
// fixture.
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final applies = hostIsIOS || hostIsMacOS;

  void log(String m) {
    // ignore: avoid_print
    print('[proxy-relay] $m');
  }

  /// Two sites in the first frame, two more in a later one. Each gets its own
  /// upstream SOCKS fixture, so "reached its own" is a positive reading off
  /// that fixture's CONNECT log rather than off the origin.
  const siteCount = 4;

  // A CONNECT proxy is a tunnel, and upstream WebKit only ever exercises one
  // with a TLS destination (attempt 37's correction). The first version of
  // this file used http origins and every proxy fixture came back empty, so
  // the origins are https.

  final socks = <Socks5Fixture>[];
  // Destinations, not origins on this machine: macOS routes an address the
  // host owns over `lo0` and Apple never proxies a loopback-routed
  // destination, so an origin bound here reads DIRECT whether or not the
  // proxy was bound (BUG-014 attempt 102). Nothing routes to a
  // `syntheticOrigin`, and the upstream SOCKS fixture terminates the tunnel's
  // TLS itself, so an arrival there IS the proof.
  late LocalProxyRelay relay;
  var containers = false;
  final verdict = <String>[];


  // A positive control in the same frame, and it is what turns a null reading
  // here into a statement. Every CONNECT arm across every run has read DIRECT
  // with an idle fixture, and run 3097 also produced a whole process that
  // proxied nothing at all -- the two are indistinguishable from the outside.
  // A SOCKS pane beside the CONNECT panes, in the same first frame of the
  // same process, separates them: if it binds and they do not, the delivery
  // is the variable.
  late Socks5Fixture controlSocks;
  var control = 'not run';

  Widget controlPane() => SizedBox(
        width: 200,
        height: 90,
        child: inapp.InAppWebView(
          key: const ValueKey('socks-control'),
          initialUrlRequest: inapp.URLRequest(
            url: inapp.WebUri('http://${syntheticOrigin(siteCount)}/ctl'),
          ),
          initialSettings: inapp.InAppWebViewSettings(
            containerId: 'ws-proxy-socks-control',
            proxySettings: inapp.ProxySettings(
              proxyRules: [
                inapp.ProxyRule(url: 'socks5://127.0.0.1:${controlSocks.port}'),
              ],
              bypassRules: [],
            ),
          ),
        ),
      );

  String userFor(int i) => 'ws-relay-site-$i';
  String tokenFor(int i) => 'token-$i-not-a-secret-in-a-test';

  setUpAll(() async {
    if (!applies) return;
    // Without this `isProxySupported` is false and every scenario below
    // skips, which is how two files in this directory once reported green
    // having measured nothing. Ordered before the container query the way
    // proxy_binding orders it, which is the only arm that binds a proxy.
    await PlatformInfo.initialize();
    containers = await ContainerNative.instance.isSupported();
    final ctx = generateSelfSignedCert(
      commonName: syntheticOrigin(0),
      ipAddresses: [
        for (var i = 0; i <= siteCount; i++) syntheticOrigin(i),
        '127.0.0.1',
      ],
    ).serverContext();

    for (var i = 0; i < siteCount; i++) {
      final fixture = await Socks5Fixture.bind();
      fixture.syntheticTls = ctx;
      socks.add(fixture);
    }

    controlSocks = await Socks5Fixture.bind();

    relay = LocalProxyRelay(realm: 'webspace-relay-test');
    expect(
      await relay.start(),
      isTrue,
      reason: 'the relay is the thing under test; if it cannot bind there is '
          'nothing to measure',
    );
    relay.setRoutes({
      for (var i = 0; i < siteCount; i++)
        userFor(i): LocalProxyRoute(
          siteId: 'site-$i',
          token: tokenFor(i),
          upstream: UserProxySettings(
            type: ProxyType.SOCKS5,
            address: '${InternetAddress.loopbackIPv4.address}:${socks[i].port}',
          ),
        ),
    });

    log('relay on ${relay.host}:${relay.port}, '
        'destinations ${List.generate(siteCount, syntheticOrigin).join(",")}, '
        'upstream socks ${socks.map((s) => s.port).join(",")}, '
        'proxySupported=${PlatformInfo.isProxySupported} '
        'containers=$containers');
  });

  tearDownAll(() async {
    if (!applies) return;
    for (var i = 0; i < socks.length; i++) {
      log('socks$i connects=${socks[i].targets}');
    }
    log('socks-control connects=${controlSocks.targets}');
    log('verdict: containers=$containers, first-frame-socks-control=$control, '
        '${verdict.join(", ")}');
    await relay.stop();
    await controlSocks.close();
    for (final s in socks) {
      await s.close();
    }
  });

  bool usable() {
    if (!applies) {
      markTestSkipped('the per-WebView proxy is an Apple path');
      return false;
    }
    expect(
      PlatformInfo.isProxySupported,
      isTrue,
      reason: 'proxy support reads as unavailable on an Apple tier past the '
          'iOS 17 / macOS 14 floor; PlatformInfo.initialize() was most '
          'likely not awaited',
    );
    return true;
  }

  Future<bool> waitReal(
    WidgetTester tester,
    bool Function() done, {
    required String label,
    Duration timeout = const Duration(seconds: 30),
  }) async {
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

  int? upstreamThatSaw(String target) {
    for (var i = 0; i < socks.length; i++) {
      if (socks[i].targets.any((t) => t.startsWith('$target:'))) return i;
    }
    return null;
  }

  /// A pane bound to the relay with site [i]'s credential. The proxy every
  /// pane carries is byte-identical apart from that credential, which is the
  /// whole point.
  Widget pane(int i) => SizedBox(
        width: 200,
        height: 90,
        child: inapp.InAppWebView(
          key: ValueKey('relay$i'),
          initialUrlRequest: inapp.URLRequest(
            url: inapp.WebUri('https://${syntheticOrigin(i)}/s$i'),
          ),
          initialSettings: inapp.InAppWebViewSettings(
            containerId: 'ws-proxy-relay-$i',
            proxySettings: inapp.ProxySettings(
              proxyRules: [
                inapp.ProxyRule(
                  url: 'http://${relay.host}:${relay.port}',
                  username: userFor(i),
                  password: tokenFor(i),
                ),
              ],
              bypassRules: [],
            ),
          ),
          // The origin certificate is self-signed and minted for this run, so
          // the load only reaches it if this accepts it. Scoped to this file.
          onReceivedServerTrustAuthRequest: (controller, challenge) async =>
              inapp.ServerTrustAuthResponse(
            action: inapp.ServerTrustAuthResponseAction.PROCEED,
          ),
        ),
      );

  String classify(int i) {
    final saw = upstreamThatSaw(syntheticOrigin(i));
    if (saw == i) return 'own(socks$saw)';
    if (saw != null) return 'CROSSED(socks$saw)';
    return 'DIRECT-or-failed';
  }

  Future<List<String>> run(
    WidgetTester tester,
    List<int> panes, {
    required String label,
    bool withControl = false,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          for (final i in panes) pane(i),
          if (withControl) controlPane(),
        ]),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));

    bool settled(int i) =>
        upstreamThatSaw(syntheticOrigin(i)) != null;

    await waitReal(tester, () => panes.every(settled), label: label);
    return [for (final i in panes) 's$i->${classify(i)}'];
  }

  testWidgets('the first frame: two sites, two upstreams, one relay',
      (tester) async {
    if (!usable()) return;
    final results =
        await run(tester, [0, 1], label: 'first-frame panes', withControl: true);
    verdict.add('first-frame=[${results.join(" ")}]');

    control = controlSocks.targets
            .any((t) => t.startsWith('${syntheticOrigin(siteCount)}:'))
        ? 'proxied'
        : 'DIRECT-or-failed';
    log('first-frame socks control -> $control');

    expect(
      control,
      'proxied',
      reason: 'the SOCKS pane in this same first frame went $control. A '
          'process that proxies nothing reads exactly like a delivery that '
          'is never used, and the relay result below cannot be told apart '
          'from the first without this',
    );
    expect(
      results.where((r) => r.contains('own(')).length,
      2,
      reason: 'two stores on one relay endpoint, each with its own credential, '
          'must each reach their own upstream. Got [${results.join(" ")}]',
    );
  });

  testWidgets('a later frame: the case every other arrangement lost',
      (tester) async {
    if (!usable()) return;
    final results = await run(tester, [2, 3], label: 'later-frame panes');
    verdict.add('later-frame=[${results.join(" ")}]');
    expect(
      results.where((r) => r.contains('own(')).length,
      2,
      reason: 'this is the reading BUG-014 turns on: stores built after the '
          'first frame went direct on every earlier arrangement. Got '
          '[${results.join(" ")}]',
    );
  });
}
