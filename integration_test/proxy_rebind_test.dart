// A site whose proxy changes while the app runs: does everything it loads
// afterwards leave through the new proxy?
//
// On Apple a container's WKWebsiteDataStore outlives the WKWebView built on
// it, and so does the store's network session: the fork caches one store per
// container for the life of the process. WebKit hands a SOCKS change to that
// live session (`NetworkSessionCocoa::setProxyConfigData`, which adds the
// proxy to the session's `nw_context`) instead of building a new session, so
// a connection the site opened on its old route can still be pooled when its
// next WebView asks the same host again. On a device, a site switched from
// direct to Tor showed the device's own address until the app was restarted.
//
// The proxies here are fixtures that keep their connections alive and record
// which tunnel served each request, so "the old route carried it" is observed
// rather than inferred from a failed load. Destinations are synthetic
// (`syntheticOrigin`), which only a fixture can answer.

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

  // Indices past the ones proxy_binding_test uses, so a stray pooled
  // connection from another file cannot answer for this one.
  const sameHostDest = 20;
  const freshHostDest = 21;
  const afterDirectDest = 22;

  late Socks5Fixture before;
  late Socks5Fixture after;
  HttpServer? loopback;
  var containers = false;
  final verdict = <String>[];

  void log(String m) {
    // ignore: avoid_print
    print('[proxy-rebind] $m');
  }

  setUpAll(() async {
    if (!applies) return;
    await PlatformInfo.initialize();
    containers = await ContainerNative.instance.isSupported();
    before = await Socks5Fixture.bind();
    after = await Socks5Fixture.bind();
    before.syntheticKeepAlive = true;
    after.syntheticKeepAlive = true;
    loopback = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    listenFixture<HttpRequest>(loopback!, (request) {
      request.response
        ..headers.contentType = ContentType.html
        ..write('<!doctype html><html><body><p>direct</p></body></html>');
      request.response.close();
    });
    log('before=${before.port} after=${after.port} '
        'loopback=${loopback!.port} containers=$containers');
  });

  tearDownAll(() async {
    if (!applies) return;
    log('before served ${before.syntheticRequests}; '
        'after served ${after.syntheticRequests}');
    log('verdict: containers=$containers, ${verdict.join(", ")}');
    await before.close();
    await after.close();
    await loopback?.close(force: true);
  });

  bool usable() {
    if (!applies) {
      markTestSkipped('per-WebView proxy binding is an Apple path');
      return false;
    }
    if (!containers) {
      // Without a container every site shares WKWebsiteDataStore.default(),
      // which is a different defect with a different fix.
      markTestSkipped('no per-site container on this OS');
      return false;
    }
    return true;
  }

  var generation = 0;
  WebViewController? controller;

  Future<void> mount(
    WidgetTester tester, {
    required String siteId,
    required String url,
    UserProxySettings? proxySettings,
  }) async {
    // A fresh key, so the old InAppWebView is disposed and a new one built,
    // which is what the app does when a site's settings are saved.
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
                  initialUrl: url,
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

  UserProxySettings via(Socks5Fixture f) =>
      UserProxySettings(type: ProxyType.SOCKS5, address: '127.0.0.1:${f.port}');

  /// Every request [f] served for `<dest><path>`, as `<tunnel> <host><path>`.
  List<String> served(Socks5Fixture f, int dest, String path) => [
        for (final r in f.syntheticRequests)
          if (r.endsWith(' ${syntheticOrigin(dest)}$path')) r,
      ];

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

  testWidgets('after a proxy change, nothing rides a connection from the old route',
      (tester) async {
    if (!usable()) return;
    const site = 'proxy-rebind-same-host';

    await mount(tester,
        siteId: site,
        url: 'http://${syntheticOrigin(sameHostDest)}/before',
        proxySettings: via(before));
    expect(
        await waitReal(tester,
            () => served(before, sameHostDest, '/before').isNotEmpty,
            label: 'first load through the first proxy'),
        isTrue,
        reason: 'the site never loaded through its first proxy, so nothing '
            'below says anything about a change');
    final beforeTunnels = before.syntheticRequests.length;

    // The same host again, on the new route, while the first route's
    // connection is still alive in the pool.
    await mount(tester,
        siteId: site,
        url: 'http://${syntheticOrigin(sameHostDest)}/after',
        proxySettings: via(after));
    await waitReal(
        tester,
        () =>
            served(after, sameHostDest, '/after').isNotEmpty ||
            served(before, sameHostDest, '/after').isNotEmpty,
        label: 'same host after the change');

    // And a host the site has never reached, from the new WebView.
    expect(await waitReal(tester, () => controller != null,
        label: 'controller created'), isTrue);
    await tester.runAsync(() async {
      await controller!.nativeController.loadUrl(
        urlRequest: inapp.URLRequest(
            url: inapp.WebUri('http://${syntheticOrigin(freshHostDest)}/fresh')),
      );
    });
    await waitReal(
        tester,
        () =>
            served(after, freshHostDest, '/fresh').isNotEmpty ||
            served(before, freshHostDest, '/fresh').isNotEmpty,
        label: 'fresh host after the change');

    final sameOld = served(before, sameHostDest, '/after');
    final sameNew = served(after, sameHostDest, '/after');
    final freshOld = served(before, freshHostDest, '/fresh');
    final freshNew = served(after, freshHostDest, '/fresh');
    final lateOnOld = before.syntheticRequests.skip(beforeTunnels).toList();
    verdict.add('same-host=${sameNew.isNotEmpty ? "new" : sameOld.isNotEmpty ? "OLD" : "none"} '
        'fresh-host=${freshNew.isNotEmpty ? "new" : freshOld.isNotEmpty ? "OLD" : "none"}');
    log('same host: old=$sameOld new=$sameNew; fresh host: old=$freshOld '
        'new=$freshNew; everything the old proxy served after the change: '
        '$lateOnOld');

    expect(sameOld, isEmpty,
        reason: 'the site\'s request after its proxy changed went out through '
            'the proxy it had before, on a connection pooled from then '
            '($sameOld). On a device this is a site switched to Tor loading '
            'from the device\'s own address.');
    expect(freshOld, isEmpty,
        reason: 'a host the site had never reached went through the old '
            'proxy, so the change was not applied at all ($freshOld)');
    expect(lateOnOld, isEmpty,
        reason: 'the old proxy kept carrying the site after the change: '
            '$lateOnOld');
    expect(sameNew, isNotEmpty,
        reason: 'the same host after the change never reached the new proxy');
    expect(freshNew, isNotEmpty,
        reason: 'a new host after the change never reached the new proxy');
  });

  testWidgets('a site that first loaded direct uses the proxy it is given',
      (tester) async {
    if (!usable()) return;
    const site = 'proxy-rebind-after-direct';

    // Loopback is never proxied, so this is the direct load a site makes
    // before the user moves it to a proxy, and it gives the container a live
    // network session with no proxy on it.
    await mount(tester,
        siteId: site, url: 'http://127.0.0.1:${loopback!.port}/direct');
    await waitReal(tester, () => false,
        label: 'direct settle window', timeout: const Duration(seconds: 3));

    await mount(tester,
        siteId: site,
        url: 'http://${syntheticOrigin(afterDirectDest)}/after',
        proxySettings: via(after));
    final reached = await waitReal(
        tester, () => served(after, afterDirectDest, '/after').isNotEmpty,
        label: 'first proxied load after a direct one');
    verdict.add('after-direct=${reached ? "proxied" : "DIRECT-or-failed"}');
    expect(reached, isTrue,
        reason: 'a site that loaded direct and was then given a proxy did not '
            'reach it: the proxy was not applied to the container\'s live '
            'session');
  });
}
