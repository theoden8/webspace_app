// Does a per-site proxy survive past the frame that mounted its store?
//
// Nine stores, each with its own SOCKS5 upstream and its own destination,
// mounted at measured distances from frame 1, none waiting for an earlier one
// to settle. BUG-014 attempt 102 reads all nine `own`: there is no frame
// boundary. The arm stays as the regression test for that.
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

  final socks = <Socks5Fixture>[];
  final verdict = <String, String>{};
  var containers = false;

  setUpAll(() async {
    if (!applies) return;
    await PlatformInfo.initialize();
    containers = await ContainerNative.instance.isSupported();
    for (var i = 0; i < rungs.length; i++) {
      socks.add(await Socks5Fixture.bind());
    }
    log('run=$runLabel origins=${[
      for (var i = 0; i < rungs.length; i++) syntheticOrigin(i)
    ].join(",")} '
        'socks=${socks.map((s) => s.port).join(",")} '
        'proxySupported=${PlatformInfo.isProxySupported} containers=$containers');
  });

  tearDownAll(() async {
    if (!applies) return;
    for (var i = 0; i < socks.length; i++) {
      log('socks$i(${rungs[i].name}) connects=${socks[i].targets} '
          'served=${socks[i].servedSynthetic}');
    }
    log('run=$runLabel verdict: containers=$containers '
        '${rungs.map((r) => "${r.name}=${verdict[r.name] ?? "unrun"}").join(" ")}');
    for (final s in socks) {
      await s.close();
    }
  });

  String urlFor(int i) => 'http://${syntheticOrigin(i)}/o$i';

  bool settled(int i) => socks.any((s) => s.targets.any(
      (t) => t.startsWith('${syntheticOrigin(i)}:')));

  /// Did rung [i] reach its destination through its own fixture?
  ///
  /// [syntheticOrigin] has no route off this machine, so a request that
  /// arrives at ANY fixture arrived through a proxy; which fixture saw it
  /// names the circuit, and no fixture seeing it means the load went direct
  /// and could not have succeeded.
  String classify(int i) {
    final want = '${syntheticOrigin(i)}:';
    for (var s = 0; s < socks.length; s++) {
      if (socks[s].targets.any((t) => t.startsWith(want))) {
        return s == i ? 'own' : 'CROSSED(socks$s)';
      }
    }
    return 'DIRECT';
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
