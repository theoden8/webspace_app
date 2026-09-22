// Is a per-site proxy used on EVERY load, or on a fraction of them? One fresh
// container and one fresh destination per round, so no round can ride
// another's connection. A partial rate fails: a proxy used four times in
// eight is not a proxy, and reporting it as one is the leak.
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
import 'package:webspace/services/container_native.dart';
import 'package:webspace/services/webview.dart';
import 'socks5_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final applies = hostIsIOS || hostIsMacOS;

  void log(String m) {
    // ignore: avoid_print
    print('[proxy-rate] $m');
  }

  /// Enough draws to tell "never" from "sometimes" without spending the
  /// tier's budget: at a true rate of one in three, eight rounds miss every
  /// time with probability under 4%.
  const rounds = 8;

  late Socks5Fixture socks;
  String control = 'not run';
  // Destinations, not origins on this machine: macOS routes an address the
  // host owns over `lo0` and Apple never proxies a loopback-routed
  // destination, so an origin bound here reads DIRECT whether or not the
  // proxy was bound (BUG-014 caution 1). Nothing routes to a
  // `syntheticOrigin`, so the fixture answers it and an arrival IS the proof.
  var containers = false;
  final outcomes = <String>[];

  setUpAll(() async {
    // Ordered the way proxy_binding orders it, which is the only arm that
    // binds a proxy. Whether that matters is unmeasured; removing the
    // difference costs nothing and leaves one fewer variable.
    await PlatformInfo.initialize();
    if (applies) {
      containers = await ContainerNative.instance.isSupported();
    }
    socks = await Socks5Fixture.bind();
    log('destinations ${syntheticOrigin(0)}..${syntheticOrigin(rounds)}, '
        'socks ${socks.port}, '
        'proxySupported=${PlatformInfo.isProxySupported} '
        'containers=$containers');
  });

  tearDownAll(() async {
    log('socks connects=${socks.targets}');
    final proxied = outcomes.where((o) => o == 'proxied').length;
    log('verdict: containers=$containers, first-frame-control=$control, '
        'proxied=$proxied of ${outcomes.length}, rounds=[${outcomes.join(" ")}]');
    await socks.close();
  });

  bool usable() {
    if (!applies) {
      markTestSkipped('the per-WebView proxy is an Apple path');
      return false;
    }
    expect(PlatformInfo.isProxySupported, isTrue,
        reason: 'proxy support reads unavailable on an Apple tier past the '
            'floor; PlatformInfo.initialize() was most likely not awaited');
    return true;
  }

  /// One pane on the shared endpoint, in the process's first frame. This is
  /// the arrangement that has proxied in every run it was measured in
  /// (`proxy_binding`'s pair), so a direct reading here means the process is
  /// not proxying anything and nothing after it can be interpreted.
  testWidgets('the control: one pane on that endpoint in the first frame',
      (tester) async {
    if (!usable()) return;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 240,
          height: 120,
          child: inapp.InAppWebView(
            key: const ValueKey('rate-control'),
            initialUrlRequest: inapp.URLRequest(
              url: inapp.WebUri('http://${syntheticOrigin(rounds)}/r$rounds'),
            ),
            initialSettings: inapp.InAppWebViewSettings(
              containerId: 'ws-proxy-rate-control',
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

    final target = '${syntheticOrigin(rounds)}:';
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 12));
      while (DateTime.now().isBefore(deadline)) {
        if (socks.targets.any((t) => t.startsWith(target))) break;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    });

    // Nothing routes to a synthetic destination, so a load that did not reach
    // the fixture went direct and failed; the two are one reading.
    control = socks.targets.any((t) => t.startsWith(target))
        ? 'proxied'
        : 'DIRECT-or-failed';
    log('first-frame control -> $control');
    expect(
      control,
      'proxied',
      reason: 'the first frame on a shared SOCKS endpoint is the one '
          'arrangement that has bound a proxy in every run it was measured '
          'in. Direct here means this process proxied nothing at all, so the '
          'rate below is a reading about the process rather than about later '
          'frames, and must not be recorded as a rate',
    );
  });

  testWidgets('the same proxied load, drawn $rounds times', (tester) async {
    if (!usable()) return;

    for (var i = 0; i < rounds; i++) {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 240,
            height: 120,
            child: inapp.InAppWebView(
              // Fresh key per round: reusing the position updates the existing
              // platform view and the round's load is never issued.
              key: ValueKey('rate$i'),
              initialUrlRequest: inapp.URLRequest(
                url: inapp.WebUri('http://${syntheticOrigin(i)}/r$i'),
              ),
              initialSettings: inapp.InAppWebViewSettings(
                containerId: 'ws-proxy-rate-$i',
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

      final target = '${syntheticOrigin(i)}:';
      await tester.runAsync(() async {
        final deadline = DateTime.now().add(const Duration(seconds: 12));
        while (DateTime.now().isBefore(deadline)) {
          if (socks.targets.any((t) => t.startsWith(target))) break;
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      });

      final outcome = socks.targets.any((t) => t.startsWith(target))
          ? 'proxied'
          : 'DIRECT-or-failed';
      outcomes.add(outcome);
      log('round $i -> $outcome');
    }

    final proxied = outcomes.where((o) => o == 'proxied').length;
    final loaded = outcomes.length;
    expect(
      control,
      'proxied',
      reason: 'the control went $control, so this process was not proxying '
          'at all and [${outcomes.join(" ")}] says nothing about later frames',
    );
    expect(
      loaded,
      rounds,
      reason: 'every round must have loaded, or the rate is measured over '
          'fewer draws than it claims. Got [${outcomes.join(" ")}]',
    );
    // The assertion the feature turns on. A partial rate fails here too, and
    // should: a proxy that is used four times in eight is not a proxy, and
    // reporting it as one is the leak.
    expect(
      proxied,
      rounds,
      reason: 'a per-site proxy must be used on every load, not on a '
          'fraction of them. Got $proxied of $rounds: [${outcomes.join(" ")}]',
    );
  });
}
