// Which shape binds a proxy, measured against the one that reliably does.
//
// Run 3098 gave every arm a positive control -- a SOCKS pane in the same
// process's own first frame -- and all three controls read DIRECT, which
// voids those arms' results. In the same run `proxy_binding` read
// `pair=2 of 2 proxied`, `raw-first=proxied`, `sameturn-loadurl=proxied`.
// Run 3097 was the same both ways. So the variable is not the frame, not the
// destination scheme and not the number of distinct proxies: it is something
// that differs between `proxy_binding`'s process and every other arm's, and
// it reproduces.
//
// Three differences are enumerable from the files, and this arm puts all
// three in one first frame so one run separates them:
//
//  A  a raw plugin webview with its proxy on `initialSettings` and its load
//     on `initialUrlRequest` -- proxy_rate's control, which read DIRECT.
//  B  the same site through `WebViewFactory.createWebView`, which is what
//     `proxy_binding`'s pair panes use and what the app itself uses.
//  C  a raw webview with no initial request, loaded by `loadUrl` from
//     `onWebViewCreated` -- proxy_binding's `sameturn` pane, which proxied.
//
// The fourth difference, setUpAll ordering, is removed rather than measured:
// this file awaits `PlatformInfo.initialize()` before asking about
// containers, the order `proxy_binding` uses and the other arms do not.
//
// One shared SOCKS5 endpoint for all three, so nothing here depends on
// whether distinct proxy configurations can coexist. Separate origins, so a
// recorded CONNECT is attributable to one pane.

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

  void log(String m) {
    // ignore: avoid_print
    print('[proxy-shape] $m');
  }

  const shapes = ['raw-initial', 'factory', 'raw-loadurl'];

  /// Where in the tier this process ran. The loop runs this file twice, once
  /// ahead of every other integration file and once in its alphabetical
  /// position, because proxy_binding -- the first proxy file the glob reaches
  /// -- is the only arm that binds and every arm behind it does not.
  final position = Platform.environment['WEBSPACE_TIER_POSITION'] ?? 'glob';

  late Socks5Fixture socks;
  final origins = <HttpServer>[];
  final ports = <int>[];
  final requests = <String>[];
  InternetAddress? routable;
  var originHost = '127.0.0.1';
  var containers = false;
  final results = <String>[];

  setUpAll(() async {
    if (!applies) return;
    // This order is the point: proxy_binding initializes PlatformInfo first
    // and is the only arm that binds.
    await PlatformInfo.initialize();
    containers = await ContainerNative.instance.isSupported();
    routable = await nonLoopbackIPv4();
    originHost = routable?.address ?? '127.0.0.1';
    socks = await Socks5Fixture.bind();

    for (var i = 0; i < shapes.length; i++) {
      final origin = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      origins.add(origin);
      ports.add(origin.port);
      listenFixture(origin, (req) async {
        requests.add('s$i:${req.uri.path}');
        final res = req.response..headers.contentType = ContentType.html;
        res.write('<!doctype html><html><body><p>s$i</p></body></html>');
        await res.close();
      });
    }
    log('position=$position, origins ${ports.join(",")} on $originHost, '
        'socks ${socks.port}, '
        'proxySupported=${PlatformInfo.isProxySupported} '
        'containers=$containers');
  });

  tearDownAll(() async {
    if (!applies) return;
    log('socks connects=${socks.targets}');
    log('verdict: containers=$containers, position=$position, '
        'shape=[${results.join(" ")}]');
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

  inapp.ProxySettings rawProxy() => inapp.ProxySettings(
        proxyRules: [inapp.ProxyRule(url: 'socks5://127.0.0.1:${socks.port}')],
        bypassRules: [],
      );

  testWidgets('three shapes, one frame, one endpoint', (tester) async {
    if (!usable()) return;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          SizedBox(
            width: 320,
            height: 110,
            child: inapp.InAppWebView(
              key: const ValueKey('shape-raw-initial'),
              initialUrlRequest: inapp.URLRequest(
                url: inapp.WebUri('http://$originHost:${ports[0]}/s0'),
              ),
              initialSettings: inapp.InAppWebViewSettings(
                containerId: 'ws-proxy-shape-0',
                proxySettings: rawProxy(),
              ),
            ),
          ),
          KeyedSubtree(
            key: const ValueKey('shape-factory'),
            child: SizedBox(
              width: 320,
              height: 110,
              child: WebViewFactory.createWebView(
                config: WebViewConfig(
                  siteId: 'proxy-shape-1',
                  initialUrl: 'http://$originHost:${ports[1]}/s1',
                  proxySettings: UserProxySettings(
                    type: ProxyType.SOCKS5,
                    address: '127.0.0.1:${socks.port}',
                  ),
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
          SizedBox(
            width: 320,
            height: 110,
            child: inapp.InAppWebView(
              key: const ValueKey('shape-raw-loadurl'),
              initialSettings: inapp.InAppWebViewSettings(
                containerId: 'ws-proxy-shape-2',
                proxySettings: rawProxy(),
              ),
              onWebViewCreated: (c) {
                c.loadUrl(
                  urlRequest: inapp.URLRequest(
                    url: inapp.WebUri('http://$originHost:${ports[2]}/s2'),
                  ),
                );
              },
            ),
          ),
        ]),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));

    bool settled(int i) =>
        socks.targets.contains('$originHost:${ports[i]}') ||
        requests.contains('s$i:/s$i');

    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (DateTime.now().isBefore(deadline)) {
        if (List.generate(shapes.length, settled).every((s) => s)) break;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    });

    for (var i = 0; i < shapes.length; i++) {
      final outcome = socks.targets.contains('$originHost:${ports[i]}')
          ? 'proxied'
          : requests.contains('s$i:/s$i')
              ? 'DIRECT'
              : 'no-load';
      results.add('${shapes[i]}->$outcome');
      log('${shapes[i]} -> $outcome');
    }

    final proxied = results.where((r) => r.endsWith('proxied')).length;
    expect(
      proxied,
      shapes.length,
      reason: 'every shape in one first frame on one endpoint must bind. Got '
          '[${results.join(" ")}]. A split here names the variable: only '
          'factory means the app path is what binds, only raw-loadurl means '
          'the load must be issued after creation, none means the difference '
          'is elsewhere in proxy_binding process',
    );
  });
}
