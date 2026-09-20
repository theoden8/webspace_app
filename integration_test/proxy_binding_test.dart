// The per-site proxy actually governs what leaves the engine (LEAK-003,
// PROXY-011, PROXY-020).
//
// Everything else about the per-site proxy is decided in Dart and tested
// there: which proxy a site resolves to, whether a Tor site waits for the
// runtime, whether a malformed address fails closed. None of that can see
// the one thing that matters -- whether the engine honoured the proxy at
// all. A dropped proxy is silent: the Dart side reports one, the page loads
// over the device IP, and only the site being visited can tell.
//
// Under PROXY-020 the delivery on Apple is the process-wide override
// (`ProxyController.setProxyOverride`), which the fork fans out across the
// default store, the non-persistent store and every cached container store,
// replaying it onto stores created later. The per-store `proxySettings`
// field is developer-mode only, so a WebView built here carries none and
// the override is the only thing that can route the load. This file applies
// the override itself, the way an activation's `_applyProxySettings` does.
//
// Three rules this file learned the hard way, each of which made it pass or
// fail for reasons that had nothing to do with the binding:
//
//  * The origin must not be on loopback. Apple never sends `localhost`,
//    `127.0.0.1` or `::1` through a proxy whatever `ProxyConfiguration`
//    says, so a loopback fixture loads directly whichever way the binding
//    went. BUG-014 attempt 4 established this; the branch trim reverted the
//    fix and attempts 73 and 74 then read a loopback origin as evidence.
//  * A second webview needs its own subtree key. Pumping the same widget
//    position again updates the existing platform view instead of building
//    a new one, so the second load is never issued and "the origin was not
//    reached" holds for free.
//  * The assertion must be positive. A refused proxy only ever supports
//    "the origin was not reached", which any broken load satisfies -- and
//    every way this file has been wrong so far broke the load.
//
// So the proxy here is a live SOCKS5 server that records the CONNECT it is
// asked for. A recorded CONNECT to the origin cannot be produced by an
// override that was dropped.
//
// Two proxied arms, not one. The first is the process's first proxied load,
// which is the arrangement most likely to bind (BUG-014). The second is the
// one PROXY-008 serialisation actually produces on every site switch: a
// container store created later, taking a *different* proxy, while the
// first store is alive and has already loaded through its own. Under the
// per-store API that second store never took a proxy (attempt 72); whether
// the process-wide fan-out reaches it is the question that decides whether
// PROXY-020 holds for anything past a session's first proxied site.

import 'dart:io';

