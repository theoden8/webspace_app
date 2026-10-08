// LCDN-007 at the effect level: the LocalCDN cache is app-wide, so the only
// thing that keeps a site that turned LocalCDN off from being served from it
// is the per-site flag the interceptor is attached with. A loopback server
// plays the CDN; the cached copy and the network copy of the same script
// report which one ran.
//
// The enabled site runs first and is the control: it proves the interceptor
// attached and served in this environment, so the disabled site's "network"
// is a decision, not an interceptor that never arrived.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/services/web_intercept_native.dart';
import 'package:webspace/services/webview.dart';
import 'bare_site.dart';
import 'fixture_server.dart';
import 'package:webspace/services/webview_config.dart';
import 'package:webspace/services/webview_controller.dart';
import 'package:webspace/services/page_js.dart';

const _kSrcProbe = 'window.__wsSrc || null';

String _pageFor(String scriptUrl) =>
    '<!doctype html><html><body><script src="$scriptUrl"></script></body></html>';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(PageJs.load);

  late HttpServer server;
  late String base;
  late Directory cacheDir;

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    listenFixture(server, onEvent: (request) {
      final path = request.uri.path;
      final res = request.response;
      if (path.startsWith('/npm/')) {
        res
          ..headers.contentType = ContentType('application', 'javascript')
          ..headers.set('Cache-Control', 'no-store')
          ..write("window.__wsSrc = 'network';");
      } else if (path == '/page') {
        res
          ..headers.contentType = ContentType.html
          ..write(_pageFor('$base/npm/wslib@${request.uri.queryParameters['v']}/probe.js'));
      } else {
        res
          ..headers.contentType = ContentType.html
          ..write('<!doctype html><html><body></body></html>');
      }
      res.close();
    });
    base = 'http://127.0.0.1:${server.port}';

    cacheDir = await Directory.systemTemp.createTemp('localcdn_per_site');
    final cached = File('${cacheDir.path}/probe.js')
      ..writeAsStringSync("window.__wsSrc = 'cache';");
    await WebInterceptNative.sendCdnPatterns([
      r'^http://127\.0\.0\.1:\d+/npm/([^@/]+)@([^/]+)/(.+)$',
    ]);
    await WebInterceptNative.sendCdnCacheIndex({
      'wslib/1.0.0/probe.js': cached.path,
      'wslib/1.0.1/probe.js': cached.path,
    });
  });

  tearDownAll(() async {
    await WebInterceptNative.sendCdnPatterns(const []);
    await WebInterceptNative.sendCdnCacheIndex(const {});
    await server.close(force: true);
    await cacheDir.delete(recursive: true);
  });

  /// Mount a site whose LocalCDN is [enabled], let the production attach run,
  /// then load a page whose one script is a cached CDN URL and report which
  /// copy ran. Null when the page never answered.
  Future<String?> scriptSource(
    WidgetTester tester, {
    required String siteId,
    required bool enabled,
    required String version,
  }) async {
    final key = ValueKey('localcdn-$siteId');
    WebViewController? controller;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WebViewFactory.createWebView(
          config: WebViewConfig(
            hooks: bareHooks(),
            key: key,
            posture: barePosture('$base/blank',
                siteId: siteId,
                adjust: (site) => site.localCdnEnabled = enabled),
            initialUrl: '$base/blank',
          ),
          onControllerCreated: (c) => controller = c,
        ),
      ),
    ));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    String? source;
    await tester.runAsync(() async {
      final mounted = DateTime.now().add(const Duration(seconds: 30));
      while (controller == null && DateTime.now().isBefore(mounted)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      final c = controller;
      if (c == null) return;
      // The attach retries for up to ~1.5s after the view is created.
      await Future<void>.delayed(const Duration(seconds: 3));
      await c.loadUrl('$base/page?v=$version');
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final raw = await c
            .evaluateJavascriptReturning(_kSrcProbe)
            .timeout(const Duration(seconds: 5), onTimeout: () => null);
        if (raw is String && raw.isNotEmpty && raw != 'null') {
          source = raw.replaceAll('"', '');
          return;
        }
      }
    });
    return source;
  }

  testWidgets('a site with LocalCDN on is served from the cache',
      (tester) async {
    expect(
      await scriptSource(tester,
          siteId: 'localcdn-on', enabled: true, version: '1.0.0'),
      'cache',
    );
  }, skip: !Platform.isAndroid);

  testWidgets('a site with LocalCDN off fetches from the network',
      (tester) async {
    expect(
      await scriptSource(tester,
          siteId: 'localcdn-off', enabled: false, version: '1.0.1'),
      'network',
    );
  }, skip: !Platform.isAndroid);
}
