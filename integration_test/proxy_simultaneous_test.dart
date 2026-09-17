// Can two data stores carry two *different* proxies at the same time?
//
// Every reading on that question so far was taken in a later frame, where a
// single proxy does not bind either -- so it measured the frame and said
// nothing about simultaneity. `crossed=false` in particular: two webviews
// carrying different proxies both went direct, which is exactly what the
// frame alone produces, so it excluded nothing. The one arrangement that
// does bind -- a raw plugin webview built in the process's first frame with
// an `initialUrlRequest` -- has never been given a sibling carrying a
// different proxy.
//
// Four panes go up in that frame. Three carry three separate SOCKS
// fixtures; the fourth shares the first fixture, so "two stores, one proxy"
// (the arrangement `pair=2 of 2 proxied` already showed works) sits beside
// "two stores, two proxies" in the same run and the same frame.
//
// Every pane has its own origin, so a recorded CONNECT names the pane that
// issued it, and every fixture is checked for every pane's origin. A load
// arriving at a *sibling's* proxy is the signature of one process-wide
// proxy that the newest store overwrites -- `nw_context_add_proxy` clears
// the context's proxies before adding, and if that context is shared
// between stores the last one configured owns the process. One fixture
// cannot see that, which is why there are three.
//
// The verdict prints each fixture's raw CONNECT list rather than only a
// classification. Twice in this investigation the classifier was the thing
// that was wrong, not the platform.

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

  final applies = hostIsIOS || hostIsMacOS;

  void log(String m) {
    // ignore: avoid_print
    print('[proxy-simultaneous] $m');
  }

  /// Panes in the first frame, and which fixture each one's proxy points at.
  /// Pane 3 shares pane 0's fixture on purpose: it is the control that
  /// reproduces the known-good "two stores, one proxy" case beside the
  /// unknown "two stores, two proxies" one.
  const fixtureOf = <int>[0, 1, 2, 0];
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
      markTestSkipped('per-WebView proxy binding is an Apple path');
      return false;
    }
    expect(
      routable,
      isNotNull,
      reason: 'no non-loopback IPv4 on this machine, and Apple never sends a '
          'loopback destination through a proxy, so nothing here could '
          'distinguish a bound proxy from an unbound one',
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

  testWidgets('the first frame: four stores, three separate proxies',
      (tester) async {
    if (!usable()) return;
    if (!PlatformInfo.isProxySupported) {
      markTestSkipped('below the proxyConfigurations floor');
      return;
    }

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

    // Positive assertion, and the one the goal turns on. A pane that went
    // direct here leaked the device IP to its origin while the Dart side
    // believed it had a proxy; a pane that CROSSED sent its traffic through
    // a *different site's* proxy, which is worse than either.
    expect(
      own,
      paneCount,
      reason: 'four stores in the first frame, three distinct proxies '
          'between them: every pane must reach its origin through its own '
          'proxy. Got [${results.join(" ")}]',
    );
  });

  testWidgets('a later frame: two stores, two separate proxies',
      (tester) async {
    if (!usable()) return;
    if (!PlatformInfo.isProxySupported) {
      markTestSkipped('below the proxyConfigurations floor');
      return;
    }

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
    // Reported, not asserted: the later frame is the known-broken half and
    // failing it here would only mask the first-frame reading above, which
    // is the one the goal turns on.
    log('later frame: ${results.join(" ")}');
  });
}
