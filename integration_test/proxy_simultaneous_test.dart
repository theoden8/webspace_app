// Two sites, two different proxies, both loaded at once.
//
// WPE applies a proxy to a `WebKitNetworkSession` and every container owns
// one, so this is a property the platform can actually hold: each container
// keeps its own proxy no matter how many others are up. Before the fork
// pinned the proxy to the container's session, the plugin fanned a single
// process-wide override across every session, so the last site activated
// decided everyone's proxy and a site pinned to Tor could silently ride a
// neighbour's exit -- or the device IP.
//
// Four panes go up in the process's first frame. Three carry three separate
// SOCKS fixtures; the fourth shares the first fixture, so "two containers,
// one proxy" sits beside "two containers, two proxies" in the same run.
// The sharing pair is at the front on purpose: the first container built is
// pane 0 on fixture 0 and the last is pane 3 on fixture 2, so a single
// process-wide proxy reads as "everything landed on fixture 0" (first
// container kept it) or "everything landed on fixture 2" (last one took
// it), and the two are distinguishable. With the shared pane last, both
// would have named fixture 0.
//
// A second frame repeats it with two fresh panes, because a container
// created after the first frame takes a different code path into the
// session cache than one created with it.
//
// Every pane has its own origin, so a recorded CONNECT names the pane that
// issued it, and every fixture is checked for every pane's origin. A load
// arriving at a *sibling's* proxy is reported as CROSSED rather than folded
// into a pass/fail, because one site's traffic leaving through another
// site's proxy is a worse outcome than no proxy at all and should not read
// the same in a log.
//
// Apple is excluded: it binds to `WKWebsiteDataStore.proxyConfigurations`,
// which does not hold for more than one store in a process (BUG-014).
// Tracked separately; this file is the WPE contract.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/container_native.dart';
import 'package:webspace/services/webview.dart';
import 'fixture_server.dart';
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
  final origins = <HttpServer>[];
  final ports = <int>[];
  final lateOrigins = <HttpServer>[];
  final latePorts = <int>[];
  final requests = <String>[];
  InternetAddress? routable;
  var originHost = '127.0.0.1';
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
    routable = await nonLoopbackIPv4();
    originHost = routable?.address ?? '127.0.0.1';

    for (var i = 0; i < paneCount; i++) {
      final origin = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      origins.add(origin);
      ports.add(origin.port);
      listenFixture(origin, (req) async {
        requests.add('p$i:${req.uri.path}');
        final res = req.response..headers.contentType = ContentType.html;
        res.write('<!doctype html><html><body><p>p$i</p></body></html>');
        await res.close();
      });
    }
    for (var i = 0; i < lateFixtureOf.length; i++) {
      final origin = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      lateOrigins.add(origin);
      latePorts.add(origin.port);
      listenFixture(origin, (req) async {
        requests.add('l$i:${req.uri.path}');
        final res = req.response..headers.contentType = ContentType.html;
        res.write('<!doctype html><html><body><p>l$i</p></body></html>');
        await res.close();
      });
    }
    for (var i = 0; i < fixtureCount; i++) {
      socks.add(await Socks5Fixture.bind());
    }
    log('origins ${ports.join(",")} late ${latePorts.join(",")} '
        'on $originHost, socks ${socks.map((s) => s.port).join(",")}, '
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
    for (final o in origins) {
      await o.close(force: true);
    }
    for (final o in lateOrigins) {
      await o.close(force: true);
    }
  });

  bool usable() {
    if (!applies) {
      markTestSkipped('per-container proxy binding is a WPE path');
      return false;
    }
    expect(
      routable,
      isNotNull,
      reason: 'no non-loopback IPv4 on this machine, and a loopback '
          'destination is not sent through a proxy, so nothing here could '
          'distinguish a bound proxy from an unbound one',
    );
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
  int? fixtureThatSaw(String target) {
    for (var f = 0; f < socks.length; f++) {
      if (socks[f].targets.contains(target)) return f;
    }
    return null;
  }

  String classify({
    required String target,
    required int expectedFixture,
    required bool reachedOrigin,
  }) {
    final saw = fixtureThatSaw(target);
    if (saw == expectedFixture) return 'own(socks$saw)';
    if (saw != null) return 'CROSSED(socks$saw)';
    return reachedOrigin ? 'DIRECT' : 'no load';
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
                  url: inapp.WebUri('http://$originHost:${ports[i]}/p$i'),
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

    bool settled(int i) =>
        fixtureThatSaw('$originHost:${ports[i]}') != null ||
        requests.contains('p$i:/p$i');

    await waitReal(
      tester,
      () => List.generate(paneCount, settled).every((s) => s),
      label: 'every first-frame pane settled',
      timeout: const Duration(seconds: 30),
    );

    final results = <String>[];
    for (var i = 0; i < paneCount; i++) {
      results.add('p$i->${classify(
        target: '$originHost:${ports[i]}',
        expectedFixture: fixtureOf[i],
        reachedOrigin: requests.contains('p$i:/p$i'),
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
                  url: inapp.WebUri('http://$originHost:${latePorts[i]}/l$i'),
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
        fixtureThatSaw('$originHost:${latePorts[i]}') != null ||
        requests.contains('l$i:/l$i');

    await waitReal(
      tester,
      () => List.generate(lateFixtureOf.length, settled).every((s) => s),
      label: 'every later-frame pane settled',
      timeout: const Duration(seconds: 30),
    );

    final results = <String>[];
    for (var i = 0; i < lateFixtureOf.length; i++) {
      results.add('l$i->${classify(
        target: '$originHost:${latePorts[i]}',
        expectedFixture: lateFixtureOf[i],
        reachedOrigin: requests.contains('l$i:/l$i'),
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
