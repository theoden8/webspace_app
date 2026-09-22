// The per-site proxy's regression test: does a proxied site's traffic go
// through its own proxy, on its first load and on everything after it?
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
import 'package:webspace/settings/proxy.dart';
import 'socks5_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final applies = hostIsIOS || hostIsMacOS;

  // One destination per navigation: a second load to the same one could ride
  // the first connection and read as "no proxy was asked for".
  const landingDest = 0;
  const inPageDest = 1;
  const loadUrlDest = 2;
  const pairADest = 3;
  const pairBDest = 4;
  const controlDest = 5;
  const seamDest = 6;

  late Socks5Fixture socks;
  late Socks5Fixture altSocks;
  var containers = false;
  final verdict = <String>[];

  void log(String m) {
    // ignore: avoid_print
    print('[proxy-binding] $m');
  }

  setUpAll(() async {
    if (!applies) return;
    await PlatformInfo.initialize();
    // The app resolves this at startup and every proxied site it builds has a
    // container as a result. Without it each WebView gets
    // `WKWebsiteDataStore.default()`, a process singleton the app never uses
    // for a proxied site.
    containers = await ContainerNative.instance.isSupported();
    socks = await Socks5Fixture.bind();
    altSocks = await Socks5Fixture.bind();

    // The landing page navigates itself away, because a navigation the PAGE
    // issues and one Dart issues through the controller are different code
    // paths in WebKit and a user only ever produces the first.
    String? body(String host, String path) => host == syntheticOrigin(landingDest)
        ? '<!doctype html><html><body><p>landing</p><script>'
            'setTimeout(function(){'
            "location.href='http://${syntheticOrigin(inPageDest)}/p';"
            '},1500);</script></body></html>'
        : null;
    socks.syntheticBody = body;
    altSocks.syntheticBody = body;

    log('socks=${socks.port} alt=${altSocks.port} '
        'proxySupported=${PlatformInfo.isProxySupported} '
        'containers=$containers');
  });

  tearDownAll(() async {
    if (!applies) return;
    log('socks connects=${socks.targets} alt connects=${altSocks.targets}');
    log('verdict: containers=$containers, ${verdict.join(", ")}');
    await socks.close();
    await altSocks.close();
  });

  bool usable() {
    if (!applies) {
      markTestSkipped('per-WebView proxy binding is an Apple path');
      return false;
    }
    expect(PlatformInfo.isProxySupported, isTrue,
        reason: 'proxy support reads unavailable past the floor; '
            'PlatformInfo.initialize() was most likely not awaited');
    return true;
  }

  var generation = 0;
  WebViewController? controller;

  Future<void> mount(
    WidgetTester tester, {
    required String? siteId,
    required int dest,
    required String path,
    UserProxySettings? proxySettings,
  }) async {
    // A fresh key per mount. Without it the second mount updates the existing
    // InAppWebView element, which keeps the platform view it already had and
    // never issues the new initial load.
    final key = ValueKey('webview-${generation++}');
    controller = null;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 320,
            height: 480,
            child: KeyedSubtree(
              key: key,
              child: WebViewFactory.createWebView(
                config: WebViewConfig(
                  siteId: siteId,
                  initialUrl: 'http://${syntheticOrigin(dest)}$path',
                  proxySettings: proxySettings,
                  clearUrlEnabled: false,
                  dnsBlockEnabled: false,
                  contentBlockEnabled: false,
                  trackingProtectionEnabled: false,
                  localCdnEnabled: false,
                ),
                onControllerCreated: (c) => controller = c,
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));
  }

  UserProxySettings liveProxy() =>
      UserProxySettings(type: ProxyType.SOCKS5, address: '127.0.0.1:${socks.port}');
  UserProxySettings altProxy() =>
      UserProxySettings(type: ProxyType.SOCKS5, address: '127.0.0.1:${altSocks.port}');

  bool saw(Socks5Fixture f, int dest) =>
      f.targets.any((t) => t.startsWith('${syntheticOrigin(dest)}:'));

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

  testWidgets('a proxied site keeps its proxy past the landing page',
      (tester) async {
    if (!usable()) return;

    await mount(tester,
        siteId: 'proxy-binding-landing',
        dest: landingDest,
        path: '/landing',
        proxySettings: liveProxy());
    final landed = await waitReal(tester, () => saw(socks, landingDest),
        label: 'landing page');
    verdict.add('landing=${landed ? "proxied" : "DIRECT-or-failed"}');
    expect(landed, isTrue,
        reason: 'the landing page of a proxied site did not go through its '
            'proxy, so nothing else in this file holds');

    // The page follows its own link, which is what a user produces.
    final inPage = await waitReal(tester, () => saw(socks, inPageDest),
        label: 'in-page navigation', timeout: const Duration(seconds: 25));
    verdict.add('in-page=${inPage ? "proxied" : "DIRECT-or-failed"}');
    expect(inPage, isTrue,
        reason: 'a site that used its proxy for its landing page went direct '
            'when its own page followed a link, so the binding covers one '
            'load and the site leaks on everything the user clicks');

    // The same second navigation, issued from Dart instead.
    expect(await waitReal(tester, () => controller != null,
        label: 'controller created'), isTrue);
    await tester.runAsync(() async {
      await controller!.nativeController.loadUrl(
        urlRequest: inapp.URLRequest(
            url: inapp.WebUri('http://${syntheticOrigin(loadUrlDest)}/d')),
      );
    });
    final viaLoadUrl = await waitReal(tester, () => saw(socks, loadUrlDest),
        label: 'loadUrl navigation');
    verdict.add('loadurl=${viaLoadUrl ? "proxied" : "DIRECT-or-failed"}');
    expect(viaLoadUrl, isTrue,
        reason: 'the same second navigation, issued from Dart, went direct');
  });

  testWidgets('two proxied sites reach their own proxies, not each other\'s',
      (tester) async {
    if (!usable()) return;

    await mount(tester,
        siteId: 'proxy-binding-pair-a',
        dest: pairADest,
        path: '/pair-a',
        proxySettings: liveProxy());
    await mount(tester,
        siteId: 'proxy-binding-pair-b',
        dest: pairBDest,
        path: '/pair-b',
        proxySettings: altProxy());

    await waitReal(tester, () => saw(socks, pairADest) && saw(altSocks, pairBDest),
        label: 'both panes settled', timeout: const Duration(seconds: 30));

    final a = saw(socks, pairADest);
    final b = saw(altSocks, pairBDest);
    final crossed = saw(altSocks, pairADest) || saw(socks, pairBDest);
    verdict.add('pair=a:${a ? "own" : "no"} b:${b ? "own" : "no"} '
        'crossed=$crossed');

    expect(crossed, isFalse,
        reason: 'a site reached another site\'s proxy, which is worse than '
            'going direct: its traffic carried the wrong identity');
    expect(a && b, isTrue,
        reason: 'two sites with different proxies must each use its own');
  });

  testWidgets('the engine received the proxy Dart sent it', (tester) async {
    // The original instance of this bug: `proxySettings` was typed
    // `[String: Any?]?`, which Objective-C cannot represent, so the plugin's
    // reflective settings parser skipped it and no per-site proxy was ever
    // applied. Nothing failed.
    //
    // `getSettings()` asks the engine what it holds, which splits the seam the
    // load-level scenarios only see the far side of: null means the field
    // never crossed the channel, non-null means it crossed and was not
    // applied. Different bugs.
    if (!usable()) return;
    await mount(tester,
        siteId: 'proxy-binding-seam',
        dest: seamDest,
        path: '/seam',
        proxySettings: liveProxy());
    expect(await waitReal(tester, () => controller != null,
        label: 'controller created'), isTrue);
    inapp.InAppWebViewSettings? live;
    await tester.runAsync(() async {
      live = await controller!.nativeController.getSettings();
    });
    log('native settings: proxySettings=${live?.proxySettings}');
    expect(live, isNotNull, reason: 'the engine reported no settings at all');
    expect(live?.proxySettings?.proxyRules, isNotEmpty,
        reason: 'the engine holds no proxy: the field did not survive the '
            'platform channel, so nothing downstream could have applied it');
  });

  testWidgets('the harness can see a load that was NOT proxied', (tester) async {
    // The control. Without it every assertion above passes for any reason a
    // page fails to load, which is most of them: an unproxied site must reach
    // no fixture, and a proxied one must.
    if (!usable()) return;
    await mount(tester, siteId: 'proxy-binding-control', dest: controlDest,
        path: '/control');
    await waitReal(tester, () => false,
        label: 'unproxied settle window',
        timeout: const Duration(seconds: 5));
    expect(saw(socks, controlDest) || saw(altSocks, controlDest), isFalse,
        reason: 'a site with no proxy reached a proxy fixture, so this file '
            'cannot tell a bound proxy from a fixture that sees everything');
  });

  testWidgets('fail-closed: a refused proxy must not leak to the origin',
      (tester) async {
    // BUG-014 gap 2. Answering this needs a destination that is BOTH proxyable
    // (so not an address this machine owns, which is never proxied) and
    // observable when reached directly (so not a synthetic destination, which
    // nothing routes to). No single machine can be both, so this arm waits on
    // the CI service-container origin rather than asserting something it
    // cannot see.
    if (!usable()) return;
    markTestSkipped(
      'fail-closed needs an origin on a second host; see docs/bugs/'
      '014-per-site-setting-dropped-at-the-native-seam.md gap 2',
    );
    verdict.add('fail-closed=not attempted (gap 2)');
  });
}
