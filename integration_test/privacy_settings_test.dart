// Privacy/perf WebView-settings integration test.
//
// Proves the androidx.webkit settings wired in
// WebViewFactory.createWebView (lib/services/webview.dart) actually take
// effect on a live engine, by loading a loopback fixture and observing the
// request the WebView issues for itself:
//
//   * X-Requested-With suppression (requestedWithHeaderOriginAllowList = {}):
//     a tracking-protection-on load must NOT carry the
//     `X-Requested-With: <package>` header Android WebView otherwise sends.
//   * Back/forward cache (backForwardCacheEnabled): with bfcache on, a
//     back navigation is served from cache and does NOT re-hit the server.
//
// Both are androidx.webkit-only. The header test self-calibrates against an
// ETP-off baseline and SKIPs on engines that never send X-Requested-With
// (WKWebView/macOS, WPE/Linux) rather than asserting a vacuous truth. The
// bfcache test is Android-gated: the flag maps to a feature WKWebView and WPE
// don't have, and the repeated mount/replace it needs would wedge the headless
// Linux runner's live platform view (see safari_navigation_test.dart). Run on
// a real Android device/emulator for the meaningful assertions:
//
//   fvm flutter test integration_test/privacy_settings_test.dart -d emulator-5554
//
// Harness mirrors safari_navigation_test.dart: a live compositing WebView
// wedges the Flutter UI thread, so waits run on real wall-clock inside
// tester.runAsync() and frames are pumped only to mount widgets.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/services/webview.dart';

class _Req {
  _Req(this.path, this.xrw);
  final String path;
  final String? xrw;
}

class _Mounted {
  _Mounted(this.request, this.controller);
  final _Req? request;
  final WebViewController? controller;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  late int port;
  final requests = <_Req>[];
  final bool savedBfcache = WebViewFactory.backForwardCacheEnabled;

  void log(String m) {
    // ignore: avoid_print
    print('[privacy] $m');
  }

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    server.listen((req) {
      requests.add(_Req(req.uri.path, req.headers.value('x-requested-with')));
      final res = req.response..headers.contentType = ContentType.html;
      res.write('<!doctype html><html><head><title>fixture</title></head>'
          '<body>fixture ${req.uri.path}</body></html>');
      res.close();
    });
  });

  tearDownAll(() async {
    WebViewFactory.backForwardCacheEnabled = savedBfcache;
    await server.close(force: true);
  });

  setUp(requests.clear);

  String url(String path) => 'http://127.0.0.1:$port$path';
  int countFor(String path) => requests.where((r) => r.path == path).length;

  Future<void> waitReal(WidgetTester tester, bool Function() done,
      {Duration timeout = const Duration(seconds: 30)}) async {
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (done()) return;
      }
    });
  }

  // Mount one webview through the real factory and wait (wall-clock) for its
  // initial request to reach the loopback server. Frames are pumped only to
  // mount the platform view; the load itself is awaited via runAsync.
  Future<_Mounted> mount(
    WidgetTester tester, {
    required String path,
    required bool trackingProtection,
  }) async {
    final ctrl = Completer<WebViewController>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 320,
            height: 480,
            child: WebViewFactory.createWebView(
              config: WebViewConfig(
                initialUrl: url(path),
                trackingProtectionEnabled: trackingProtection,
              ),
              onControllerCreated: (c) {
                if (!ctrl.isCompleted) ctrl.complete(c);
              },
            ),
          ),
        ),
      ),
    ));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await waitReal(tester, () => countFor(path) >= 1);
    _Req? seen;
    for (final r in requests) {
      if (r.path == path) seen = r;
    }
    final controller = ctrl.isCompleted ? await ctrl.future : null;
    return _Mounted(seen, controller);
  }

  testWidgets('tracking protection suppresses the X-Requested-With header',
      (tester) async {
    final off =
        await mount(tester, path: '/xrw-off', trackingProtection: false);
    expect(off.request, isNotNull, reason: 'ETP-off page should have loaded');
    log('baseline X-Requested-With = ${off.request!.xrw}');
    if (off.request!.xrw == null) {
      log('SKIP: engine does not send X-Requested-With; the '
          'requestedWithHeaderOriginAllowList setting is androidx.webkit-only. '
          'Run on Android to assert suppression.');
      return;
    }
    final on = await mount(tester, path: '/xrw-on', trackingProtection: true);
    expect(on.request, isNotNull, reason: 'ETP-on page should have loaded');
    expect(on.request!.xrw, isNull,
        reason: 'requestedWithHeaderOriginAllowList={} must drop '
            'X-Requested-With when tracking protection is on');
  });

  testWidgets('back/forward cache serves back-navigation from cache',
      (tester) async {
    if (!Platform.isAndroid) {
      log('SKIP: backForwardCacheEnabled maps to the androidx.webkit '
          'BACK_FORWARD_CACHE feature; WKWebView/WPE ignore it. Run on Android.');
      return;
    }

    // Returns whether navigating back to A re-hits the network. With bfcache
    // the back entry is restored from cache (no new request); without it the
    // engine re-fetches A.
    Future<bool> backRefetches(bool bfcache) async {
      WebViewFactory.backForwardCacheEnabled = bfcache;
      final tag = bfcache ? 'on' : 'off';
      final aPath = '/bfa-$tag';
      final bPath = '/bfb-$tag';
      final m = await mount(tester, path: aPath, trackingProtection: false);
      final c = m.controller;
      if (c == null) return false;
      await tester.runAsync(() => c.loadUrl(url(bPath)));
      await waitReal(tester, () => countFor(bPath) >= 1);
      final before = countFor(aPath);
      await tester.runAsync(() => c.goBack());
      await waitReal(tester, () => countFor(aPath) > before,
          timeout: const Duration(seconds: 6));
      return countFor(aPath) > before;
    }

    final offRefetch = await backRefetches(false);
    log('bfcache off -> back refetched A: $offRefetch');
    if (!offRefetch) {
      log('SKIP: back-navigation served from an always-on engine cache here, '
          'so the flag is not observable. Run on a WebView build where bfcache '
          'is off by default.');
      return;
    }
    final onRefetch = await backRefetches(true);
    log('bfcache on -> back refetched A: $onRefetch');
    expect(onRefetch, isFalse,
        reason: 'with backForwardCacheEnabled, going back must restore from '
            'the bfcache and not re-hit the network');
  });
}
