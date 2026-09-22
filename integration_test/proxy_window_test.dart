// Two containers with different proxies, mounted in the same frame after a
// warm-up load, each asserted to have reached its own upstream.
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
import 'package:webspace/services/webview.dart';
import 'socks5_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final applies = hostIsIOS || hostIsMacOS;

  // Destinations, not origins on this machine: macOS routes an address the
  // host owns over `lo0` and Apple never proxies a loopback-routed
  // destination, so an origin bound here reads DIRECT whether or not the
  // proxy was bound (BUG-014 caution 1). Nothing routes to a
  // `syntheticOrigin`, so the fixture answers it and an arrival IS the proof.
  const warmDest = 0;
  const destA = 1;
  const destB = 2;
  late Socks5Fixture socks;
  final verdict = <String>[];

  void log(String m) {
    // ignore: avoid_print
    print('[proxy-window] $m');
  }

  setUpAll(() async {
    await PlatformInfo.initialize();
    socks = await Socks5Fixture.bind();
    log('destinations ${syntheticOrigin(warmDest)}/${syntheticOrigin(destA)}/${syntheticOrigin(destB)}, socks on ${socks.port}, '
        'proxySupported=${PlatformInfo.isProxySupported}');
  });

  tearDownAll(() async {
    log('verdict: ${verdict.join(", ")}');
    await socks.close();
  });

  /// Wall-clock wait: a live compositing platform view blocks `pump()`.
  Future<bool> waitReal(
    WidgetTester tester,
    bool Function() done, {
    required String label,
    Duration timeout = const Duration(seconds: 20),
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

  bool usable() {
    if (!applies) {
      markTestSkipped('the proxy window is an Apple path');
      return false;
    }
    return true;
  }

  Widget pane(String containerId, String url, {int? proxyPort}) => SizedBox(
        width: 320,
        height: 160,
        child: inapp.InAppWebView(
          key: ValueKey(containerId),
          initialUrlRequest: inapp.URLRequest(url: inapp.WebUri(url)),
          initialSettings: inapp.InAppWebViewSettings(
            containerId: containerId,
            proxySettings: proxyPort == null
                ? null
                : inapp.ProxySettings(
                    proxyRules: [
                      inapp.ProxyRule(url: 'socks5://127.0.0.1:$proxyPort'),
                    ],
                    bypassRules: [],
                  ),
          ),
        ),
      );

  testWidgets('the first frame is spent bringing the network process up',
      (tester) async {
    // No proxy on this one. Its only job is to make WebKit's networking
    // exist before any proxied store is configured -- which is the one
    // thing every proxied reading in the sibling file has never had in
    // front of it.
    if (!usable()) return;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: pane('ws-proxy-window-warm', 'http://${syntheticOrigin(warmDest)}/w'),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));
    final warmed = await waitReal(tester, () => socks.syntheticPaths.any((t) => t.startsWith(syntheticOrigin(warmDest))),
        label: 'unproxied warm-up load');
    verdict.add('warm=${warmed ? "loaded" : "NEVER LOADED"}');
    expect(
      warmed,
      isTrue,
      reason: 'the warm-up load never reached its origin, so the network '
          'process may not have come up and the measurement below cannot '
          'mean anything',
    );
  });

  testWidgets('a proxied pair in the second frame', (tester) async {
    if (!usable()) return;
    if (!PlatformInfo.isProxySupported) {
      markTestSkipped('below the proxyConfigurations floor');
      return;
    }
    socks.targets.clear();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          pane('ws-proxy-window-a', 'http://${syntheticOrigin(destA)}/a',
              proxyPort: socks.port),
          pane('ws-proxy-window-b', 'http://${syntheticOrigin(destB)}/b',
              proxyPort: socks.port),
        ]),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));
    await waitReal(
        tester,
        () =>
            socks.targets.any((t) => t.startsWith('${syntheticOrigin(destA)}:')) &&
            socks.targets.any((t) => t.startsWith('${syntheticOrigin(destB)}:')),
        label: 'two proxied webviews after the network process exists',
        timeout: const Duration(seconds: 25));
    final proxied = [
      if (socks.targets.any((t) => t.startsWith('${syntheticOrigin(destA)}:'))) 'a',
      if (socks.targets.any((t) => t.startsWith('${syntheticOrigin(destB)}:'))) 'b',
    ];
    verdict.add('after-warmup=${proxied.length} of 2 proxied'
        '${proxied.isEmpty ? "" : " (${proxied.join("+")})"}, '
        'arrived=${[
      if (socks.syntheticPaths.contains('${syntheticOrigin(destA)}/a')) 'a',
      if (socks.syntheticPaths.contains('${syntheticOrigin(destB)}/b')) 'b',
    ].join("+")}');
    // Measurement, not assertion: both outcomes are the answer to a
    // different question, and neither is a defect of this file.
    //
    //   2 of 2 -> the window is the widget frame, and the network process
    //             is not what closes it.
    //   0 of 2 -> the window closes when WebKit's networking comes up, "the
    //             first frame" was a coincidence of where the first load
    //             happens, and arming every proxied store before anything
    //             touches the network is a repair rather than the no-op
    //             attempt 20 measured.
  });
}
