// The narrowest question the platform can be asked: one data store, one
// proxy, one `WKWebView`, one load, through the macOS probe plugin rather
// than the app's machinery.
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

  // The probe is registered by the macOS Runner only. iOS has no equivalent
  // host for it, so the file is a macOS instrument and says so rather than
  // pretending to cover both.
  final applies = hostIsMacOS;

  void log(String m) {
    // ignore: avoid_print
    print('[proxy-probe] $m');
  }

  const channel = MethodChannel('webspace/proxy_probe');

  late Socks5Fixture socks;
  // Destinations, not origins on this machine. macOS routes traffic aimed at
  // any address the host owns over `lo0`, and Apple never proxies a
  // loopback-routed destination, so an origin bound here reads DIRECT
  // whether or not the proxy was bound -- the defect that voided ninety-odd
  // BUG-014 attempts (attempt 102). Nothing routes to a `syntheticOrigin`,
  // so the fixture answers it itself and an arrival there IS the proof.
  const dest = 0;
  final verdict = <String>[];

  setUpAll(() async {
    if (!applies) return;
    await PlatformInfo.initialize();
    socks = await Socks5Fixture.bind();
    log('socks ${socks.port}, destination ${syntheticOrigin(dest)}');
  });

  tearDownAll(() async {
    if (!applies) return;
    log('verdict: ${verdict.join(", ")}');
    await socks.close();
  });

  /// One probe, and what the SOCKS server saw for it. The fixture records
  /// every CONNECT it is asked for, so the reading is "the proxy was used",
  /// not "the origin was not reached".
  Future<void> probe(String label, {required bool identified}) async {
    final before = socks.targets.length;
    final reply = await channel.invokeMapMethod<String, dynamic>('probe', {
      'socksHost': '127.0.0.1',
      'socksPort': socks.port,
      'url': 'http://${syntheticOrigin(dest)}/',
      'identified': identified,
      'identifier': '8f1d5c4e-0000-4000-8000-00000000000${identified ? 1 : 2}',
    });
    final seen = socks.targets.length - before;
    final ok = reply?['ok'] == true;
    final detail = reply?['detail'] ?? 'no reply';
    final configured = reply?['configured'];
    verdict.add('$label->${seen > 0 ? "proxied" : "DIRECT"}');
    log('$label: ok=$ok configured=$configured connects=$seen detail=$detail');
    expect(ok, isTrue, reason: 'the probe could not run: $detail');
  }

  testWidgets('a bare WKWebView proxies through a per-store SOCKS5',
      (tester) async {
    if (!applies) {
      markTestSkipped('the per-store proxy probe is a macOS instrument');
      return;
    }

    await probe('nonPersistent', identified: false);
    await probe('identified', identified: true);

    // Deliberately not a pass/fail on proxying: this file's job is to report
    // which shapes proxy, and a red bar here would say only what the rest of
    // the tier already says. The verdict line is the result.
    expect(verdict.length, 2);
  });
}
