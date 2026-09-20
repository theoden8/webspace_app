// When does a per-site proxy stop applying on Apple? (BUG-014, LEAK-003)
//
// Attempt 80 settled that several per-site proxies work at once: four stores
// reached four distinct upstreams in one frame, across both deliveries and
// both URL schemes. What it could not settle is timing. Its `prebound` arm
// sat at about:blank in frame 1 and went direct when navigated later, but a
// store that never proxied anything cannot distinguish "lost it" from "never
// had it".
//
// That distinction is the whole product question:
//
//  * If a store that HAS proxied keeps proxying, the leak is per-store and a
//    site's own browsing is safe once its first load binds. Only a newly
//    activated site is exposed.
//  * If it stops after one load, every link click on a proxied site leaves
//    over the device IP, and the feature is unusable rather than partial.
//
// So pane A is proxied in frame 1 -- that is both the positive control and
// the baseline -- and then the arms vary only WHEN and HOW the next
// navigation is issued. Every verdict is read off the fixture's CONNECT log,
// never off the origin, because the fixture relays and a proxied load reaches
// the origin too.
//
// Gap -2: this file MUST run first in the macOS tier. Only the tier's first
// app process can proxy; anywhere else it measures a dead process and says
// so via the control.

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
  final runLabel = Platform.environment['WEBSPACE_TIMING_RUN'] ?? '1';

  void log(String m) {
    // ignore: avoid_print
    print('[proxy-timing] $m');
  }

  // 0 pane A's frame-1 load (the control and the baseline)
  // 1 pane A's SECOND navigation, same store, same proxy, later frame
  // 2 a brand-new store in a later frame
  // 3 a brand-new store after an idle period
  const originCount = 4;
  final origins = <HttpServer>[];
  final ports = <int>[];
  final socks = <Socks5Fixture>[];
  final requests = <String>[];
  InternetAddress? routable;
  var originHost = '127.0.0.1';
  var containers = false;
  inapp.InAppWebViewController? paneA;
  final verdict = <String, String>{};

  setUpAll(() async {
    if (!applies) return;
    await PlatformInfo.initialize();
    containers = await ContainerNative.instance.isSupported();
    routable = await nonLoopbackIPv4();
    originHost = routable?.address ?? '127.0.0.1';
    for (var i = 0; i < originCount; i++) {
      final origin = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      origins.add(origin);
      ports.add(origin.port);
      listenFixture(origin, (req) async {
        requests.add('o$i');
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
      log('socks$i connects=${socks[i].targets}');
    }
    log('run=$runLabel verdict: containers=$containers '
        '${verdict.entries.map((e) => "${e.key}=${e.value}").join(" ")}');
    for (final s in socks) {
      await s.close();
    }
    for (final o in origins) {
      await o.close(force: true);
    }
  });

  String urlFor(int i) => 'http://$originHost:${ports[i]}/o$i';

  /// Did the fixture that is supposed to carry origin [i] actually get asked
  /// for it? Checked against every fixture so a crossed circuit is named.
  String classify(int i, int expectedSocks) {
    final target = '$originHost:${ports[i]}';
    for (var s = 0; s < socks.length; s++) {
      if (socks[s].targets.contains(target)) {
        return s == expectedSocks ? 'own' : 'CROSSED(socks$s)';
      }
    }
    return requests.contains('o$i') ? 'DIRECT' : 'no-load';
  }

  bool settled(int i) {
    final target = '$originHost:${ports[i]}';
    return socks.any((s) => s.targets.contains(target)) || requests.contains('o$i');
  }

  Future<void> waitReal(WidgetTester tester, bool Function() done,
      {required String label,
      Duration timeout = const Duration(seconds: 25)}) async {
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

  Widget pane(int i, {required int socksIndex, String? url}) => SizedBox(
        width: 160,
        height: 60,
        child: inapp.InAppWebView(
          key: ValueKey('timing-$i'),
          initialUrlRequest:
              inapp.URLRequest(url: inapp.WebUri(url ?? urlFor(i))),
          initialSettings: inapp.InAppWebViewSettings(
            containerId: 'ws-timing-$runLabel-$i',
            proxySettings: inapp.ProxySettings(
              proxyRules: [
                inapp.ProxyRule(url: 'socks5://127.0.0.1:${socks[socksIndex].port}')
              ],
              bypassRules: [],
            ),
          ),
          onWebViewCreated: (c) {
            if (i == 0) paneA = c;
          },
        ),
      );

  bool usable() {
    if (!applies) {
      markTestSkipped('the per-WebView proxy is an Apple path');
      return false;
    }
    expect(routable, isNotNull,
        reason: 'no non-loopback IPv4 here, and Apple never proxies a loopback '
            'destination, so nothing could be distinguished');
    expect(PlatformInfo.isProxySupported, isTrue,
        reason: 'proxy support reads unavailable past the floor; '
            'PlatformInfo.initialize() was most likely not awaited');
    return true;
  }

  // One test, not four. `testWidgets` tears the widget tree down between
  // tests, so pane A's platform view is gone by the next one and its
  // controller is stale -- which is exactly how the first run of this file
  // read `same-store-2nd-nav=no-load`: the loadUrl no-opped against a
  // disposed WebView. Keeping the arms in one test is what lets the SAME
  // WebView, not merely the same container, issue the second navigation.
  testWidgets('when a per-site proxy stops applying', (tester) async {
    if (!usable()) return;

    // Frame 1. Both the positive control and the baseline: if this does not
    // proxy, the process is one of the poisoned ones (BUG-014 gap -2) and
    // nothing below means anything.
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Column(children: [pane(0, socksIndex: 0)])),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));
    await waitReal(tester, () => settled(0), label: 'frame-1 pane A');
    verdict['baseline'] = classify(0, 0);
    final baselineProxied = verdict['baseline'] == 'own';
    log('baseline=${verdict["baseline"]}');

    if (!baselineProxied) {
      for (final k in const [
        'same-store-2nd-nav',
        'new-store-later',
        'new-store-after-idle'
      ]) {
        verdict[k] = 'void';
      }
    } else {
      // The question the matrix could not answer: the very WebView that just
      // proxied, navigating again, no rebuild in between.
      final controller = paneA;
      expect(controller, isNotNull,
          reason: 'pane A reported no controller, so its second navigation '
              'could not be issued');
      await tester.runAsync(() async {
        await controller!.loadUrl(
            urlRequest: inapp.URLRequest(url: inapp.WebUri(urlFor(1))));
      });
      await waitReal(tester, () => settled(1),
          label: 'pane A second navigation');
      verdict['same-store-2nd-nav'] = classify(1, 0);
      log('same-store-2nd-nav=${verdict["same-store-2nd-nav"]}');

      // A brand-new store in a later frame. Pane A stays in the tree so its
      // WebView is not torn down under the new one.
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(children: [
            pane(0, socksIndex: 0, url: urlFor(1)),
            pane(2, socksIndex: 2),
          ]),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 500));
      await waitReal(tester, () => settled(2), label: 'new store, later frame');
      verdict['new-store-later'] = classify(2, 2);
      log('new-store-later=${verdict["new-store-later"]}');

      await tester
          .runAsync(() => Future<void>.delayed(const Duration(seconds: 6)));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(children: [
            pane(0, socksIndex: 0, url: urlFor(1)),
            pane(2, socksIndex: 2),
            pane(3, socksIndex: 3),
          ]),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 500));
      await waitReal(tester, () => settled(3), label: 'new store after idle');
      verdict['new-store-after-idle'] = classify(3, 3);
      log('new-store-after-idle=${verdict["new-store-after-idle"]}');
    }

    // Reported, not asserted: every arm above is the open question, and a
    // process that could not proxy produces the same nulls as a platform
    // that drops the proxy. The baseline is what separates them.
    expect(verdict['baseline'], 'own',
        reason: 'pane A did not proxy in frame 1, so no verdict in this file '
            'is evidence about timing');
  });
}
