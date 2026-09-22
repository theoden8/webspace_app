// Three containers over three distinct HTTP CONNECT proxies with `https://`
// destinations, plus a SOCKS control in the same first frame.
//
// A CONNECT proxy is a tunnel, so the destination's TLS has to terminate
// somewhere; nothing routes to a synthetic destination, so the fixture
// terminates it (`syntheticTls`).
//
// Destinations are `syntheticOrigin()` addresses. An address this machine owns
// is routed over `lo0` and Apple never proxies a loopback-routed destination,
// so an origin bound here reads DIRECT whether or not the proxy was bound --
// the defect that voided BUG-014's first 101 attempts. Nothing routes to a
// synthetic destination, so the fixture answers it and an arrival there is the
// proof.

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/container_native.dart';
import 'package:webspace/services/webview.dart';
import 'http_connect_fixture.dart';
import 'self_signed_cert.dart';
import 'socks5_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final applies = hostIsIOS || hostIsMacOS;

  void log(String m) {
    // ignore: avoid_print
    print('[proxy-connect-https] $m');
  }

  const paneCount = 3;

  final proxies = <HttpConnectFixture>[];
  // Destinations, not origins on this machine: macOS routes an address the
  // host owns over `lo0` and Apple never proxies a loopback-routed
  // destination, so an origin bound here reads DIRECT whether or not the
  // proxy was bound (BUG-014 caution 1). Nothing routes to a
  // `syntheticOrigin`, and for https the CONNECT fixture terminates the
  // tunnel's TLS itself, so an arrival there IS the proof.
  var containers = false;
  final verdict = <String>[];

  // A SOCKS pane in the same first frame of the same process. Every CONNECT
  // arm has read DIRECT with an idle fixture in every run, and run 3097 also
  // produced a process that proxied nothing at all; from outside the two look
  // the same. If this binds and the CONNECT panes beside it do not, the
  // delivery is the variable rather than the process.
  late Socks5Fixture controlSocks;
  var control = 'not run';


  setUpAll(() async {
    if (!applies) return;
    // Ordered the way proxy_binding orders it, which is the only arm that
    // binds a proxy. Whether that matters is unmeasured; removing the
    // difference costs nothing and leaves one fewer variable.
    await PlatformInfo.initialize();
    containers = await ContainerNative.instance.isSupported();
    // Minted for the synthetic destinations, because the CONNECT fixture is
    // what answers their handshake now: nothing routes to them, so there is
    // no origin server behind the tunnel to terminate TLS.
    final ctx = generateSelfSignedCert(
      commonName: syntheticOrigin(0),
      ipAddresses: [
        for (var i = 0; i <= paneCount; i++) syntheticOrigin(i),
        '127.0.0.1',
      ],
    ).serverContext();

    for (var i = 0; i < paneCount; i++) {
      final proxy = await HttpConnectFixture.bind();
      proxy.syntheticTls = ctx;
      proxies.add(proxy);
    }
    controlSocks = await Socks5Fixture.bind();

    log('https destinations ${List.generate(paneCount, syntheticOrigin).join(",")}, '
        'connect proxies ${proxies.map((p) => p.port).join(",")}, '
        'proxySupported=${PlatformInfo.isProxySupported} '
        'containers=$containers');
  });

  tearDownAll(() async {
    if (!applies) return;
    for (var f = 0; f < proxies.length; f++) {
      log('proxy$f connects=${proxies[f].targets}');
    }
    log('socks-control connects=${controlSocks.targets}');
    log('verdict: containers=$containers, first-frame-socks-control=$control, '
        '${verdict.join(", ")}');
    await controlSocks.close();
    for (final p in proxies) {
      await p.close();
    }
  });

  bool usable() {
    if (!applies) {
      markTestSkipped('the per-WebView proxy is an Apple path');
      return false;
    }
    expect(PlatformInfo.isProxySupported, isTrue,
        reason: 'proxy support reads unavailable on an Apple tier past the '
            'floor; PlatformInfo.initialize() was most likely not awaited');
    return true;
  }

  int? proxyThatSaw(String target) {
    for (var f = 0; f < proxies.length; f++) {
      if (proxies[f].targets.any((t) => t.startsWith('$target:'))) return f;
    }
    return null;
  }

  testWidgets('three stores, three CONNECT proxies, https origins',
      (tester) async {
    if (!usable()) return;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          for (var i = 0; i < paneCount; i++)
            SizedBox(
              width: 200,
              height: 90,
              child: inapp.InAppWebView(
                key: ValueKey('connecths$i'),
                initialUrlRequest: inapp.URLRequest(
                  url: inapp.WebUri('https://${syntheticOrigin(i)}/c$i'),
                ),
                initialSettings: inapp.InAppWebViewSettings(
                  containerId: 'ws-proxy-connect-https-$i',
                  proxySettings: inapp.ProxySettings(
                    proxyRules: [
                      inapp.ProxyRule(
                        url: 'http://127.0.0.1:${proxies[i].port}',
                      ),
                    ],
                    bypassRules: [],
                  ),
                ),
                // The origin certificate is self-signed and minted for this
                // run, so the only way a load reaches it is to accept it
                // here. Scoped to this file; nothing else trusts it.
                onReceivedServerTrustAuthRequest: (controller, challenge) async =>
                    inapp.ServerTrustAuthResponse(
                  action: inapp.ServerTrustAuthResponseAction.PROCEED,
                ),
              ),
            ),
          SizedBox(
            width: 200,
            height: 90,
            child: inapp.InAppWebView(
              key: const ValueKey('socks-control'),
              initialUrlRequest: inapp.URLRequest(
                url: inapp.WebUri('http://${syntheticOrigin(paneCount)}/ctl'),
              ),
              initialSettings: inapp.InAppWebViewSettings(
                containerId: 'ws-proxy-connect-https-control',
                proxySettings: inapp.ProxySettings(
                  proxyRules: [
                    inapp.ProxyRule(
                      url: 'socks5://127.0.0.1:${controlSocks.port}',
                    ),
                  ],
                  bypassRules: [],
                ),
              ),
            ),
          ),
        ]),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));

    bool settled(int i) => proxyThatSaw(syntheticOrigin(i)) != null;

    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (DateTime.now().isBefore(deadline)) {
        if (List.generate(paneCount, settled).every((s) => s)) break;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    });

    final results = <String>[];
    for (var i = 0; i < paneCount; i++) {
      final saw = proxyThatSaw(syntheticOrigin(i));
      results.add('c$i->${saw == i ? 'own(proxy$saw)' : saw != null ? 'CROSSED(proxy$saw)' : 'DIRECT-or-failed'}');
    }
    verdict.add('connect-https=[${results.join(" ")}]');
    final own = results.where((r) => r.contains('own(')).length;
    log('$own of $paneCount panes used their own CONNECT proxy');

    control = controlSocks.targets
            .any((t) => t.startsWith('${syntheticOrigin(paneCount)}:'))
        ? 'proxied'
        : 'DIRECT-or-failed';
    log('first-frame socks control -> $control');
    expect(
      control,
      'proxied',
      reason: 'the SOCKS pane in this same first frame went $control, so this '
          'process proxied nothing and the CONNECT result below says nothing '
          'about CONNECT',
    );
    expect(
      own,
      paneCount,
      reason: 'three stores in the first frame, three distinct CONNECT '
          'proxies, https origins -- the arrangement WebKit tests upstream. '
          'Got [${results.join(" ")}]. Compare with proxy_http_connect, '
          'whose only difference is an http origin: if that one is all '
          'DIRECT with empty proxies and this one is not, the destination '
          'scheme is what decides whether a CONNECT proxy is used at all',
    );
  });
}
