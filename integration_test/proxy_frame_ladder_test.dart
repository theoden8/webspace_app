// How far past the first frame does a per-site proxy survive? (BUG-014, LEAK-003)
//
// Attempts 90, 91, 92, 94 and 96 all say the same thing: a navigation issued
// in the app process's first frame is proxied and one issued later is not,
// whatever store or WebView it belongs to. `proxy_timing_test.dart` brackets
// that from above -- a store built after the baseline has settled (seconds)
// and one built after a further six second idle both go direct. Nothing has
// ever measured the other side of the boundary.
//
// That gap decides which kind of bug this is, and the two answers want
// different fixes:
//
//  * If a store mounted one frame later, or fifty milliseconds later, still
//    proxies and the boundary only bites at hundreds of milliseconds, this
//    is a RACE -- most plausibly against the network process launch that
//    `WebsiteDataStore::setProxyConfigData` triggers inside the window where
//    it has nulled `m_proxyConfigData`. A race is fixable from the fork:
//    wait for the process, then assign.
//  * If every rung past frame 1 goes direct, including the one sixteen
//    milliseconds later, no amount of waiting helps and what is left is
//    instrumentation inside WebKit.
//
// So every rung mounts its own store, with its own upstream fixture and its
// own origin, at a measured distance from frame 1, and NOTHING waits for an
// earlier rung to settle first -- waiting is what would collapse the ladder
// back onto `proxy_timing`'s coarse end. The control is that SOME rung
// proxied: a process that could not proxy at all produces the same nulls as
// a platform that drops the proxy, and only a rung reaching its own upstream
// separates them. Which rung that is, is the measurement.
//
// Read per request, off the peer port the origin saw against the ports each
// fixture dialled upstream from, so a request served over a kept-alive
// connection still counts for the proxy that carries it (attempt 87).
//
// Gap -2 applies here as everywhere: without a slot this file measures a
// dead process and says so through rung 0.
//
// ONE CAVEAT ON READING THE RUNGS. "Frame 1" here is the first frame of the
// TEST, not of the process. The app has already run its startup by then --
// the tier's own logs put `main() pre-runApp init` at roughly 800ms and the
// first setState a few hundred milliseconds after that -- so rung 0 is
// already a second or two into the process's life. If the boundary were a
// race against a network process launched during that startup, every rung
// here would sit on the far side of it and they would all read DIRECT,
// including rung 0. Rung 0 reading `own` is therefore evidence that the
// boundary is NOT simply "the first milliseconds of the process", and the
// rungs measure distance from the first WebView, not from launch.
//
// A ladder that starts before app startup would need a different harness
// than integration_test; the absolute UTC stamps on every line here are
// what allow these rungs to be aligned against the startup log and the
// network process's own os_log after the fact.

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

/// One rung: how long after frame 1 its store is mounted and navigated.
/// `null` means "in frame 1 itself", which is the control.
class _Rung {
  const _Rung(this.name, this.delay);
  final String name;
  final Duration? delay;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final applies = hostIsIOS || hostIsMacOS;
  final runLabel = Platform.environment['WEBSPACE_LADDER_RUN'] ?? '1';

  // The near rungs bracket a launch race. The far ones exist because of
  // `proxy_binding`'s staircase in run 35668961271, which is the reading this
  // ladder was nearly built blind to:
  //
  //   stair=[0ms:DIRECT 3158ms:DIRECT 6224ms:DIRECT 9287ms:proxied 9550ms:proxied]
  //
  // One WebView, one store, five navigations. The 3.1s gaps are that arm's
  // settle timeouts, so the first three timed out DIRECT and the last two
  // proxied 263ms apart: proxy capability ARRIVED about 9.3 seconds into that
  // process, and its frame-1 pair had none (`pair=0 of 2 proxied`). A ladder
  // that stopped at 2s would have read DIRECT on every rung, reported "no
  // slot", and missed the thing it was sitting on.
  //
  // So the far rungs straddle 9.3s. If a store created at 10s proxies where
  // one created at frame 1 did not, the question stops being "when does the
  // proxy stop applying" and becomes "what has to happen before it starts".
  const rungs = <_Rung>[
    _Rung('frame1', null),
    _Rung('next-frame', Duration.zero),
    _Rung('50ms', Duration(milliseconds: 50)),
    _Rung('150ms', Duration(milliseconds: 150)),
    _Rung('500ms', Duration(milliseconds: 500)),
    _Rung('2s', Duration(seconds: 2)),
    _Rung('5s', Duration(seconds: 5)),
    _Rung('10s', Duration(seconds: 10)),
    _Rung('15s', Duration(seconds: 15)),
  ];

  void log(String m) {
    // UTC and to the millisecond: the tier streams the network process's own
    // os_log alongside this, and a rung is only interpretable against when
    // that process started.
    // ignore: avoid_print
    print('[proxy-ladder] ${DateTime.now().toUtc().toIso8601String()} $m');
  }

  final origins = <HttpServer>[];
  final ports = <int>[];
  final socks = <Socks5Fixture>[];
  final requests = <({String origin, int port})>[];
  final verdict = <String, String>{};
  InternetAddress? routable;
  var originHost = '127.0.0.1';
  var containers = false;

  setUpAll(() async {
    if (!applies) return;
    await PlatformInfo.initialize();
    containers = await ContainerNative.instance.isSupported();
    routable = await nonLoopbackIPv4();
    originHost = routable?.address ?? '127.0.0.1';
    for (var i = 0; i < rungs.length; i++) {
      final origin = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      origins.add(origin);
      ports.add(origin.port);
      listenFixture(origin, (req) async {
        requests.add((
          origin: 'o$i',
          port: req.connectionInfo?.remotePort ?? -1,
        ));
        final res = req.response..headers.contentType = ContentType.html;
        res.write('<!doctype html><html><body><p>o$i</p></body></html>');
        await res.close();
      });
      socks.add(await Socks5Fixture.bind());
    }
    log('run=$runLabel host=$originHost origins=${ports.join(",")} '
        'socks=${socks.map((s) => s.port).join(",")} '
        'proxySupported=${PlatformInfo.isProxySupported} containers=$containers');
  });

