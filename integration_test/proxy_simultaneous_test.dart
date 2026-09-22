// Four containers over three distinct SOCKS5 upstreams in one frame, then two
// more in a later frame. Every pane must reach its own upstream: a pane that
// went direct leaked the device IP, and one that CROSSED sent its traffic
// through another site's proxy, which is worse.
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
import 'socks5_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final applies = hostIsLinux;

  void log(String m) {
    // ignore: avoid_print
    print('[proxy-simultaneous] $m');
  }

  /// Panes in the first frame, and which fixture each one's proxy points at.
  /// Panes 0 and 1 share a fixture so "two containers, one proxy" is covered
  /// in the same run.
  const fixtureOf = <int>[0, 0, 1, 2];
  const paneCount = 4;
  const fixtureCount = 3;

  /// The later-frame repeat uses its own panes, containers and origins, so
  /// it cannot be confused with the first-frame ones in any log.
  const lateFixtureOf = <int>[0, 1];

  final socks = <Socks5Fixture>[];
  // Destinations, not origins on this machine: macOS routes an address the
  // host owns over `lo0` and Apple never proxies a loopback-routed
  // destination, so an origin bound here reads DIRECT whether or not the
  // proxy was bound (BUG-014 attempt 102). Nothing routes to a
  // `syntheticOrigin`, so the fixture answers it and an arrival IS the proof.
  // The later-frame panes take the block after the first-frame ones.
  String destFor(int i) => syntheticOrigin(i);
  String lateDestFor(int i) => syntheticOrigin(paneCount + i);
  var containers = false;

  final trace =
      File('${Directory.systemTemp.path}/webspace-container-store.log');
  final verdict = <String>[];

  setUpAll(() async {
    // One file per app process into the same path, so a stale trace would
    // otherwise open with webviews this file never built.
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
    for (var i = 0; i < fixtureCount; i++) {
      socks.add(await Socks5Fixture.bind());
    }
    log('destinations ${List.generate(paneCount, destFor).join(",")} '
        'late ${List.generate(lateFixtureOf.length, lateDestFor).join(",")}, '
        'socks ${socks.map((s) => s.port).join(",")}, '
        'proxySupported=${PlatformInfo.isProxySupported} '
        'containers=$containers');
  });

  tearDownAll(() async {
    for (var f = 0; f < socks.length; f++) {
      log('socks$f connects=${socks[f].targets}');
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
    for (final s in socks) {
      await s.close();
    }
  });

  bool usable() {
    if (!applies) {
      markTestSkipped('per-container proxy binding is a WPE path');
      return false;
    }
    // Not a skip. Every WPE build the fork targets supports the per-site
    // proxy, so a false here means PlatformInfo was never initialized rather
    // than an old platform -- and skipping on it is indistinguishable, in
    // the tier's output, from a file that ran.
    expect(
      PlatformInfo.isProxySupported,
      isTrue,
      reason: 'proxy support reads as unavailable on WPE; '
          'PlatformInfo.initialize() was most likely not awaited in setUpAll',
    );
    return true;
  }

  /// Wall-clock wait: a live compositing platform view blocks `pump()`.
  Future<bool> waitReal(
    WidgetTester tester,
    bool Function() done, {
    required String label,
    Duration timeout = const Duration(seconds: 25),
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

  /// Which fixture, if any, was asked to reach [target]. Reported by index
  /// rather than as a boolean so a load arriving at a sibling's proxy is
  /// distinguishable from one that was never proxied.
  int? fixtureThatSaw(String dest) {
    for (var f = 0; f < socks.length; f++) {
      if (socks[f].targets.any((t) => t.startsWith('$dest:'))) return f;
    }
    return null;
  }

  /// Nothing routes to a synthetic destination, so a pane that reached no
  /// fixture went direct and could not have loaded; the two are one reading.
  String classify({
    required String dest,
    required int expectedFixture,
  }) {
    final saw = fixtureThatSaw(dest);
    if (saw == expectedFixture) return 'own(socks$saw)';
    if (saw != null) return 'CROSSED(socks$saw)';
    return 'DIRECT-or-failed';
  }

  inapp.InAppWebViewSettings settingsFor(String container, int fixture) =>
      inapp.InAppWebViewSettings(
        containerId: container,
        proxySettings: inapp.ProxySettings(
          proxyRules: [
            inapp.ProxyRule(url: 'socks5://127.0.0.1:${socks[fixture].port}'),
          ],
          bypassRules: [],
        ),
      );

  testWidgets('the first frame: four containers, three separate proxies',
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
                key: ValueKey('simul$i'),
                initialUrlRequest: inapp.URLRequest(
                  url: inapp.WebUri('http://${destFor(i)}/p$i'),
                ),
                initialSettings:
                    settingsFor('ws-proxy-simul-$i', fixtureOf[i]),
              ),
            ),
        ]),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));

    bool settled(int i) => fixtureThatSaw(destFor(i)) != null;

    await waitReal(
      tester,
      () => List.generate(paneCount, settled).every((s) => s),
      label: 'every first-frame pane settled',
      timeout: const Duration(seconds: 30),
    );

    final results = <String>[];
    for (var i = 0; i < paneCount; i++) {
      results.add('p$i->${classify(
        dest: destFor(i),
        expectedFixture: fixtureOf[i],
      )}');
    }
    verdict.add('first-frame=[${results.join(" ")}]');

    final own = results.where((r) => r.contains('own(')).length;
    log('first frame: $own of $paneCount panes used their own proxy');

    // A pane that went direct here reached its origin from the device IP
    // while the Dart side believed it had a proxy; a pane that CROSSED sent
    // its traffic through a different site's proxy, which is worse than
    // either.
    expect(
      own,
      paneCount,
      reason: 'four containers in the first frame, three distinct proxies '
          'between them: every pane must reach its origin through its own '
          'proxy. Got [${results.join(" ")}]',
    );
  });

  testWidgets('a later frame: two containers, two separate proxies',
      (tester) async {
    if (!usable()) return;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          for (var i = 0; i < lateFixtureOf.length; i++)
            SizedBox(
              width: 200,
              height: 90,
              child: inapp.InAppWebView(
                key: ValueKey('simul-late$i'),
                initialUrlRequest: inapp.URLRequest(
                  url: inapp.WebUri('http://${lateDestFor(i)}/l$i'),
                ),
                initialSettings:
                    settingsFor('ws-proxy-simul-late-$i', lateFixtureOf[i]),
              ),
            ),
        ]),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));

    bool settled(int i) =>
        fixtureThatSaw(lateDestFor(i)) != null;

    await waitReal(
      tester,
      () => List.generate(lateFixtureOf.length, settled).every((s) => s),
      label: 'every later-frame pane settled',
      timeout: const Duration(seconds: 30),
    );

    final results = <String>[];
    for (var i = 0; i < lateFixtureOf.length; i++) {
      results.add('l$i->${classify(
        dest: lateDestFor(i),
        expectedFixture: lateFixtureOf[i],
      )}');
    }
    verdict.add('later-frame=[${results.join(" ")}]');

    final own = results.where((r) => r.contains('own(')).length;
    expect(
      own,
      lateFixtureOf.length,
      reason: 'two containers created after the first frame, two distinct '
          'proxies between them: each must reach its origin through its own '
          'proxy. Got [${results.join(" ")}]',
    );
  });
}