import 'package:flutter/material.dart';
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

  // One origin per arm, on its own port. The fixture records CONNECT by
  // `host:port`, so a separate origin is what makes a recorded CONNECT
  // attributable to the arm that caused it; two loads to one origin can
  // also share a connection, which reads as a CONNECT that never happened.
  late HttpServer proxiedOrigin;
  late HttpServer switchedOrigin;
  late HttpServer controlOrigin;
  late int proxiedPort;
  late int switchedPort;
  late int controlPort;
  late String originHost;
  InternetAddress? routable;
  late Socks5Fixture socks;
  // A second proxy, so the switched arm can distinguish "went through the
  // new proxy" from "still going through the old one" -- which one fixture
  // cannot tell apart, and which is the difference between a working switch
  // and a site riding its predecessor's circuit.
  late Socks5Fixture altSocks;
  final requests = <String>[];

  void log(String m) {
    // ignore: avoid_print
    print('[proxy-binding] $m');
  }

  var containers = false;

  Future<HttpServer> serveOrigin(String label) async {
    // anyIPv4, not loopbackIPv4: the WebView reaches this through the
    // routable interface address, which a loopback-bound socket does not
    // answer on.
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    listenFixture(server, (req) async {
      requests.add(req.uri.path);
      final res = req.response..headers.contentType = ContentType.html;
      res.write('<!doctype html><html><body><p>$label</p></body></html>');
      await res.close();
    });
    return server;
  }

  setUpAll(() async {
    await PlatformInfo.initialize();
    // The app resolves this at startup, and every site it builds gets a
    // container of its own as a result. Without it `cachedSupported` is
    // false, `siteOwnsContainerProfile` returns false, no containerId is
    // sent, and the fork falls through to `WKWebsiteDataStore.default()` --
    // a store shape the app does not use for sites.
    containers = await ContainerNative.instance.isSupported();
    routable = await nonLoopbackIPv4();
    socks = await Socks5Fixture.bind();
    altSocks = await Socks5Fixture.bind();
    proxiedOrigin = await serveOrigin('proxied');
    switchedOrigin = await serveOrigin('switched');
    controlOrigin = await serveOrigin('control');
    proxiedPort = proxiedOrigin.port;
    switchedPort = switchedOrigin.port;
    controlPort = controlOrigin.port;
    originHost = (routable ?? InternetAddress.loopbackIPv4).address;
    log('origin host $originHost, proxied on $proxiedPort, '
        'switched on $switchedPort, control on $controlPort, '
        'socks on ${socks.port}, altSocks on ${altSocks.port}, '
        'proxySupported=${PlatformInfo.isProxySupported} '
        'containers=$containers');
  });

  tearDownAll(() async {
    await socks.close();
    await altSocks.close();
    await proxiedOrigin.close(force: true);
    await switchedOrigin.close(force: true);
    await controlOrigin.close(force: true);
  });

  setUp(requests.clear);

  Future<void> mount(
    WidgetTester tester, {
    required String siteId,
    required String initialUrl,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 320,
            height: 480,
            // Keyed by siteId: without it the second arm reuses the first
            // arm's platform view and never issues its load.
            child: KeyedSubtree(
              key: ValueKey('webview-$siteId'),
              child: WebViewFactory.createWebView(
                config: WebViewConfig(
                  siteId: siteId,
                  initialUrl: initialUrl,
                  clearUrlEnabled: false,
                  dnsBlockEnabled: false,
                  contentBlockEnabled: false,
                  trackingProtectionEnabled: false,
                  localCdnEnabled: false,
                ),
                onControllerCreated: (_) {},
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));
  }

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

  /// Put [settings] in force process-wide, the way `_applyProxySettings`
  /// does on a real activation.
  Future<void> applyOverride(UserProxySettings settings) =>
      ProxyManager().setProxySettings(settings);

  bool skipUnlessMeasurable() {
    if (!applies) {
      markTestSkipped('this file covers the Apple proxy delivery');
      return true;
    }
    if (!PlatformInfo.isProxySupported) {
      // Below iOS 17 / macOS 14 the app blanks the load instead
      // (`proxyUnavailable`), which is a different contract with its own
      // coverage.
      markTestSkipped('below the proxyConfigurations floor');
      return true;
    }
    if (routable == null) {
      // Not a pass. A loopback origin is never proxied on Apple, so with no
      // routable interface this file cannot tell a bound proxy from a
      // dropped one and must not claim to have.
      markTestSkipped('no non-loopback IPv4 interface to serve the origin on');
      return true;
    }
    return false;
  }

  // The proxied arm runs first, on the process's first WebView: only the
  // first store in a process has ever been observed to carry a proxy
  // (BUG-014), so putting the arm that must be proxied anywhere else would
  // assert against a store that cannot be.
  testWidgets('a proxied site reaches its origin through the proxy',
      (tester) async {
    if (skipUnlessMeasurable()) return;
    await applyOverride(UserProxySettings(
      type: ProxyType.SOCKS5,
      address: '127.0.0.1:${socks.port}',
    ));
    await mount(
      tester,
      siteId: 'proxy-binding-proxied',
      initialUrl: 'http://$originHost:$proxiedPort/proxied',
    );
    final target = '$originHost:$proxiedPort';
    await waitReal(tester, () => socks.targets.contains(target),
        label: 'proxied load (must arrive at the proxy)');
    expect(
      socks.targets,
      contains(target),
      reason: 'the proxy was never asked for the origin, so the process-wide '
          'override did not reach the load: every proxied site is going out '
          'over the device IP. Origin saw: $requests',
    );
  });

  // The arrangement a site switch produces: the first store is alive and
  // has loaded through its own proxy, the override flips, and a second
  // container store is created under the new one. If this fails while the
  // arm above passes, only a session's first proxied site is protected and
  // every switch after it goes out over the device IP.
  testWidgets('a second site switched to another proxy uses the new one',
      (tester) async {
    if (skipUnlessMeasurable()) return;
    await applyOverride(UserProxySettings(
      type: ProxyType.SOCKS5,
      address: '127.0.0.1:${altSocks.port}',
    ));
    await mount(
      tester,
      siteId: 'proxy-binding-switched',
      initialUrl: 'http://$originHost:$switchedPort/switched',
    );
    final target = '$originHost:$switchedPort';
    await waitReal(tester, () => altSocks.targets.contains(target),
        label: 'switched load (must arrive at the new proxy)');
    expect(
      altSocks.targets,
      contains(target),
      reason: 'the second site never reached the proxy it was switched to. '
          'Either it went direct, or it is still on the first proxy '
          '(first proxy saw: ${socks.targets}). Under PROXY-008 the override '
          'flips on every activation, so this is every site switch after the '
          "session's first proxied load. Origin saw: $requests",
    );
    expect(
      socks.targets,
      isNot(contains(target)),
      reason: "the second site's traffic left through the first site's "
          'proxy, which is worse than no proxy at all: it attributes one '
          "site's browsing to another's circuit",
    );
  });

  testWidgets('an unproxied site reaches the origin and not the proxy',
      (tester) async {
    // The control. Without it the assertion above fails for any reason a
    // page fails to load, which is most of them, and passes for any reason
    // the fixture records a stray CONNECT.
    if (skipUnlessMeasurable()) return;
    await applyOverride(UserProxySettings(type: ProxyType.DEFAULT));
    final before = List<String>.of(socks.targets);
    final altBefore = List<String>.of(altSocks.targets);
    await mount(tester,
        siteId: 'proxy-binding-control',
        initialUrl: 'http://$originHost:$controlPort/control');
    expect(
      await waitReal(tester, () => requests.contains('/control'),
          label: 'direct load'),
      isTrue,
      reason: 'an unproxied site never reached the fixture origin, so this '
          'file cannot tell an honoured override from a broken harness',
    );
    expect(
      [
        ...socks.targets.sublist(before.length),
        ...altSocks.targets.sublist(altBefore.length),
      ],
      isNot(contains('$originHost:$controlPort')),
      reason: 'a site with no proxy in force still went through a proxy '
          'fixture, so the arms above prove nothing about the override',
    );
  });
}
