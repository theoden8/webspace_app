// How often does a per-site proxy actually get used? Not "under which rule" --
// how often.
//
// BUG-014 spent thirty-odd attempts deriving rules from one sample per
// scenario, and attempt 37 showed the thing being sampled is random: the same
// file, byte-identical, against the same plugin pin, reported `raw-late=DIRECT`
// on one run and `raw-late=proxied` on the next. Every "only X is proxied"
// statement in that file was a single draw from a distribution nobody had
// measured.
//
// So this file measures the distribution instead. One scenario, repeated: a
// webview built in a later frame -- the case the app is actually made of,
// since only the first site a user opens is in the first frame -- with its own
// container, its own proxy and its own origin each round, so no round can
// reuse another's connection or container. The verdict is a count.
//
// A rate is what tells a race from a rule. All proxied or none proxied is a
// rule; anything between is a race, and the app cannot ship a privacy feature
// that works k times in n either way.

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
    print('[proxy-rate] $m');
  }

  /// Enough draws to tell "never" from "sometimes" without spending the
  /// tier's budget: at a true rate of one in three, eight rounds miss every
  /// time with probability under 4%.
  const rounds = 8;

  late Socks5Fixture socks;
  final origins = <HttpServer>[];
  final ports = <int>[];
  final requests = <String>[];
  InternetAddress? routable;
  var originHost = '127.0.0.1';
  var containers = false;
  final outcomes = <String>[];

  setUpAll(() async {
    if (applies) {
      containers = await ContainerNative.instance.isSupported();
    }
    await PlatformInfo.initialize();
    routable = await nonLoopbackIPv4();
    originHost = routable?.address ?? '127.0.0.1';
    socks = await Socks5Fixture.bind();
    // One origin per round. A round reusing the previous round's origin could
    // ride its connection, which reads as "no proxy was asked for".
    for (var i = 0; i < rounds; i++) {
      final origin = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      origins.add(origin);
      ports.add(origin.port);
      listenFixture(origin, (req) async {
        requests.add('r$i:${req.uri.path}');
        final res = req.response..headers.contentType = ContentType.html;
        res.write('<!doctype html><html><body><p>r$i</p></body></html>');
        await res.close();
      });
    }
    log('origins ${ports.join(",")} on $originHost, socks ${socks.port}, '
        'proxySupported=${PlatformInfo.isProxySupported} '
        'containers=$containers');
  });

  tearDownAll(() async {
    log('socks connects=${socks.targets}');
    final proxied = outcomes.where((o) => o == 'proxied').length;
    log('verdict: containers=$containers, '
        'proxied=$proxied of ${outcomes.length}, rounds=[${outcomes.join(" ")}]');
    await socks.close();
    for (final o in origins) {
      await o.close(force: true);
    }
  });

  bool usable() {
    if (!applies) {
      markTestSkipped('the per-WebView proxy is an Apple path');
      return false;
    }
    expect(routable, isNotNull,
        reason: 'no non-loopback IPv4; Apple never proxies a loopback '
            'destination, so nothing here could be distinguished');
    expect(PlatformInfo.isProxySupported, isTrue,
        reason: 'proxy support reads unavailable on an Apple tier past the '
            'floor; PlatformInfo.initialize() was most likely not awaited');
    return true;
  }

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
                url: inapp.WebUri('http://$originHost:${ports[i]}/r$i'),
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

      final target = '$originHost:${ports[i]}';
      await tester.runAsync(() async {
        final deadline = DateTime.now().add(const Duration(seconds: 12));
        while (DateTime.now().isBefore(deadline)) {
          if (socks.targets.contains(target) ||
              requests.contains('r$i:/r$i')) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      });

      final outcome = socks.targets.contains(target)
          ? 'proxied'
          : requests.contains('r$i:/r$i')
              ? 'DIRECT'
              : 'no-load';
      outcomes.add(outcome);
      log('round $i -> $outcome');
    }

    final proxied = outcomes.where((o) => o == 'proxied').length;
    final loaded = outcomes.where((o) => o != 'no-load').length;
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