  tearDownAll(() async {
    if (!applies) return;
    for (var i = 0; i < socks.length; i++) {
      log('socks$i(${rungs[i].name}) connects=${socks[i].targets} '
          'relayed=${socks[i].relayedPorts.toList()..sort()}');
    }
    log('origin arrivals=${requests.map((r) => "${r.origin}@${r.port}").toList()}');
    log('run=$runLabel verdict: containers=$containers '
        '${rungs.map((r) => "${r.name}=${verdict[r.name] ?? "unrun"}").join(" ")}');
    for (final s in socks) {
      await s.close();
    }
    for (final o in origins) {
      await o.close(force: true);
    }
  });

  String urlFor(int i) => 'http://$originHost:${ports[i]}/o$i';

  bool settled(int i) {
    final target = '$originHost:${ports[i]}';
    return socks.any((s) => s.targets.contains(target)) ||
        requests.any((r) => r.origin == 'o$i');
  }

  int? relayOf(int remotePort) {
    for (var s = 0; s < socks.length; s++) {
      if (socks[s].relayedPorts.contains(remotePort)) return s;
    }
    return null;
  }

  /// Did rung [i] reach its origin through its own fixture? Read off the last
  /// request that origin saw and attributed by peer port, so a crossed
  /// circuit is named rather than counted as a pass.
  String classify(int i) {
    final hits = requests.where((r) => r.origin == 'o$i').toList();
    if (hits.isEmpty) {
      return socks.any((s) => s.targets.contains('$originHost:${ports[i]}'))
          ? 'asked-not-delivered'
          : 'no-load';
    }
    final via = relayOf(hits.last.port);
    if (via == null) return 'DIRECT';
    return via == i ? 'own' : 'CROSSED(socks$via)';
  }

  Widget pane(int i) => SizedBox(
        width: 120,
        height: 40,
        child: inapp.InAppWebView(
          key: ValueKey('ladder-$i'),
          initialUrlRequest:
              inapp.URLRequest(url: inapp.WebUri(urlFor(i))),
          initialSettings: inapp.InAppWebViewSettings(
            containerId: 'ws-ladder-$runLabel-$i',
            proxySettings: inapp.ProxySettings(
              proxyRules: [
                // Failover off, as everywhere in this investigation: with it
                // on, a proxy that cannot serve a request produces a silent
                // direct load, which is indistinguishable from a proxy that
                // was never installed.
                inapp.ProxyRule(
                  url: 'socks5://127.0.0.1:${socks[i].port}',
                  allowFailover: false,
                )
              ],
              bypassRules: [],
            ),
          ),
        ),
      );

  Future<void> waitReal(WidgetTester tester, bool Function() done,
      {required String label,
      Duration timeout = const Duration(seconds: 30)}) async {
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

  testWidgets('how far past frame 1 a per-site proxy survives',
      (tester) async {
    if (!applies) {
      markTestSkipped('the per-WebView proxy is an Apple path');
      return;
    }
    expect(routable, isNotNull,
        reason: 'no non-loopback IPv4 here, and Apple never proxies a '
            'loopback destination, so no rung could be distinguished');
    expect(PlatformInfo.isProxySupported, isTrue,
        reason: 'proxy support reads unavailable past the floor; '
            'PlatformInfo.initialize() was most likely not awaited');

    // Mounted cumulatively, so a rung already up is never torn down under
    // the next one. Nothing here waits for a load: the whole point is the
    // distance from frame 1 at which each store is created and navigated.
    final mounted = <int>[];
    Widget tree() => MaterialApp(
          home: Scaffold(
            body: Column(
              mainAxisSize: MainAxisSize.min,
              children: [for (final i in mounted) pane(i)],
            ),
          ),
        );

    mounted.add(0);
    await tester.pumpWidget(tree());
    log('rung frame1 mounted');

    for (var i = 1; i < rungs.length; i++) {
      final delay = rungs[i].delay!;
      if (delay == Duration.zero) {
        await tester.pump();
      } else {
        // Real time, not fake: the boundary being measured is wall-clock
        // distance from process start, and pump()'s clock is not.
        await tester.runAsync(() => Future<void>.delayed(delay));
        await tester.pump();
      }
      mounted.add(i);
      await tester.pumpWidget(tree());
      log('rung ${rungs[i].name} mounted');
    }

    for (var i = 0; i < rungs.length; i++) {
      await waitReal(tester, () => settled(i), label: 'rung ${rungs[i].name}');
      verdict[rungs[i].name] = classify(i);
      log('${rungs[i].name}=${verdict[rungs[i].name]}');
    }

    // The control is "some rung proxied", NOT "frame 1 proxied". Late
    // acquisition is a result here, not a void run: proxy_binding's staircase
    // has one process go DIRECT for nine seconds and then proxy, so asserting
    // on frame1 would fail the arm in exactly the case it was extended to
    // catch. What is genuinely void is a process where no rung ever reached
    // its own upstream, which is indistinguishable from a platform that drops
    // the proxy outright.
    final anyProxied = verdict.values.any((v) => v == 'own');
    log('frame1-proxied=${verdict["frame1"] == "own"} any-proxied=$anyProxied');
    expect(anyProxied, isTrue,
        reason: 'no rung reached its own upstream, so this process never had '
            'the proxy at all and nothing here is evidence about the boundary');
  });
}
