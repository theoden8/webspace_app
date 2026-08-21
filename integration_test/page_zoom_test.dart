// Per-site page zoom against real engines (BUG-008).
//
// Zoom is enacted differently per platform by design: Android and iOS
// drive the layout viewport through `<meta name="viewport">` (Android
// additionally pinning the width, to keep Chromium's 980px wide-viewport
// quirk out of the path), while desktop engines take root CSS `zoom`.
// Three engines, two channels — and the user-visible result has to be the
// same on all of them. That is what this test pins.
//
// The measurement is deliberately layout-only: a strip of fixed-width
// cells, counted per row. CSSOM lengths report differently across engines
// under root `zoom` (each has its own view on whether clientWidth lives in
// the zoomed coordinate space), but "how many 50px cells fit across the
// window" is decided by layout alone and means the same thing everywhere:
// at zoom z, 1/z as much content fits. A page that merely shrank into a
// gutter, or one laid out at the 980px fallback, fails it.
//
// Runs on the Linux and macOS integration jobs by file discovery, and on
// the Android emulator via scripts/run_android_page_zoom_tests.sh.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/services/webview.dart';

// Cell width in CSS px, and the box the webview is mounted in. The cell
// is small enough that a zoom step moves the count by more than the
// rounding tolerance: 320/50 = 6 cells at 100%, 8 at 80%, 4 at 150%.
const int _kCell = 50;
const double _kBoxWidth = 320;
const double _kBoxHeight = 480;

const String _kRulerPath = '/ruler';

String _rulerPage() => '''
<!doctype html><html><head>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  html,body{margin:0;padding:0;background:#123524}
  #strip{display:flex;flex-wrap:wrap}
  .cell{width:${_kCell}px;height:${_kCell}px;background:#8c1d5a;box-sizing:border-box}
</style></head><body>
<div id="strip">${'<div class="cell"></div>' * 120}</div>
</body></html>''';

