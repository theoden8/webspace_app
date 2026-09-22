// Three containers over three distinct HTTP CONNECT proxies, plain-http
// destinations, plus a later-frame SOCKS control in the same process.
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
import 'package:webspace/services/webview.dart';
import 'http_connect_fixture.dart';
import 'socks5_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final applies = hostIsIOS || hostIsMacOS;

  void log(String m) {
    // ignore: avoid_print
    print('[proxy-http-connect] $m');
  }

  const paneCount = 3;

  final proxies = <HttpConnectFixture>[];
  // Destinations, not origins on this machine: macOS routes an address the
  // host owns over `lo0` and Apple never proxies a loopback-routed
  // destination, so an origin bound here reads DIRECT whether or not the
  // proxy was bound (BUG-014 caution 1). Nothing routes to a
  // `syntheticOrigin`, so the fixture answers it and an arrival IS the proof.
  var containers = false;

  final trace =
      File('${Directory.systemTemp.path}/webspace-container-store.log');
  final verdict = <String>[];

  setUpAll(() async {
    if (trace.existsSync()) trace.deleteSync();
    // Without this `isProxySupported` is false and every scenario
    // below skips, which is how the first run of these files
    // reported green having measured nothing. Ordered before the container
    // query the way proxy_binding orders it, which is the only arm that
    // binds a proxy.
    await PlatformInfo.initialize();
    if (applies) {
      containers = await ContainerNative.instance.isSupported();
    }

    for (var i = 0; i < paneCount; i++) {
      proxies.add(await HttpConnectFixture.bind());
    }
    log('destinations ${List.generate(paneCount, syntheticOrigin).join(",")}, '
        'http proxies ${proxies.map((p) => p.port).join(",")}, '
        'proxySupported=${PlatformInfo.isProxySupported} '
        'containers=$containers');
  });

  tearDownAll(() async {
    for (var f = 0; f < proxies.length; f++) {
      log('proxy$f connects=${proxies[f].targets}');
    }
    log('verdict: containers=$containers, ${verdict.join(", ")}');
    if (trace.existsSync()) {
      for (final line in trace.readAsLinesSync()) {
        log('native: $line');
      }
      trace.deleteSync();
    } else {
      log('native: no container-store trace was written');
    }
    for (final p in proxies) {
      await p.close();
    }
  });

  bool usable() {
    if (!applies) {
      markTestSkipped('per-WebView proxy binding is an Apple path');
      return false;
    }
    // Not a skip. Every Apple tier this runs on is past the
    // proxyConfigurations floor, so a false here means PlatformInfo was
    // never initialized rather than an old OS -- and skipping on it is
    // indistinguishable, in the tier's output, from a file that ran.
    expect(
      PlatformInfo.isProxySupported,
      isTrue,
      reason: 'proxy support reads as unavailable on an Apple tier that is '
          'past the iOS 17 / macOS 14 floor; PlatformInfo.initialize() was '
          'most likely not awaited in setUpAll',
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

  int? proxyThatSaw(String target) {
    for (var f = 0; f < proxies.length; f++) {
      if (proxies[f].targets.any((t) => t.startsWith('$target:'))) return f;
    }
    return null;
  }

  testWidgets('the first frame: three stores, three HTTP CONNECT proxies',
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
                key: ValueKey('httpc$i'),
                initialUrlRequest: inapp.URLRequest(
                  url: inapp.WebUri('http://${syntheticOrigin(i)}/h$i'),
                ),
                initialSettings: inapp.InAppWebViewSettings(
                  containerId: 'ws-proxy-httpc-$i',
                  proxySettings: inapp.ProxySettings(
                    proxyRules: [
                      inapp.ProxyRule(
                        url: 'http://127.0.0.1:${proxies[i].port}',
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

    bool settled(int i) =>
        proxyThatSaw(syntheticOrigin(i)) != null;

    await waitReal(
      tester,
      () => List.generate(paneCount, settled).every((s) => s),
      label: 'every HTTP CONNECT pane settled',
    );

    final results = <String>[];
    for (var i = 0; i < paneCount; i++) {
      final saw = proxyThatSaw(syntheticOrigin(i));
      // Nothing routes to a synthetic destination, so a pane that reached no
      // proxy went direct and could not have loaded.
      results.add('h$i->${saw == i ? 'own(proxy$saw)' : saw != null ? 'CROSSED(proxy$saw)' : 'DIRECT-or-failed'}');
    }
    verdict.add('http-connect=[${results.join(" ")}]');

    final own = results.where((r) => r.contains('own(')).length;
    log('$own of $paneCount HTTP CONNECT panes used their own proxy');

    expect(
      own,
      paneCount,
      reason: 'three stores in the first frame, three distinct HTTP CONNECT '
          'proxies: every pane must reach its origin through its own. Got '
          '[${results.join(" ")}]. If SOCKS5 fails the same shape and this '
          'passes, the live nw_context patch is the mechanism and an HTTP '
          'proxy is the delivery that works',
    );
  });

  testWidgets('a SOCKS5 pane in a later frame, for the contrast',
      (tester) async {
    if (!usable()) return;
    // Deliberately one pane and one proxy: this is not a simultaneity
    // question, it is the control that says whether this process reaches a
    // proxy at all outside its first frame, so a null result above can be
    // told apart from a process that had stopped proxying anything.
    final socks = await Socks5Fixture.bind();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 200,
          height: 90,
          child: inapp.InAppWebView(
            key: const ValueKey('httpc-control'),
            initialUrlRequest: inapp.URLRequest(
              url: inapp.WebUri('http://${syntheticOrigin(paneCount)}/ctl'),
            ),
            initialSettings: inapp.InAppWebViewSettings(
              containerId: 'ws-proxy-httpc-control',
              proxySettings: inapp.ProxySettings(
                proxyRules: [
                  inapp.ProxyRule(url: 'socks5://127.0.0.1:${socks.port}'),
                ],
                bypassRules: [],
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));

    final target = '${syntheticOrigin(paneCount)}:';
    await waitReal(
      tester,
      () => socks.targets.any((t) => t.startsWith(target)),
      label: 'later-frame SOCKS control settled',
    );
    verdict.add('later-socks-control='
        '${socks.targets.any((t) => t.startsWith(target)) ? "proxied" : "DIRECT-or-failed"}');

    await socks.close();
  });
}
