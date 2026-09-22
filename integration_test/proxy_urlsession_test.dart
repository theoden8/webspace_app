// The same `ProxyConfiguration` handed to `URLSession` instead of
// `WKWebsiteDataStore`, loading one destination twice on one session. Reads
// whether a second load on a live session keeps the proxy, in a process where
// every step can be traced.
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
    print('[proxy-urlsession] $m');
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

  testWidgets('two sequential URLSession loads through one proxy config',
      (tester) async {
    if (!applies) {
      markTestSkipped('the probe plugin is macOS only');
      return;
    }

    final target = '${syntheticOrigin(dest)}:80';
    Map<Object?, Object?>? reply;
    await tester.runAsync(() async {
      reply = await channel.invokeMethod<Map<Object?, Object?>>(
        'urlSessionSequential',
        {
          'socksHost': '127.0.0.1',
          'socksPort': socks.port,
          // Same URL twice on purpose: nothing about the request can differ
          // between the loads, so wrapper or domain routing cannot explain a
          // split.
          'urls': [
            'http://${syntheticOrigin(dest)}/a',
            'http://${syntheticOrigin(dest)}/a',
          ],
        },
      );
    });

    final connects = socks.targets.where((t) => t == target).length;
    // Nothing routes to a synthetic destination, so every arrival at the
    // fixture went through the proxy and a load that bypassed it arrives
    // nowhere at all.
    final seen = socks.syntheticPaths;
    final proxied = seen.length;
    log('reply=$reply');
    log('socks CONNECTs for $target = $connects, relayed ports '
        '${socks.relayedPorts.toList()..sort()}, fixture served $seen');

    expect(reply, isNotNull, reason: 'the probe plugin did not answer');
    expect(reply!['ok'], isTrue,
        reason: 'the probe refused: ${reply!['detail']}');

    // Reported, not asserted on the split: which way it goes is the finding.
    // What IS asserted is that the arm ran at all -- two loads settled and
    // the fixture was reachable -- so a silent no-op cannot read as evidence.
    final outcomes = (reply!['outcomes'] as List?) ?? const [];
    expect(outcomes.length, 2,
        reason: 'both loads must settle for the comparison to mean anything, '
            'got $outcomes');
    // Not asserted: a second load that FAILS rather than going direct leaves
    // the origin with one request, and that is a finding too (it is what
    // allowFailover:false turns a silent bypass into).
    expect(proxied, greaterThan(0),
        reason: 'no URLSession load reached the fixture, so this process '
            'could not proxy at all and the split below says nothing');

    log('VERDICT urlsession-sequential proxied=$proxied '
        'requests=$seen connects=$connects outcomes=$outcomes '
        'configuredAfter=${reply!['configuredAfter']}');
  });
}