// Cells per row, plus the CSSOM numbers for triage. Only the count is
// asserted on; the rest is printed when something goes wrong.
const String _kProbeJs = '''
(function(){
  try{
    var cells=document.querySelectorAll('.cell');
    if(!cells.length) return JSON.stringify({error:'no cells'});
    var top=cells[0].offsetTop, perRow=0;
    for(var i=0;i<cells.length;i++){
      if(cells[i].offsetTop!==top) break;
      perRow++;
    }
    var d=document.documentElement;
    var meta=document.querySelector('meta[name="viewport" i]');
    var vv=window.visualViewport;
    return JSON.stringify({
      perRow:perRow,
      client:d.clientWidth,
      inner:window.innerWidth,
      visual:vv&&vv.width>0?Math.round(vv.width):0,
      scroll:Math.max(d.scrollWidth,document.body?document.body.scrollWidth:0),
      meta:meta?meta.getAttribute('content'):null,
      zoom:String(getComputedStyle(d).zoom||'')
    });
  }catch(e){ return JSON.stringify({error:String(e)}); }
})()''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  late String base;

  // Mounting a webview costs tens of seconds on an emulator, and the box
  // is identical across cases, so a zoom level is measured once per run.
  final measured = <int, Map<String, dynamic>>{};
  var mountSeq = 0;

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      request.response
        ..headers.contentType = ContentType.html
        ..write(request.uri.path == _kRulerPath
            ? _rulerPage()
            : '<!doctype html><html><body>404</body></html>');
      request.response.close();
    });
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  void log(String message) {
    // ignore: avoid_print
    print('page_zoom_test: $message');
  }

  /// Mount one webview at [zoomPercent] and read the ruler back. Returns
  /// null when the engine never got far enough to answer, so a headless
  /// runner that cannot mount a webview skips rather than fails
  /// spuriously — the load itself has its own coverage elsewhere.
  Future<Map<String, dynamic>?> measure(
    WidgetTester tester,
    int zoomPercent,
  ) async {
    mountSeq += 1;
    final mountKey = ValueKey('page-zoom-$zoomPercent-$mountSeq');
    // Tear the previous webview down first, and key the next one: a zoom
    // is baked into the webview at creation, but an unkeyed replacement
    // updates the existing element in place, so the platform view (and
    // its zoom) is reused and onControllerCreated never fires again.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 250));

    WebViewController? controller;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            key: mountKey,
            width: _kBoxWidth,
            height: _kBoxHeight,
            child: WebViewFactory.createWebView(
              config: WebViewConfig(
                key: mountKey,
                initialUrl: '$base$_kRulerPath',
                zoomPercent: zoomPercent,
                // Keep the surface to the zoom path: no blocker lists, no
                // ETP shim (which also spoofs screen.*), no CDN rewriting.
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
    ));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    Map<String, dynamic>? result;
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final c = controller;
        if (c == null) continue;
        try {
          final raw = await c
              .evaluateJavascriptReturning(_kProbeJs)
              .timeout(const Duration(seconds: 5));
          if (raw == null) continue;
          final decoded = jsonDecode(raw is String ? raw : '$raw');
          if (decoded is! Map<String, dynamic>) continue;
          if (decoded['error'] != null) continue;
          if ((decoded['perRow'] as num?) == null ||
              (decoded['perRow'] as num) <= 0) {
            continue;
          }
          result = decoded;
          return;
        } catch (_) {
          // Engine not ready yet (or the bridge is still coming up).
        }
      }
    });
    log('zoom $zoomPercent% -> $result');
    if (result != null) measured[zoomPercent] = result!;
    return result;
  }

  Future<Map<String, dynamic>?> measureOnce(
    WidgetTester tester,
    int zoomPercent,
  ) async =>
      measured[zoomPercent] ?? await measure(tester, zoomPercent);

  double rootZoomOf(Map<String, dynamic>? m) =>
      double.tryParse((m?['zoom'] as String?) ?? '') ?? 1;

  /// Whether the site's zoom rode the CSS channel, read against the
  /// unzoomed baseline rather than as an absolute: Android System WebView
  /// reports the device pixel ratio as the computed root zoom (2.75 on the
  /// Pixel 5 emulator, at every zoom level), so only the ratio is a signal.
  bool cssZoomChannel(Map<String, dynamic>? zoomed) {
    final base = rootZoomOf(measured[100]);
    final now = rootZoomOf(zoomed);
    if (base <= 0 || now <= 0) return false;
    return (now / base - 1).abs() > 0.01;
  }

  // The contract, one zoom level per case, against the 100% baseline: the
  // webview's CSS width is the platform's business (device pixel ratio,
  // insets, letterboxing), and only the *ratio* between zoom levels is a
  // promise the app makes.
  //
  // Each case measures at most one zoom level, so every mount is the first
  // in its test and gets the framework's own teardown between them; a
  // second live webview inside one test is a mount the desktop engines do
  // not reliably bring up.
  Future<void> checkZoom(WidgetTester tester, int zoomPercent) async {
    final baseline = measured[100];
    if (baseline == null) {
      log('SKIP: no 100% baseline was measured');
      return;
    }
    final zoomed = await measureOnce(tester, zoomPercent);
    if (zoomed == null) {
      fail('the 100% baseline rendered but $zoomPercent% did not: '
          'baseline=$baseline');
    }

    final scale = zoomPercent / 100;
    final basePerRow = (baseline['perRow'] as num).toInt();
    final perRow = (zoomed['perRow'] as num).toInt();
    final expected = basePerRow / scale;

    expect(
      (perRow - expected).abs(),
      lessThanOrEqualTo(1.0),
      reason: 'at $zoomPercent% the page must fit ${expected.toStringAsFixed(1)} '
          'cells per row (1/z as much content as the $basePerRow at 100%), '
          'got $perRow. baseline=$baseline zoomed=$zoomed',
    );

    if (scale < 1) {
      expect(perRow, greaterThan(basePerRow),
          reason: 'zooming out must reflow more content in, not shrink the '
              'page into a gutter. baseline=$baseline zoomed=$zoomed');
    } else {
      expect(perRow, lessThan(basePerRow),
          reason: 'zooming in must reflow less content in. '
              'baseline=$baseline zoomed=$zoomed');
    }

    // Horizontal overflow, but only on the viewport channel. There the
    // layout viewport must fit inside the visible one, and both come from
    // the same layout-space APIs; a wider layout viewport is a pin that
    // overshot the WebView's box and hangs the page off the right edge.
    // On the CSS channel `clientWidth` and `scrollWidth` are not in the
    // same coordinate space (WebKit reported 303 vs 378 at 80% and 303 vs
    // 303 at 150% for the same page), so no comparison of them means
    // anything; the cells-per-row ratio above carries the contract there.
    final client = (zoomed['client'] as num?)?.toDouble() ?? 0;
    final visual = (zoomed['visual'] as num?)?.toDouble() ?? 0;
    if (!cssZoomChannel(zoomed) && visual > 0) {
      expect(client, lessThanOrEqualTo(visual + 2),
          reason: 'the layout viewport must fit the WebView: '
              '${client.toStringAsFixed(0)}px laid out into a '
              '${visual.toStringAsFixed(0)}px box. zoomed=$zoomed');
    }
  }

  testWidgets('100%: the unzoomed baseline renders', (tester) async {
    // The reference every other case is measured against. A skip here (an
    // engine that cannot bring a webview up at all) skips the rest rather
    // than failing them.
    final baseline = await measureOnce(tester, 100);
    if (baseline == null) {
      log('SKIP: the engine never rendered a webview');
      return;
    }
    expect((baseline['perRow'] as num).toInt(), greaterThan(1),
        reason: 'the ruler must fit at least two cells to be a ruler. '
            'baseline=$baseline');
  }, timeout: const Timeout(Duration(minutes: 4)));

  testWidgets('80%: one fifth more content fits, on every engine',
      (tester) async {
    await checkZoom(tester, 80);
  }, timeout: const Timeout(Duration(minutes: 4)));

  testWidgets('150%: content reflows out, on every engine', (tester) async {
    await checkZoom(tester, 150);
  }, timeout: const Timeout(Duration(minutes: 4)));

  testWidgets('the platform takes the channel it is supposed to take',
      (tester) async {
    // Same outcome, two mechanisms. Mixing them is what BUG-008 is about,
    // so each platform must be on its own channel and off the other's.
    final zoomed = await measureOnce(tester, 80);
    if (zoomed == null) {
      log('SKIP: the engine never rendered the zoomed page');
      return;
    }
    final meta = zoomed['meta'] as String?;
    final cssZoomed = cssZoomChannel(zoomed);
    final haveBaseline = measured.containsKey(100);

    if (Platform.isAndroid || Platform.isIOS) {
      expect(meta, isNotNull,
          reason: 'the mobile channel is the viewport meta. zoomed=$zoomed');
      expect(meta, contains('initial-scale=0.8'),
          reason: 'the meta must carry the site zoom. zoomed=$zoomed');
      expect(cssZoomed, isFalse,
          reason: 'the CSS channel must stay untouched on mobile. '
              'zoomed=$zoomed');
      if (Platform.isAndroid) {
        // The 980px quirk fires on a meta that names a scale and no
        // width; the pinned width is the whole fix.
        expect(meta, matches(RegExp(r'width=\d+')),
            reason: 'Android must pin an explicit layout width '
                '(PageScaleConstraintsSet::AdjustForAndroidWebViewQuirks). '
                'zoomed=$zoomed');
      }
    } else {
      expect(meta, isNot(contains('initial-scale=0.8')),
          reason: 'desktop engines ignore the viewport meta; the zoom shim '
              'must not be writing one there. zoomed=$zoomed');
      if (!haveBaseline) {
        log('SKIP css-zoom assertion: no baseline to read the root zoom '
            'against');
      } else {
        expect(cssZoomed, isTrue,
            reason: 'the desktop channel is root CSS zoom. zoomed=$zoomed');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
