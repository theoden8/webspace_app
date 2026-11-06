// A site's webview resized around its pull-to-refresh spinner, on an iOS
// simulator: when the spinner goes, the page must rest at its top again
// (NAV-020; upstream flutter_inappwebview #2253, closed unfixed).
//
// On a phone the page was seen resting about 60pt below its top, the top shown
// only while dragged down, until a resize (the block-stats banner opened and
// closed) put it back. While the refresh control refreshes, UIKit holds its
// 60pt in contentInset.top and takes it back off when it ends; the plugin's
// `InAppWebView.frame` setter zeroes contentInset on every resize, so a resize
// in between leaves it at -60 once the spinner is gone. That top,
// -adjustedContentInset.top, is what no plugin call reads, so a debug-only probe
// in the Runner (ScrollInsetProbe) reads it; the scroll offset alone missed it
// (the page can sit at 0 above the top it bounces back to).
//
// The control arm refreshes the same page with no resize, so a page that
// rests below its top for another reason fails every arm. The others resize
// at each point a resize can meet the spinner: while it refreshes, as its end
// animation starts (the refresh's own page load ends it), and across that
// animation the way the block-stats banner's opening animates the box.
//
// iOS only: no other platform has the refresh control. Run by
// .github/workflows/ios-refresh-inset.yml on a simulator.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/services/pull_to_refresh_gate.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/services/webview_config.dart';
import 'package:webspace/services/webview_controller.dart';
import 'package:webspace/settings/site_ids.dart';

import 'bare_site.dart';
import 'fixture_server.dart';

const double _kWidth = 360;
const double _kTall = 640;

/// The box after the resize, as the block-stats banner opening shrinks it.
const double _kShort = 560;

/// How far into the space above the page a pull leaves it while the spinner
/// shows.
const int _kPulled = 120;

const String _kPagePath = '/tall';

const String _kPage = '''
<!doctype html><html><head>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  html,body{margin:0;padding:0;background:#123524}
  #top{height:60px;background:#8c1d5a}
  #rest{height:4000px}
</style></head><body><div id="top"></div><div id="rest"></div></body></html>''';

/// One webview's scroll view as the debug probe reads it: the page's top rests
/// at -[adjustedTop], so a negative one is a top the page cannot stay at.
typedef _Insets = ({
  double offsetY,
  double insetTop,
  double adjustedTop,
  double insetBottom,
  double adjustedBottom,
});

/// The scroll view once the spinner has ended and settled.
typedef _Reading = ({_Insets? settled, _Insets? afterScrollToTop});

const _probe = MethodChannel('webspace/debug_scroll_insets');

_Insets? _insetsOf(Object? view) => switch (view) {
      {
        'offsetY': final double offsetY,
        'insetTop': final double insetTop,
        'adjustedTop': final double adjustedTop,
        'insetBottom': final double insetBottom,
        'adjustedBottom': final double adjustedBottom,
      } =>
        (
          offsetY: offsetY,
          insetTop: insetTop,
          adjustedTop: adjustedTop,
          insetBottom: insetBottom,
          adjustedBottom: adjustedBottom,
        ),
      _ => null,
    };

/// When the box changes size against the spinner's life.
enum _Resize {
  none,
  whileRefreshing,
  asSpinnerEnds,
  animatedAcrossEnd,
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  late String base;

