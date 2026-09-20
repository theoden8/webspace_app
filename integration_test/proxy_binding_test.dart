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
// The assertion is the origin's own view: a site whose proxy cannot be
// reached must not arrive at the origin. A direct load is exactly what a
// dropped binding produces, and the fixture server sees it.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/settings/proxy.dart';
import 'fixture_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final applies = hostIsIOS || hostIsMacOS;

  late HttpServer server;
  late int port;
  late int deadPort;
  final requests = <String>[];

  void log(String m) {
    // ignore: avoid_print
    print('[proxy-binding] $m');
  }

  setUpAll(() async {
    await PlatformInfo.initialize();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    listenFixture(server, (req) async {
      requests.add(req.uri.path);
      final res = req.response..headers.contentType = ContentType.html;
      res.write('<!doctype html><html><body><p>origin</p></body></html>');
      await res.close();
    });
    // Claimed, then released: a connection there is refused rather than
    // filtered, so a bound proxy fails fast instead of timing out.
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    deadPort = probe.port;
    await probe.close();
    log('origin on $port, dead proxy on $deadPort, '
        'proxySupported=${PlatformInfo.isProxySupported}');
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  setUp(requests.clear);

  Future<void> mount(
    WidgetTester tester, {
    required String siteId,
    required String initialUrl,
    UserProxySettings? proxySettings,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 320,
            height: 480,
            child: WebViewFactory.createWebView(
              config: WebViewConfig(
                siteId: siteId,
                initialUrl: initialUrl,
                proxySettings: proxySettings,
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

  // Ordering is not cosmetic. Both cases below live in one app process, and
  // a proxy assigned to a `WKWebsiteDataStore` whose session has already
  // carried a load does not take effect there (BUG-014) -- so a control that
  // loads first defeats the assertion it exists to support, which is what it
  // did until this was reordered. The proxied case therefore runs first, on
  // the process's first WebView and a store of its own, and the control runs
  // after. The control's meaning is unchanged by the order: it says the
  // fixture can see a load at all.
  testWidgets('a site whose proxy is refused never reaches the origin',
      (tester) async {
    if (!applies) {
      markTestSkipped('per-WebView proxy binding is an Apple path');
      return;
    }
    if (!PlatformInfo.isProxySupported) {
      // Below iOS 17 / macOS 14 the app blanks the load instead
      // (`proxyUnavailable`), which is a different contract with its own
      // coverage.
      markTestSkipped('below the proxyConfigurations floor');
      return;
    }
    await mount(
      tester,
      siteId: 'proxy-binding-proxied',
      initialUrl: 'http://127.0.0.1:$port/proxied',
      proxySettings: UserProxySettings(
        type: ProxyType.SOCKS5,
        address: '127.0.0.1:$deadPort',
      ),
    );
    // Long enough for a direct load to have happened many times over; the
    // proxied one cannot succeed at all.
    await waitReal(tester, () => requests.contains('/proxied'),
        label: 'proxied load (must not arrive)',
        timeout: const Duration(seconds: 15));
    expect(
      requests,
      isNot(contains('/proxied')),
      reason: 'the request reached the origin directly: the per-site proxy '
          'was not bound to the engine, so every proxied site is loading '
          'over the device IP',
    );
  });

  testWidgets('the harness can see a load reach the origin', (tester) async {
    // The control. Without it, the assertion above passes for any reason a
    // page fails to load, which is most of them.
    if (!applies) {
      markTestSkipped('per-WebView proxy binding is an Apple path');
      return;
    }
    await mount(tester,
        siteId: 'proxy-binding-control',
        initialUrl: 'http://127.0.0.1:$port/control');
    expect(
      await waitReal(tester, () => requests.contains('/control'),
          label: 'direct load'),
      isTrue,
      reason: 'an unproxied site never reached the fixture origin, so this '
          'file cannot tell a bound proxy from a broken harness',
    );
  });
}
