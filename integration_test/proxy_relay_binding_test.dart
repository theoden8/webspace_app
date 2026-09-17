// The goal, measured at the layer that decides it: two data stores, two
// different upstream proxies, both working at the same time, through WebKit.
//
// This is the repair rather than another probe. Every store points at ONE
// loopback HTTP CONNECT endpoint -- `LocalProxyRelay` -- and carries its own
// proxy-auth credential; the relay reads the credential and dials that site's
// real upstream. Two things follow, and they are the two failures BUG-014 has
// been circling:
//
//  * **Simultaneity.** No two stores ever hold different proxy
//    configurations, because they all hold the same endpoint. Whatever
//    WebKit does when a second store's proxy replaces the first cannot
//    arise, and `pair=2 of 2 proxied` already showed stores sharing one
//    proxy work.
//  * **Durability.** An HTTP CONNECT configuration makes
//    `nw_proxy_config_stack_requires_http_protocols` true, which sets
//    `recreateSessions` in `NetworkSessionCocoa::setProxyConfigData`, which
//    runs `recreateSessionWithUpdatedProxyConfigurations` -- the one route
//    that writes the proxy onto a session's own
//    `NSURLSessionConfiguration`. A SOCKS5 rule never reaches it, so on that
//    rule the default wrapper is built with `@[ ]` and patched only on its
//    live `nw_context` (BUG-014 attempt 36).
//
// So the second test is the one that matters: it builds its panes in a LATER
// frame, which is where every previous arrangement went direct.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/container_native.dart';
import 'package:webspace/services/local_proxy_relay.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/settings/proxy.dart';
import 'fixture_server.dart';
import 'socks5_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final applies = hostIsIOS || hostIsMacOS;

  void log(String m) {
    // ignore: avoid_print
    print('[proxy-relay] $m');
  }

  /// Two sites in the first frame, two more in a later one. Each gets its own
  /// upstream SOCKS fixture, so "reached its own" is a positive reading off
  /// that fixture's CONNECT log rather than off the origin.
  const siteCount = 4;

  final socks = <Socks5Fixture>[];
  final origins = <HttpServer>[];
  final ports = <int>[];
  final requests = <String>[];
  late LocalProxyRelay relay;
  InternetAddress? routable;
  var originHost = '127.0.0.1';
  var containers = false;
  final verdict = <String>[];

  String userFor(int i) => 'ws-relay-site-$i';
  String tokenFor(int i) => 'token-$i-not-a-secret-in-a-test';

  setUpAll(() async {
    if (applies) {
      containers = await ContainerNative.instance.isSupported();
    }
    // Without this `isProxySupported` is false and every scenario below
    // skips, which is how two files in this directory once reported green
    // having measured nothing.
    await PlatformInfo.initialize();
    routable = await nonLoopbackIPv4();
    originHost = routable?.address ?? '127.0.0.1';

    for (var i = 0; i < siteCount; i++) {
      final origin = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      origins.add(origin);
      ports.add(origin.port);
      listenFixture(origin, (req) async {
        requests.add('s$i:${req.uri.path}');
        final res = req.response..headers.contentType = ContentType.html;
        res.write('<!doctype html><html><body><p>s$i</p></body></html>');
        await res.close();
      });
      socks.add(await Socks5Fixture.bind());
    }

    relay = LocalProxyRelay(realm: 'webspace-relay-test');
    expect(
      await relay.start(),
      isTrue,
      reason: 'the relay is the thing under test; if it cannot bind there is '
          'nothing to measure',
    );
    relay.setRoutes({
      for (var i = 0; i < siteCount; i++)
        userFor(i): LocalProxyRoute(
          siteId: 'site-$i',
          token: tokenFor(i),
          upstream: UserProxySettings(
            type: ProxyType.SOCKS5,
            address: '${InternetAddress.loopbackIPv4.address}:${socks[i].port}',
          ),
        ),
    });

    log('relay on ${relay.host}:${relay.port}, origins ${ports.join(",")} '
        'on $originHost, upstream socks ${socks.map((s) => s.port).join(",")}, '
        'proxySupported=${PlatformInfo.isProxySupported} '
        'containers=$containers');
  });

  tearDownAll(() async {
    for (var i = 0; i < socks.length; i++) {
      log('socks$i connects=${socks[i].targets}');
    }
    log('verdict: containers=$containers, ${verdict.join(", ")}');
    await relay.stop();
    for (final s in socks) {
      await s.close();
    }
    for (final o in origins) {
      await o.close(force: true);
    }
  });

  bool usable() {
    if (!applies) {
      markTestSkipped('the per-WebView proxy is an Apple path');
      return false;
    }
    expect(
      routable,
      isNotNull,
      reason: 'no non-loopback IPv4 here, and Apple never sends a loopback '
          'destination through a proxy, so nothing could be distinguished',
    );
    expect(
      PlatformInfo.isProxySupported,
      isTrue,
      reason: 'proxy support reads as unavailable on an Apple tier past the '
          'iOS 17 / macOS 14 floor; PlatformInfo.initialize() was most '
          'likely not awaited',
    );
    return true;
  }

  Future<bool> waitReal(
    WidgetTester tester,
    bool Function() done, {
    required String label,
    Duration timeout = const Duration(seconds: 30),
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

  int? upstreamThatSaw(String target) {
    for (var i = 0; i < socks.length; i++) {
      if (socks[i].targets.contains(target)) return i;
    }
    return null;
  }

  /// A pane bound to the relay with site [i]'s credential. The proxy every
  /// pane carries is byte-identical apart from that credential, which is the
  /// whole point.
  Widget pane(int i) => SizedBox(
        width: 200,
        height: 90,
        child: inapp.InAppWebView(
          key: ValueKey('relay$i'),
          initialUrlRequest: inapp.URLRequest(
            url: inapp.WebUri('http://$originHost:${ports[i]}/s$i'),
          ),
          initialSettings: inapp.InAppWebViewSettings(
            containerId: 'ws-proxy-relay-$i',
            proxySettings: inapp.ProxySettings(
              proxyRules: [
                inapp.ProxyRule(
                  url: 'http://${relay.host}:${relay.port}',
                  username: userFor(i),
                  password: tokenFor(i),
                ),
              ],
              bypassRules: [],
            ),
          ),
        ),
      );

  String classify(int i) {
    final saw = upstreamThatSaw('$originHost:${ports[i]}');
    if (saw == i) return 'own(socks$saw)';
    if (saw != null) return 'CROSSED(socks$saw)';
    return requests.contains('s$i:/s$i') ? 'DIRECT' : 'no load';
  }

  Future<List<String>> run(
    WidgetTester tester,
    List<int> panes, {
    required String label,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Column(children: [for (final i in panes) pane(i)])),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));

    bool settled(int i) =>
        upstreamThatSaw('$originHost:${ports[i]}') != null ||
        requests.contains('s$i:/s$i');

    await waitReal(tester, () => panes.every(settled), label: label);
    return [for (final i in panes) 's$i->${classify(i)}'];
  }

  testWidgets('the first frame: two sites, two upstreams, one relay',
      (tester) async {
    if (!usable()) return;
    final results = await run(tester, [0, 1], label: 'first-frame panes');
    verdict.add('first-frame=[${results.join(" ")}]');
    expect(
      results.where((r) => r.contains('own(')).length,
      2,
      reason: 'two stores on one relay endpoint, each with its own credential, '
          'must each reach their own upstream. Got [${results.join(" ")}]',
    );
  });

  testWidgets('a later frame: the case every other arrangement lost',
      (tester) async {
    if (!usable()) return;
    final results = await run(tester, [2, 3], label: 'later-frame panes');
    verdict.add('later-frame=[${results.join(" ")}]');
    expect(
      results.where((r) => r.contains('own(')).length,
      2,
      reason: 'this is the reading BUG-014 turns on: stores built after the '
          'first frame went direct on every earlier arrangement. Got '
          '[${results.join(" ")}]',
    );
  });
}