  setUpAll(() async {
    await bareSetUp();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    listenFixture(server, onEvent: (request) {
      request.response
        ..headers.contentType = ContentType.html
        ..headers.set('Cache-Control', 'no-store')
        ..write(request.uri.path == _kPagePath
            ? _kPage
            : '<!doctype html><html><body>404</body></html>');
      unawaited(request.response.close());
    });
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  void log(String message) {
    // ignore: avoid_print
    print('ios_refresh_inset_test: $message');
  }

  Future<void> settle(WidgetTester tester, {required Duration wait}) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.runAsync(() => Future<void>.delayed(wait));
    await tester.pump();
  }

  Future<_Reading> refresh(
    WidgetTester tester, {
    required _Resize resize,
  }) async {
    final arm = resize.name;
    final height = ValueNotifier<double>(_kTall);
    final gate = PullToRefreshGate.forHost(onRefresh: () async {});
    expect(gate?.controller, isNotNull,
        reason: 'the app builds no refresh control on this platform');
    final mountKey = ValueKey('refresh-inset-$arm');
    WebViewController? controller;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: ValueListenableBuilder<double>(
            valueListenable: height,
            builder: (context, h, child) =>
                SizedBox(width: _kWidth, height: h, child: child),
            child: WebViewFactory.createWebView(
              config: WebViewConfig(
                cacheFirst: false,
                hooks: bareHooks(),
                key: mountKey,
                posture: barePosture('$base$_kPagePath',
                    siteId: SiteId('refresh-inset-$arm')),
                initialUrl: '$base$_kPagePath',
                pullToRefreshGate: gate,
              ),
              onControllerCreated: (c) => controller = c,
            ),
          ),
        ),
      ),
    ));

    var loaded = false;
    for (var i = 0; i < 90 && !loaded; i++) {
      await settle(tester, wait: const Duration(milliseconds: 500));
      final c = controller;
      if (c == null) continue;
      await tester.runAsync(() async {
        try {
          final state = await c
              .evaluateJavascriptReturning(
                  "document.readyState + ':' + !!document.getElementById('top')")
              .timeout(const Duration(seconds: 5));
          loaded = state == 'complete:true';
        } on TimeoutException {
          // The bridge is not up yet.
        }
      });
    }
    expect(loaded, isTrue, reason: 'the page never loaded');
    final native = controller!.nativeController;
    final control = gate!.controller!;

    /// The one webview this test mounts, read off its scroll view.
    Future<_Insets?> insets() async {
      List<Object?>? views;
      await tester.runAsync(
          () async => views = await _probe.invokeListMethod<Object?>('read'));
      expect(views, hasLength(1), reason: 'the probe found ${views?.length} '
          'webviews, not the one this test mounts');
      return _insetsOf(views!.single);
    }

    log('$arm: before the refresh ${await insets()}');
    await tester.runAsync(() async {
      await control.beginRefreshing();
      await native.scrollTo(x: 0, y: -_kPulled);
    });
    await settle(tester, wait: const Duration(milliseconds: 500));
    log('$arm: spinner up, refreshing '
        '${await tester.runAsync(control.isRefreshing)}, ${await insets()}');

    switch (resize) {
      case _Resize.none:
        await tester.runAsync(control.endRefreshing);
      case _Resize.whileRefreshing:
        height.value = _kShort;
        await settle(tester, wait: const Duration(milliseconds: 500));
        log('$arm: resized to $_kShort while refreshing, ${await insets()}');
        await tester.runAsync(control.endRefreshing);
      case _Resize.asSpinnerEnds:
        await tester.runAsync(() async {
          unawaited(control.endRefreshing());
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        height.value = _kShort;
        await tester.pump();
        log('$arm: resized to $_kShort 50ms into the end');
      case _Resize.animatedAcrossEnd:
        const steps = 20;
        for (var i = 1; i <= steps; i++) {
          if (i == steps ~/ 4) unawaited(control.endRefreshing());
          height.value = _kTall + (_kShort - _kTall) * i / steps;
          await tester.pump();
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 15)));
        }
        log('$arm: animated to $_kShort over ~300ms, ending at step '
            '${steps ~/ 4}');
    }
    final path = <String>[];
    for (var i = 0; i < 15; i++) {
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      final now = await insets();
      path.add('${now?.offsetY}/${now?.adjustedTop}');
    }
    log('$arm: offset/adjustedTop every 100ms after the end: $path');
    final settled = await insets();

    await tester.runAsync(() async {
      try {
        await controller!.evaluateJavascript('window.scrollTo(0, 0);');
        await Future<void>.delayed(const Duration(milliseconds: 500));
        log('$arm: page scrollY after asking for its top: '
            '${await controller!.evaluateJavascriptReturning('window.scrollY')}');
      } on PlatformException catch (e) {
        log('$arm: the page could not be asked for its top: $e');
      }
    });
    await settle(tester, wait: const Duration(milliseconds: 300));
    final reading = (settled: settled, afterScrollToTop: await insets());
    log('$arm: settled ${reading.settled}');
    log('$arm: after scroll to top ${reading.afterScrollToTop}');
    height.dispose();
    return reading;
  }

  for (final resize in _Resize.values) {
    testWidgets(
        'a refresh with resize ${resize.name} leaves the page at its top '
        '(NAV-020)',
        skip: !Platform.isIOS, (tester) async {
      final r = await refresh(tester, resize: resize);
      expect(r.settled, isNotNull, reason: 'the probe read no scroll view');
      expect(r.settled!.adjustedTop, 0,
          reason: 'with the spinner gone the page\'s top rests at '
              '${-r.settled!.adjustedTop}pt, not 0');
      expect(r.settled!.adjustedBottom, 0,
          reason: 'with no keyboard the page\'s end rests '
              '${r.settled!.adjustedBottom}pt from the bottom');
    });
  }
}
