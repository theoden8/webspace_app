// What closes the per-site proxy window on Apple (LEAK-003, BUG-014).
//
// `proxy_binding_test.dart` establishes the shape and cannot establish the
// cause, because every proxied reading it has is also the process's first
// frame *and* the first thing in the process to touch the network. Its
// staircase settled one half of that: the boundary is not elapsed time and
// not a race. A webview navigated by `loadUrl` from inside
// `onWebViewCreated` is proxied; the same call on another first-frame
// webview 0ms after the tree settled is not, and so are the four steps
// after it. Five consecutive samples, one outcome.
//
// So the window closes on an event, not on a clock. The candidate that
// WebKit's source names is the network process: `WebsiteDataStore::
// setProxyConfigData` clears `m_proxyConfigData`, calls `networkProcess()`
// -- which registers the session and reads its parameters right then --
// and only afterwards restores the data. A store registered while that
// process is still launching has its parameters read later, once the
// connection is up, with the proxy back in place. A store registered
// against a process that is already running is read immediately, with the
// proxy missing.
//
// If that is the mechanism, "the first frame" is a coincidence of this
// suite: the first frame is simply where the first load happens. This file
// separates them. It spends its first frame on an *unproxied* load, which
// brings the network process up and nothing else, and then builds the
// proxied pair in the second frame. Two proxied loads there says the window
// is the widget frame. Zero says it is the network process, and that the
// startup pre-arm of BUG-014 attempt 20 failed only because it ran after
// something had already brought that process up.
//
// One file per app process is how the tier runs, which is what makes this
// measurable at all: this file owns its own first frame.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/webview.dart';
import 'fixture_server.dart';
import 'socks5_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final applies = hostIsIOS || hostIsMacOS;

  late HttpServer warmOrigin;
  late HttpServer originA;
  late HttpServer originB;
  late int warmPort;
  late int portA;
  late int portB;
  late String originHost;
  late Socks5Fixture socks;
  InternetAddress? routable;
  final requests = <String>[];
  final verdict = <String>[];

  void log(String m) {
    // ignore: avoid_print
    print('[proxy-window] $m');
  }

  HttpServer serve(HttpServer origin, String tag) {
    listenFixture(origin, (req) async {
      requests.add('$tag:${req.uri.path}');
      final res = req.response..headers.contentType = ContentType.html;
      res.write('<!doctype html><html><body><p>$tag</p></body></html>');
      await res.close();
    });
    return origin;
  }

  setUpAll(() async {
    await PlatformInfo.initialize();
    routable = await nonLoopbackIPv4();
    originHost = (routable ?? InternetAddress.loopbackIPv4).address;
    warmOrigin = serve(
        await HttpServer.bind(InternetAddress.anyIPv4, 0), 'warm');
    warmPort = warmOrigin.port;
    originA = serve(await HttpServer.bind(InternetAddress.anyIPv4, 0), 'a');
    portA = originA.port;
    originB = serve(await HttpServer.bind(InternetAddress.anyIPv4, 0), 'b');
    portB = originB.port;
    socks = await Socks5Fixture.bind();
    log('origin on $originHost, socks on ${socks.port}, '
        'proxySupported=${PlatformInfo.isProxySupported}');
  });

  tearDownAll(() async {
    log('verdict: ${verdict.join(", ")}');
    await socks.close();
    await warmOrigin.close(force: true);
    await originA.close(force: true);
    await originB.close(force: true);
  });

  /// Wall-clock wait: a live compositing platform view blocks `pump()`.
  Future<bool> waitReal(
    WidgetTester tester,
    bool Function() done, {
    required String label,
    Duration timeout = const Duration(seconds: 20),
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

  bool usable() {
    if (!applies) {
      markTestSkipped('the proxy window is an Apple path');
      return false;
    }
    expect(routable, isNotNull,
        reason: 'no non-loopback IPv4 on this machine, and Apple never sends '
            'a loopback destination through a proxy, so nothing here could '
            'distinguish a bound proxy from an unbound one');
    return true;
  }

  Widget pane(String containerId, String url, {int? proxyPort}) => SizedBox(
        width: 320,
        height: 160,
        child: inapp.InAppWebView(
          key: ValueKey(containerId),
          initialUrlRequest: inapp.URLRequest(url: inapp.WebUri(url)),
          initialSettings: inapp.InAppWebViewSettings(
            containerId: containerId,
            proxySettings: proxyPort == null
                ? null
                : inapp.ProxySettings(
                    proxyRules: [
                      inapp.ProxyRule(url: 'socks5://127.0.0.1:$proxyPort'),
                    ],
                    bypassRules: [],
                  ),
          ),
        ),
      );

  testWidgets('the first frame is spent bringing the network process up',
      (tester) async {
    // No proxy on this one. Its only job is to make WebKit's networking
    // exist before any proxied store is configured -- which is the one
    // thing every proxied reading in the sibling file has never had in
    // front of it.
    if (!usable()) return;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: pane('ws-proxy-window-warm', 'http://$originHost:$warmPort/w'),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));
    final warmed = await waitReal(tester, () => requests.contains('warm:/w'),
        label: 'unproxied warm-up load');
    verdict.add('warm=${warmed ? "loaded" : "NEVER LOADED"}');
    expect(
      warmed,
      isTrue,
      reason: 'the warm-up load never reached its origin, so the network '
          'process may not have come up and the measurement below cannot '
          'mean anything',
    );
  });

  testWidgets('a proxied pair in the second frame', (tester) async {
    if (!usable()) return;
    if (!PlatformInfo.isProxySupported) {
      markTestSkipped('below the proxyConfigurations floor');
      return;
    }
    socks.targets.clear();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          pane('ws-proxy-window-a', 'http://$originHost:$portA/a',
              proxyPort: socks.port),
          pane('ws-proxy-window-b', 'http://$originHost:$portB/b',
              proxyPort: socks.port),
        ]),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));
    await waitReal(
        tester,
        () =>
            socks.targets.contains('$originHost:$portA') &&
            socks.targets.contains('$originHost:$portB'),
        label: 'two proxied webviews after the network process exists',
        timeout: const Duration(seconds: 25));
    final proxied = [
      if (socks.targets.contains('$originHost:$portA')) 'a',
      if (socks.targets.contains('$originHost:$portB')) 'b',
    ];
    verdict.add('after-warmup=${proxied.length} of 2 proxied'
        '${proxied.isEmpty ? "" : " (${proxied.join("+")})"}, '
        'arrived=${[
      if (requests.contains('a:/a')) 'a',
      if (requests.contains('b:/b')) 'b',
    ].join("+")}');
    // Measurement, not assertion: both outcomes are the answer to a
    // different question, and neither is a defect of this file.
    //
    //   2 of 2 -> the window is the widget frame, and the network process
    //             is not what closes it.
    //   0 of 2 -> the window closes when WebKit's networking comes up, "the
    //             first frame" was a coincidence of where the first load
    //             happens, and arming every proxied store before anything
    //             touches the network is a repair rather than the no-op
    //             attempt 20 measured.
  });
}
