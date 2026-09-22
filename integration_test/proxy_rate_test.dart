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
// container and its own origin each round, so no round can reuse another's
// connection or container. Every round points at **one shared SOCKS5
// endpoint**, which matters: it is the arrangement a per-site proxy relay
// would produce, so a null result here is a result about relays too.
//
// A rate is what tells a race from a rule. All proxied or none proxied is a
// rule; anything between is a race, and the app cannot ship a privacy feature
// that works k times in n either way.
//
// The control is not optional. Run 3097 produced a whole process --
// proxy_simultaneous -- that proxied nothing at all, including its first
// frame, while another process in the same run proxied its first-frame pair.
// Against a process in that state a count of zero measures the process, not
// the scenario, and reads identically to a real zero. So the first test here
// mounts one pane in the process's own first frame, on the same shared
// endpoint: if that pane goes direct the rounds that follow say nothing and
// the file must report a void draw rather than a rate.

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
  String control = 'not run';
  final ports = <int>[];
  final requests = <String>[];
  InternetAddress? routable;
  var originHost = '127.0.0.1';
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
    routable = await nonLoopbackIPv4();
    originHost = routable?.address ?? '127.0.0.1';
    socks = await Socks5Fixture.bind();
    // One origin per round. A round reusing the previous round's origin could
    // ride its connection, which reads as "no proxy was asked for".
    // rounds origins, plus one for the first-frame control.
    for (var i = 0; i <= rounds; i++) {
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
    log('verdict: containers=$containers, first-frame-control=$control, '
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

  /// One pane on the shared endpoint, in the process's first frame. This is
  /// the arrangement that has proxied in every run it was measured in
  /// (`proxy_binding`'s pair), so a direct reading here means the process is
  /// not proxying anything and nothing after it can be interpreted.
  testWidgets('the control: one pane on that endpoint in the first frame',
      (tester) async {
    if (!usable()) return;
    final port = ports[rounds];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 240,
          height: 120,
          child: inapp.InAppWebView(
            key: const ValueKey('rate-control'),
            initialUrlRequest: inapp.URLRequest(
              url: inapp.WebUri('http://$originHost:$port/r$rounds'),
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

    final target = '$originHost:$port';
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 12));
      while (DateTime.now().isBefore(deadline)) {
        if (socks.targets.contains(target) ||
            requests.contains('r$rounds:/r$rounds')) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    });

    control = socks.targets.contains(target)
        ? 'proxied'
        : requests.contains('r$rounds:/r$rounds')
            ? 'DIRECT'
            : 'no-load';
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
