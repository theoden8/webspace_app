// A per-site proxy across a store's life: a second navigation on the same
// store, the CONNECT route beside the SOCKS one in the same process, a store
// built in a later frame, and one built after an idle period.
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
import 'package:webspace/services/local_proxy_relay.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/settings/proxy.dart';
import 'socks5_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final applies = hostIsIOS || hostIsMacOS;
  final runLabel = Platform.environment['WEBSPACE_TIMING_RUN'] ?? '1';

  void log(String m) {
    // Timestamped so the verdict lines can be aligned against WebKit's own
    // os_log stream, which is the only view of which session-creation path
    // actually ran (NetworkSessionCocoa RELEASE_LOGs from
    // initializeNSURLSessionsInSet and configurationForSessionID; the
    // isolated / ephemeral / app-bound copy-paths log nothing).
    // ignore: avoid_print
    print('[proxy-timing] ${DateTime.now().toUtc().toIso8601String()} $m');
  }

  // WebKit installs a store's proxy by one of two routes and the caller does
  // not choose: `NetworkSessionCocoa::setProxyConfigData` rebuilds each
  // NSURLSession with the proxy on its own NSURLSessionConfiguration when
  // `nw_proxy_config_stack_requires_http_protocols` holds for any
  // configuration, and otherwise patches the live `nw_context` -- which it
  // clears before it adds, and de-duplicates across session wrappers. A
  // SOCKS5 rule only ever takes the second.
  //
  // Every reading behind that answer was taken on SOCKS5, so on the
  // patch route only. Pane C runs the identical two-navigation sequence
  // through a loopback CONNECT relay, which forces the rebuild route. If C's
  // second navigation is proxied where A's is not, the bypass belongs to the
  // live-`nw_context` half and delivery is the fix; if both bypass, the route
  // is not the variable and the relay buys nothing here.
  //
  // 0 pane A's frame-1 load (the control and the baseline)
  // 1 unused as an origin: pane A's second navigation goes back to origin 0,
  //   so host, port, registrable domain and storage policy are identical to
  //   the load that WAS proxied. sessionWrapperForTask routes on
  //   RegistrableDomain(firstPartyForCookies), so nothing about the request
  //   can select a different session wrapper (attempt 84).
  // 2 a brand-new store in a later frame
  // 3 a brand-new store after an idle period
  const originCount = 5;
  // Destinations, not origins on this machine: macOS routes an address the
  // host owns over `lo0` and Apple never proxies a loopback-routed
  // destination, so an origin bound here reads DIRECT whether or not the
  // proxy was bound (BUG-014 caution 1). Nothing routes to a
  // `syntheticOrigin`, so the fixture answers it and an arrival IS the proof.
  final socks = <Socks5Fixture>[];
  late LocalProxyRelay relay;
  const relayUser = 'ws-timing-c';
  const relayToken = 'timing-c-token';
  inapp.InAppWebViewController? paneC;
  var containers = false;
  inapp.InAppWebViewController? paneA;
  final verdict = <String, String>{};

  setUpAll(() async {
    if (!applies) return;
    await PlatformInfo.initialize();
    containers = await ContainerNative.instance.isSupported();
    for (var i = 0; i < originCount; i++) {
      socks.add(await Socks5Fixture.bind());
    }
    // Pane C's upstream is socks[4]; the relay in front of it is what makes
    // the rule a CONNECT one.
    relay = LocalProxyRelay(realm: 'webspace-timing');
    expect(await relay.start(), isTrue,
        reason: 'the CONNECT arm needs its relay; without it pane C says '
            'nothing about the delivery route');
    relay.setRoutes({
      relayUser: LocalProxyRoute(
        siteId: 'timing-c',
        token: relayToken,
        upstream: UserProxySettings(
          type: ProxyType.SOCKS5,
          address: '127.0.0.1:${socks[4].port}',
        ),
      ),
    });
    log('run=$runLabel destinations=${[
      for (var i = 0; i < originCount; i++) syntheticOrigin(i)
    ].join(",")} '
        'socks=${socks.map((s) => s.port).join(",")} '
        'proxySupported=${PlatformInfo.isProxySupported} containers=$containers');
  });

  tearDownAll(() async {
    if (!applies) return;
    for (var i = 0; i < socks.length; i++) {
      log('socks$i connects=${socks[i].targets} '
          'served=${socks[i].servedSynthetic}');
    }
    log('run=$runLabel verdict: containers=$containers '
        '${verdict.entries.map((e) => "${e.key}=${e.value}").join(" ")}');
    await relay.stop();
    for (final s in socks) {
      await s.close();
    }
  });

  String urlFor(int i) => 'http://${syntheticOrigin(i)}/o$i';

  /// Which fixture last carried destination [i], or -1 if none did.
  int lastCircuit(int i) {
    for (var s = socks.length - 1; s >= 0; s--) {
      if (socks[s].targets.any((t) => t.startsWith('${syntheticOrigin(i)}:'))) {
        return s;
      }
    }
    return -1;
  }

  /// How many times destination [i] has arrived at any fixture.
  int arrivalsFor(int i) => socks
      .expand((s) => s.syntheticPaths)
      .where((t) => t.startsWith(syntheticOrigin(i)))
      .length;

  /// Did destination [i] arrive through the fixture that is supposed to carry
  /// it? Nothing routes to a synthetic destination, so an arrival at ANY
  /// fixture went through a proxy, the fixture that saw it names the circuit,
  /// and no arrival means the load went direct and could not have succeeded.
  String classify(int i, int expectedSocks) {
    final want = '${syntheticOrigin(i)}:';
    for (var s = 0; s < socks.length; s++) {
      if (socks[s].targets.any((t) => t.startsWith(want))) {
        return s == expectedSocks ? 'own' : 'CROSSED(socks$s)';
      }
    }
    return 'DIRECT';
  }

  bool settled(int i) =>
      socks.any((s) => s.targets.any((t) => t.startsWith('${syntheticOrigin(i)}:')));

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
                // Pinned, not left to Apple's default, which the docs do not
                // state. With failover permitted, a proxy that cannot serve a
                // request yields a silent direct load -- indistinguishable
                // from a proxy that was never consulted, which is exactly the
                // reading attempt 82 mistook for a rule. False turns that
                // case into a failed load instead.
                inapp.ProxyRule(
                  url: 'socks5://127.0.0.1:${socks[socksIndex].port}',
                  allowFailover: false,
                )
              ],
              bypassRules: [],
            ),
          ),
          onWebViewCreated: (c) {
            if (i == 0) paneA = c;
          },
        ),
      );

  /// Pane C: same store shape as pane A, but its rule names the loopback
  /// CONNECT relay and carries the credential the relay routes on. The
  /// upstream behind it is socks[4], so `classify(4, 4)` reads it the same
  /// way every other arm is read.
  Widget paneConnect() => SizedBox(
        width: 160,
        height: 60,
        child: inapp.InAppWebView(
          key: const ValueKey('timing-connect'),
          initialUrlRequest: inapp.URLRequest(url: inapp.WebUri(urlFor(4))),
          initialSettings: inapp.InAppWebViewSettings(
            containerId: 'ws-timing-$runLabel-c',
            proxySettings: inapp.ProxySettings(
              proxyRules: [
                inapp.ProxyRule(
                  url: 'http://${relay.host}:${relay.port}',
                  // The fields, not URL userinfo: toProxyConfiguration builds
                  // its endpoint from URL.host/port and drops userinfo, so
                  // only these reach applyCredential (PROXY-025).
                  username: relayUser,
                  password: relayToken,
                  allowFailover: false,
                )
              ],
              bypassRules: [],
            ),
          ),
          onWebViewCreated: (c) => paneC = c,
        ),
      );

  bool usable() {
    if (!applies) {
      markTestSkipped('the per-WebView proxy is an Apple path');
      return false;
    }
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
      home: Scaffold(
        body: Column(children: [pane(0, socksIndex: 0), paneConnect()]),
      ),
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
        'connect-baseline',
        'connect-2nd-nav',
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
      // Back to the very origin that was just proxied, so host, port,
      // registrable domain and storage policy are identical to the load that
      // WAS proxied. The arrival is attributed by peer port, not by a new
      // CONNECT: a navigation served over the connection the first load
      // opened is still a proxied one, and counting CONNECTs would have
      // called it a bypass.
      final hitsBefore = arrivalsFor(0);
      await tester.runAsync(() async {
        await controller!.loadUrl(
            urlRequest: inapp.URLRequest(url: inapp.WebUri(urlFor(0))));
      });
      await waitReal(
          tester,
          () => arrivalsFor(0) > hitsBefore,
          label: 'pane A second navigation (identical origin)');
      final hitsAfter = arrivalsFor(0);
      if (hitsAfter <= hitsBefore) {
        // Nothing routes to a synthetic destination, so a second navigation
        // that did not arrive at a fixture went direct and failed. With
        // allowFailover pinned false that is also what a dropped
        // configuration looks like, and the two are the same reading here.
        verdict['same-store-2nd-nav'] = 'DIRECT-or-failed';
      } else {
        verdict['same-store-2nd-nav'] = lastCircuit(0) == 0
            ? 'own'
            : 'CROSSED(socks${lastCircuit(0)})';
      }
      log('pane A destination-0 arrivals before=$hitsBefore after=$hitsAfter '
          'socks0 served=${socks[0].servedSynthetic}');
      log('same-store-2nd-nav=${verdict["same-store-2nd-nav"]}');

      // The same sequence on the other delivery route, in this same
      // process and frame, so the only thing that differs from pane A is
      // whether the rule is a CONNECT one.
      await waitReal(tester, () => settled(4), label: 'frame-1 pane C');
      verdict['connect-baseline'] = classify(4, 4);
      if (verdict['connect-baseline'] == 'own') {
        final hitsBeforeC = arrivalsFor(4);
        await tester.runAsync(() async {
          await paneC!.loadUrl(
              urlRequest: inapp.URLRequest(url: inapp.WebUri(urlFor(4))));
        });
        await waitReal(
            tester,
            () => arrivalsFor(4) > hitsBeforeC,
            label: 'pane C second navigation (identical origin, CONNECT)');
        final hitsAfterC = arrivalsFor(4);
        if (hitsAfterC <= hitsBeforeC) {
          verdict['connect-2nd-nav'] = 'DIRECT-or-failed';
        } else {
          verdict['connect-2nd-nav'] = lastCircuit(4) == 4
              ? 'own'
              : 'CROSSED(socks${lastCircuit(4)})';
        }
      } else {
        verdict['connect-2nd-nav'] = 'void';
      }
      log('connect-baseline=${verdict["connect-baseline"]} '
          'connect-2nd-nav=${verdict["connect-2nd-nav"]}');

      // A brand-new store in a later frame. Pane A stays in the tree so its
      // WebView is not torn down under the new one.
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(children: [
            pane(0, socksIndex: 0, url: urlFor(1)),
            paneConnect(),
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
            paneConnect(),
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
