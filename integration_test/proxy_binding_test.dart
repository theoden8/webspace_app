// The per-site proxy is actually bound to the engine (LEAK-003, PROXY-011).
//
// Everything else about the per-site proxy is decided in Dart and tested
// there: which proxy a site resolves to, whether a Tor site waits for the
// runtime, whether a malformed address fails closed. None of that can see
// the one thing that matters -- whether the engine received the proxy at
// all. On iOS and macOS it is delivered as one field on
// `InAppWebViewSettings`, parsed natively, and a parse that drops it is
// silent: the Dart side reports a proxy, the page loads over the device IP,
// and only the site being visited can tell the difference.
//
// That is not hypothetical. `proxySettings` was typed `[String: Any?]?`,
// which Objective-C cannot represent, so the plugin's reflective settings
// parser skipped it and no per-site proxy was ever applied on either Apple
// platform.
//
// Two rules this file learned the hard way, both of which made it pass while
// no proxy was bound at all:
//
//  * The origin must not be on loopback. Apple never proxies `127.0.0.1`,
//    so a loopback fixture loads directly whichever way the binding went.
//  * A second webview for the same site needs its own subtree key. Pumping
//    the same widget position again updates the existing platform view
//    instead of building a new one, so the second load is never issued and
//    "the origin was not reached" holds for free.
//
// So the assertions here are positive wherever they can be: the fixture
// SOCKS5 server must have been asked for the origin. A negative ("the
// origin was not reached") is satisfied by any broken load, and every way
// this file has been wrong so far broke the load.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/container_native.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/settings/proxy.dart';
import 'fixture_server.dart';
import 'socks5_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final applies = hostIsIOS || hostIsMacOS;

  late HttpServer server;
  late String originHost;
  late int port;
  late int deadPort;
  late Socks5Fixture socks;
  InternetAddress? routable;
  final requests = <String>[];

  void log(String m) {
    // ignore: avoid_print
    print('[proxy-binding] $m');
  }

  var containers = false;

  setUpAll(() async {
    await PlatformInfo.initialize();
    // The app resolves this at startup and every proxied site it builds has
    // a container of its own as a result. Without it here each WebView got
    // `WKWebsiteDataStore.default()` instead -- a process singleton that the
    // first load puts into service -- so this file was measuring a store
    // shape the app never uses.
    containers = await ContainerNative.instance.isSupported();
    routable = await nonLoopbackIPv4();
    server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    port = server.port;
    originHost = (routable ?? InternetAddress.loopbackIPv4).address;
    listenFixture(server, (req) async {
      requests.add(req.uri.path);
      final res = req.response..headers.contentType = ContentType.html;
      res.write('<!doctype html><html><body><p>origin</p></body></html>');
      await res.close();
    });
    socks = await Socks5Fixture.bind();
    // Claimed, then released: a connection there is refused rather than
    // filtered, so a bound proxy fails fast instead of timing out.
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    deadPort = probe.port;
    await probe.close();
    log('origin on $originHost:$port, socks on ${socks.port}, '
        'dead proxy on $deadPort, '
        'proxySupported=${PlatformInfo.isProxySupported} '
        'containers=$containers');
  });

  /// Which scenarios saw the proxy, in one line at the end of the file's
  /// output. The tier re-prints only the last 60 lines of a failing file, and
  /// twice now the scenario that decided the diagnosis was further back than
  /// that -- leaving the verdict to be inferred from a pass/fail count.
  final verdict = <String>[];

  tearDownAll(() async {
    log('verdict: containers=$containers, ${verdict.join(", ")}');
    await socks.close();
    await server.close(force: true);
  });

  setUp(() {
    requests.clear();
    socks.targets.clear();
  });

  /// Skips off-Apple, and fails rather than skips when the environment
  /// cannot host the assertion. A silent skip is how this file spent its
  /// whole life reporting green over an unbound proxy.
  bool usable() {
    if (!applies) {
      markTestSkipped('per-WebView proxy binding is an Apple path');
      return false;
    }
    expect(
      routable,
      isNotNull,
      reason: 'no non-loopback IPv4 on this machine, and Apple never sends a '
          'loopback destination through a proxy, so nothing here could '
          'distinguish a bound proxy from an unbound one',
    );
    return true;
  }

  var generation = 0;
  WebViewController? controller;

  Future<void> mount(
    WidgetTester tester, {
    required String siteId,
    required String path,
    UserProxySettings? proxySettings,
  }) async {
    // A fresh key per mount. Without it the second mount updates the
    // existing InAppWebView element, which keeps the platform view it
    // already had and never issues the new initial load.
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
                  initialUrl: 'http://$originHost:$port$path',
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

  UserProxySettings liveProxy() => UserProxySettings(
        type: ProxyType.SOCKS5,
        address: '127.0.0.1:${socks.port}',
      );

  UserProxySettings refusedProxy() => UserProxySettings(
        type: ProxyType.SOCKS5,
        address: '127.0.0.1:$deadPort',
      );

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

  testWidgets('the very first webview in the process honours its proxy',
      (tester) async {
    // First, deliberately, and that is the whole point. Without a container
    // id every WebView here gets `WKWebsiteDataStore.default()`, which is a
    // process singleton, and Apple's `proxyConfigurations` is documented to
    // apply to a store before it is used for network loads. If this passes
    // while the identical fresh-site scenario below fails, the difference is
    // not the site and not the proxy: it is that by then the store has
    // already served a load, and the assignment was ignored.
    //
    // That is also the shape of the report this file exists for: a site that
    // loads once without a proxy keeps loading without one until the app is
    // restarted.
    if (!usable()) return;
    if (!PlatformInfo.isProxySupported) {
      markTestSkipped('below the proxyConfigurations floor');
      return;
    }
    await mount(
      tester,
      siteId: 'proxy-binding-first',
      path: '/first-in-process',
      proxySettings: liveProxy(),
    );
    final used = await waitReal(tester, () => socks.targets.isNotEmpty,
        label: 'first-in-process proxied load');
    verdict.add('first-in-process=${used ? "proxied" : "DIRECT"}');
    expect(
      used,
      isTrue,
      reason: 'even the first WebView in this process did not use its proxy, '
          'so the binding is broken outright rather than only stale on a '
          'store that has already been used',
    );
    expect(socks.targets.first, '$originHost:$port');
  });

  testWidgets('the harness can see a load reach the origin', (tester) async {
    // The control. Without it, the assertions below pass for any reason a
    // page fails to load, which is most of them.
    if (!usable()) return;
    await mount(tester, siteId: 'proxy-binding-control', path: '/control');
    expect(
      await waitReal(tester, () => requests.contains('/control'),
          label: 'direct load'),
      isTrue,
      reason: 'an unproxied site never reached the fixture origin, so this '
          'file cannot tell a bound proxy from a broken harness',
    );
    expect(socks.targets, isEmpty,
        reason: 'an unproxied site went through the fixture proxy');
  });

  testWidgets("a fresh site's first webview loads through its proxy",
      (tester) async {
    if (!usable()) return;
    if (!PlatformInfo.isProxySupported) {
      // Below iOS 17 / macOS 14 the app blanks the load instead
      // (`proxyUnavailable`), which is a different contract with its own
      // coverage.
      markTestSkipped('below the proxyConfigurations floor');
      return;
    }
    await mount(
      tester,
      // Its own site, so the container store this webview gets has never
      // served a load: binding at construction is what this asserts, and
      // re-binding a store that is already in use is the scenario below.
      siteId: 'proxy-binding-fresh',
      path: '/proxied',
      proxySettings: liveProxy(),
    );
    final freshUsed = await waitReal(tester, () => socks.targets.isNotEmpty,
        label: 'proxied load (must arrive at the proxy)');
    verdict.add('fresh-site=${freshUsed ? "proxied" : "DIRECT"}');
    expect(
      freshUsed,
      isTrue,
      reason: 'the fixture proxy was never asked for anything: the per-site '
          'proxy was not bound to the engine, so every proxied site is '
          'loading over the device IP',
    );
    expect(socks.targets.first, '$originHost:$port');
    expect(
      await waitReal(tester, () => requests.contains('/proxied'),
          label: 'proxied load (relayed to the origin)'),
      isTrue,
    );
  });

  testWidgets('the engine received the proxy Dart sent it', (tester) async {
    // Splits the seam the other scenarios can only see the far side of. The
    // proxy is one field on `InAppWebViewSettings`, delivered over a method
    // channel and parsed reflectively; `getSettings()` asks the engine what
    // it actually holds. A null here means the field never crossed, which is
    // a different bug from a field that crossed and was not applied -- and
    // the load-level assertions cannot tell them apart.
    if (!usable()) return;
    if (!PlatformInfo.isProxySupported) {
      markTestSkipped('below the proxyConfigurations floor');
      return;
    }
    await mount(
      tester,
      siteId: 'proxy-binding-seam',
      path: '/seam',
      proxySettings: liveProxy(),
    );
    expect(await waitReal(tester, () => controller != null,
            label: 'controller created'),
        isTrue);
    inapp.InAppWebViewSettings? live;
    await tester.runAsync(() async {
      live = await controller!.nativeController.getSettings();
    });
    log('native settings: proxySettings=${live?.proxySettings}');
    expect(live, isNotNull, reason: 'the engine reported no settings at all');
    expect(
      live?.proxySettings?.proxyRules,
      isNotEmpty,
      reason: 'the engine holds no proxy: the field did not survive the '
          'platform channel, so nothing downstream could have applied it',
    );
  });

  testWidgets('a site whose proxy is refused never reaches the origin',
      (tester) async {
    if (!usable()) return;
    if (!PlatformInfo.isProxySupported) {
      markTestSkipped('below the proxyConfigurations floor');
      return;
    }
    await mount(
      tester,
      siteId: 'proxy-binding-refused',
      path: '/refused',
      proxySettings: refusedProxy(),
    );
    // Long enough for a direct load to have happened many times over; the
    // proxied one cannot succeed at all.
    await waitReal(tester, () => requests.contains('/refused'),
        label: 'refused load (must not arrive)',
        timeout: const Duration(seconds: 15));
    verdict.add(
        'refused=${requests.contains('/refused') ? "DIRECT" : "failed closed"}');
    expect(
      requests,
      isNot(contains('/refused')),
      reason: 'the request reached the origin directly: a proxy that cannot '
          'be connected to fell back to the device IP instead of failing '
          'the load',
    );
  });

  testWidgets('a site that gains a proxy stops going direct', (tester) async {
    // The reported symptom: "sometimes I have to restart the app for the Tor
    // proxy to start working". A site's container data store outlives its
    // webview -- the plugin caches one per container for the process -- so
    // the proxy for a second webview is assigned to a store that has already
    // served a load. If that assignment does not take, the only thing that
    // ever binds a proxy is the first webview a site gets, and restarting
    // the app is the only way to change it.
    if (!usable()) return;
    if (!PlatformInfo.isProxySupported) {
      markTestSkipped('below the proxyConfigurations floor');
      return;
    }
    const siteId = 'proxy-binding-rebind';
    await mount(tester, siteId: siteId, path: '/first');
    expect(
      await waitReal(tester, () => requests.contains('/first'),
          label: 'unproxied first load'),
      isTrue,
      reason: 'the site never loaded at all, so the rebind below proves '
          'nothing',
    );

    await mount(
      tester,
      siteId: siteId,
      path: '/second',
      proxySettings: liveProxy(),
    );
    final reboundUsed = await waitReal(
        tester, () => socks.targets.isNotEmpty,
        label: 'rebound load (must arrive at the proxy)');
    verdict.add('rebind=${reboundUsed ? "proxied" : "DIRECT"}');
    expect(
      reboundUsed,
      isTrue,
      reason: 'a proxy assigned to a container store that has already served '
          'a load does not take effect, so a site keeps whatever proxy its '
          'first webview was built with until the app restarts',
    );
    expect(socks.targets.last, '$originHost:$port');
    expect(
      await waitReal(tester, () => requests.contains('/second'),
          label: 'rebound load (relayed to the origin)'),
      isTrue,
    );
  });
}
