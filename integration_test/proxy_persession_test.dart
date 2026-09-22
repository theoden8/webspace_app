// Three `URLSession`s in one process: the first two share a single
// `ProxyConfiguration` instance, the third mints its own for the same
// endpoint. Separates "the config object is single-use" from "one proxied
// session per process".
//
// Destinations are `syntheticOrigin()` addresses. An address this machine owns
// is routed over `lo0` and Apple never proxies a loopback-routed destination,
// so an origin bound here reads DIRECT whether or not the proxy was bound --
// the defect that voided BUG-014's first 101 attempts. Nothing routes to a
// synthetic destination, so the fixture answers it and an arrival there is the
// proof.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/webview.dart';
import 'socks5_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('webspace/proxy_probe');
  final applies = hostIsMacOS;

  // Destinations, not origins on this machine. macOS routes traffic aimed at
  // any address the host owns over `lo0`, and Apple never proxies a
  // loopback-routed destination, so an origin bound here reads DIRECT
  // whether or not the proxy was bound -- the defect that voided ninety-odd
  // BUG-014 attempts (attempt 102). Nothing routes to a `syntheticOrigin`,
  // so the fixture answers it itself and an arrival there IS the proof.
  const dest = 0;
  late Socks5Fixture socks;

  void log(String m) {
    // ignore: avoid_print
    print('[proxy-persession] $m');
  }

  setUpAll(() async {
    if (!applies) return;
    await PlatformInfo.initialize();
    socks = await Socks5Fixture.bind();
    log('destination ${syntheticOrigin(dest)} socks ${socks.port}');
  });

  tearDownAll(() async {
    if (!applies) return;
    await socks.close();
  });

  testWidgets('three URLSessions, one shared proxy object and one fresh',
      (tester) async {
    if (!applies) {
      markTestSkipped('the probe plugin is macOS only');
      return;
    }

    Map<Object?, Object?>? reply;
    await tester.runAsync(() async {
      reply = await channel.invokeMethod<Map<Object?, Object?>>(
        'urlSessionPerSession',
        {
          'socksHost': '127.0.0.1',
          'socksPort': socks.port,
          'url': 'http://${syntheticOrigin(dest)}/p',
        },
      );
    });

    expect(reply, isNotNull, reason: 'the probe plugin did not answer');
    expect(reply!['ok'], isTrue,
        reason: 'the probe refused: ${reply!['detail']}');

    final labels = (reply!['labels'] as List?)?.cast<Object?>() ?? const [];
    final outcomes = (reply!['outcomes'] as List?) ?? const [];
    // The loads are sequential and each session makes exactly one, so the
    // origin's arrivals line up with the labels in order. A session whose
    // load never arrived leaves a hole, which is itself a reading.
    // Nothing routes to a synthetic destination, so an arrival at the
    // fixture is a proxied load and a bypassed one arrives nowhere.
    final arrivals = socks.syntheticPaths;
    final seen = <String>[
      for (var i = 0; i < arrivals.length; i++)
        '${i < labels.length ? labels[i] : "extra$i"}:proxied',
    ];
    final proxied = seen.length;

    log('relayed ports ${socks.relayedPorts.toList()..sort()}, '
        'CONNECTs ${socks.targets}');

    expect(outcomes.length, 3,
        reason: 'all three loads must settle for the comparison to mean '
            'anything, got $outcomes');
    expect(proxied, greaterThan(0),
        reason: 'no session reached the fixture, so this process could not '
            'proxy at all and the split below says nothing: $seen');

    log('VERDICT urlsession-persession proxied=$proxied '
        'arrivals=$seen outcomes=$outcomes');
  });
}
