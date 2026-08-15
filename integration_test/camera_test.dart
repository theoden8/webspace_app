// Per-site camera scenarios on a real Android WebView (CAM-010).
//
// The jsdom tier proves the shim's decision funnel and the desktop-Chromium
// tier proves a QR decodes off the synthetic stream, but neither runs the
// Android WebView the app actually ships. That gap shipped a real bug: the
// WebView defaults `mediaPlaybackRequiresUserGesture` to true, which blocks a
// getUserMedia stream from ever playing, so every mode rendered a grey frame
// while both lower tiers stayed green. This tier closes it by driving the
// production app end to end:
//
//   1. Virtual mode: the page's getUserMedia must resolve with a stream whose
//      pixels ARE the user-picked image. Proves picker -> model -> bridge ->
//      shim -> canvas captureStream -> <video> -> page, and fails on the
//      autoplay regression because no frame ever arrives.
//   2. Block mode: the same page must be denied (NotAllowedError), proving
//      scenario 1 is not vacuously green.
//   3. Real mode: the device camera is handed over when one exists. Skipped
//      (not failed) on a runner with no camera, since the emulated camera is
//      an AVD option rather than a guarantee — see
//      scripts/run_android_camera_tests.sh, which pre-grants the CAMERA
//      runtime permission so the OS dialog never blocks the run.
//
// The probe page reports its result back to the in-process loopback server
// rather than through pixels: the exact error name is what makes a remote
// failure diagnosable (INTEG-006), and a solid-color source makes the pixel
// assertion exact.
//
// NOTE: virtual mode is exercised with an IMAGE source. The looped-video
// source path is covered at the jsdom tier (test/js/camera_stream_shim.test.js
// asserts loop/muted/play on the <video> branch) and by the preview HTML
// builder test; encoding a video fixture needs a tool the CI image lacks.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/main.dart' as app;
import 'package:webspace/demo_data.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/settings/camera.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

// A colour Flutter never draws and no real camera would produce, so a match
// proves the sampled pixel came from the picked image.
const int _kSourceR = 0x1E;
const int _kSourceG = 0xC8;
const int _kSourceB = 0x7A;

/// Solid-colour PNG used as the virtual camera source, as a `data:` URL.
String _sourceImageDataUrl() {
  final image = img.Image(width: 320, height: 240);
  img.fill(image, color: img.ColorRgb8(_kSourceR, _kSourceG, _kSourceB));
  return 'data:image/png;base64,${base64Encode(img.encodePng(image))}';
}

/// Page that drives the exact API a web QR scanner uses and reports the
/// outcome back to the test server.
String _probePage() => '''
<!doctype html><html><head>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>html,body{margin:0;height:100%;background:#202020}</style>
</head><body><script>
function report(o) {
  return fetch('/report?data=' + encodeURIComponent(JSON.stringify(o)));
}
(async function() {
  var result = { ok: false };
  try {
    var devices = await navigator.mediaDevices.enumerateDevices();
    result.cams = devices.filter(function(d) { return d.kind === 'videoinput'; }).length;
    var stream = await navigator.mediaDevices.getUserMedia({ video: true });
    var track = stream.getVideoTracks()[0];
    result.label = track ? track.label : null;
    var video = document.createElement('video');
    video.muted = true;
    video.playsInline = true;
    video.srcObject = stream;
    await video.play();
    var canvas = document.createElement('canvas');
    var deadline = Date.now() + 20000;
    while (Date.now() < deadline) {
      if (video.readyState >= 2 && video.videoWidth > 0) {
        var w = video.videoWidth, h = video.videoHeight;
        canvas.width = w; canvas.height = h;
        var ctx = canvas.getContext('2d');
        ctx.drawImage(video, 0, 0, w, h);
        var d = ctx.getImageData(Math.floor(w / 2), Math.floor(h / 2), 1, 1).data;
        // A camera warming up can emit black frames first; keep sampling
        // until a non-black one arrives (or the deadline passes).
        if (d[0] + d[1] + d[2] > 12) {
          result.ok = true;
          result.w = w; result.h = h;
          result.px = [d[0], d[1], d[2]];
          document.body.style.background =
            'rgb(' + d[0] + ',' + d[1] + ',' + d[2] + ')';
          break;
        }
      }
      await new Promise(function(r) { setTimeout(r, 100); });
    }
    if (!result.ok) result.error = 'no frame before deadline';
    try { track.stop(); } catch (e) {}
  } catch (e) {
    result.ok = false;
    result.error = (e && e.name ? e.name : 'Error') + ': ' + (e && e.message);
  }
  await report(result);
})();
</script></body></html>
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  HttpServer? server;
  // siteId -> decoded probe report. The probe page tags its request with the
  // site it was loaded for via the query string.
  final reports = <String, Map<String, dynamic>>{};

  setUpAll(() async {
    isDemoMode = true;

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server!.listen((request) {
      if (request.uri.path == '/report') {
        final tag = request.uri.queryParameters['site'] ?? 'unknown';
        final raw = request.uri.queryParameters['data'] ?? '{}';
        try {
          reports[tag] = jsonDecode(raw) as Map<String, dynamic>;
        } catch (_) {
          reports[tag] = {'ok': false, 'error': 'unparsable report: $raw'};
        }
        request.response
          ..statusCode = 204
          ..close();
        return;
      }
      request.response
        ..headers.contentType = ContentType.html
        ..write(_probePage())
        ..close();
    });
    final base = 'http://127.0.0.1:${server!.port}';

    final source = VirtualCameraSource(
      kind: 'image',
      dataUrl: _sourceImageDataUrl(),
      fileName: 'source.png',
    );

    final virtual = WebViewModel(
      siteId: 'ws-cam-virtual',
      initUrl: '$base/probe.html?site=virtual',
      name: 'CamVirtual',
      cameraMode: CameraAccessMode.virtual,
      virtualCameraSource: source,
    );
    final blocked = WebViewModel(
      siteId: 'ws-cam-block',
      initUrl: '$base/probe.html?site=block',
      name: 'CamBlock',
      cameraMode: CameraAccessMode.block,
    );
    final real = WebViewModel(
      siteId: 'ws-cam-real',
      initUrl: '$base/probe.html?site=real',
      name: 'CamReal',
      cameraMode: CameraAccessMode.real,
    );

    SharedPreferences.setMockInitialValues({
      'webViewModels': [
        jsonEncode(virtual.toJson()),
        jsonEncode(blocked.toJson()),
        jsonEncode(real.toJson()),
      ],
    });
  });

  tearDownAll(() async {
    await server?.close(force: true);
  });

  void dumpDiagnostics(String context) {
    print('=== camera_test failure: $context');
    print('reports so far: $reports');
    final entries = LogService.instance.allEntriesMerged;
    for (final e in entries.skip(entries.length < 40 ? 0 : entries.length - 40)) {
      print('  [${e.tag}/${e.level.name}] ${e.message}');
    }
  }

  // pumpAndSettle deadlocks on a live webview, so poll in fixed slices until
  // the probe page posts its report.
  Future<Map<String, dynamic>> awaitReport(
    WidgetTester tester,
    String tag, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 250));
      final report = reports[tag];
      if (report != null) return report;
    }
    dumpDiagnostics('no report from "$tag" within ${timeout.inSeconds}s');
    fail('Timed out waiting for the "$tag" probe report. A missing report '
        'usually means the page never ran: check the site loaded at all.');
  }

  Future<void> openSiteDrawer(WidgetTester tester) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      if (find.byType(Drawer).evaluate().isNotEmpty) return;
      final menuIcon = find.byIcon(Icons.menu);
      if (menuIcon.evaluate().isNotEmpty) {
        await tester.tap(menuIcon.first);
      } else {
        for (final element in find.byType(Scaffold).evaluate()) {
          final state = tester.state<ScaffoldState>(
              find.byWidget(element.widget as Scaffold));
          if (state.hasDrawer) {
            state.openDrawer();
            break;
          }
        }
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(find.byType(Drawer), findsOneWidget,
        reason: 'site drawer should open for switching sites');
  }

  Future<void> tapSite(WidgetTester tester, String siteName) async {
    final drawer = find.byType(Drawer);
    final tile = drawer.evaluate().isNotEmpty
        ? find.descendant(of: drawer, matching: find.text(siteName))
        : find.text(siteName);
    if (tile.evaluate().isEmpty) dumpDiagnostics('site tile "$siteName" missing');
    expect(tile, findsWidgets, reason: '$siteName should be in the site list');
    await tester.tap(tile.first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  bool near(int actual, int expected, {int tolerance = 24}) =>
      (actual - expected).abs() <= tolerance;

  testWidgets('per-site camera modes behave on a real Android WebView',
      (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 30));
    await tester.tap(find.byKey(const ValueKey(kAllWebspaceId)));
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // --- Scenario 1: virtual mode serves the picked image ------------------
    await tapSite(tester, 'CamVirtual');
    final virtualReport = await awaitReport(tester, 'virtual');
    if (virtualReport['ok'] != true) {
      dumpDiagnostics('virtual mode produced no frame: $virtualReport');
    }
    expect(virtualReport['ok'], isTrue,
        reason: 'virtual mode must resolve getUserMedia with a playing stream; '
            'got ${virtualReport['error']}. A "no frame before deadline" here '
            'is the mediaPlaybackRequiresUserGesture regression.');
    final px = (virtualReport['px'] as List).cast<num>();
    expect(near(px[0].toInt(), _kSourceR), isTrue,
        reason: 'red channel of the served frame should match the picked '
            'image, got $px');
    expect(near(px[1].toInt(), _kSourceG), isTrue,
        reason: 'green channel should match the picked image, got $px');
    expect(near(px[2].toInt(), _kSourceB), isTrue,
        reason: 'blue channel should match the picked image, got $px');
    // The synthetic track presents as an ordinary camera, and enumeration
    // reports exactly one videoinput in virtual mode.
    expect(virtualReport['label'], 'Integrated Camera');
    expect(virtualReport['cams'], 1);

    // --- Scenario 2: block mode denies (control for scenario 1) ------------
    await openSiteDrawer(tester);
    await tapSite(tester, 'CamBlock');
    final blockReport = await awaitReport(tester, 'block');
    expect(blockReport['ok'], isFalse,
        reason: 'a blocked site must not receive a camera stream');
    expect(blockReport['error'].toString(), contains('NotAllowedError'),
        reason: 'block should surface as a NotAllowedError, got '
            '${blockReport['error']}');

    // --- Scenario 3: real mode hands over the device camera ----------------
    // Emulated cameras are an AVD option, not a guarantee: treat "no camera
    // on this runner" as a skip and everything else as a failure.
    await openSiteDrawer(tester);
    await tapSite(tester, 'CamReal');
    final realReport = await awaitReport(tester, 'real');
    final realError = (realReport['error'] ?? '').toString();
    // No camera device on this runner, or the app-level CAMERA permission was
    // never granted (scripts/run_android_camera_tests.sh pre-grants it; a
    // manual `flutter test` run will not have). Both are environment gaps
    // rather than regressions — the site IS seeded to `real`, so the per-site
    // decision cannot be what denied it.
    final environmentGap = realError.contains('NotFoundError') ||
        realError.contains('NotReadableError') ||
        realError.contains('NotAllowedError') ||
        realReport['cams'] == 0;
    if (realReport['ok'] != true && environmentGap) {
      print('camera_test: SKIPPING real-camera assertions — no usable camera '
          'or CAMERA permission on this runner ($realError). Run via '
          'scripts/run_android_camera_tests.sh and add `-camera-back emulated` '
          'to the emulator options to exercise this scenario.');
    } else {
      expect(realReport['ok'], isTrue,
          reason: 'real mode should deliver device-camera frames; got '
              '$realError');
      // Real frames must NOT be the virtual source colour: that would mean
      // the virtual path leaked into a site set to the real camera.
      final realPx = (realReport['px'] as List).cast<num>();
      final looksSynthetic = near(realPx[0].toInt(), _kSourceR) &&
          near(realPx[1].toInt(), _kSourceG) &&
          near(realPx[2].toInt(), _kSourceB);
      expect(looksSynthetic, isFalse,
          reason: 'a real-camera site must not be served the virtual source');
      expect((realReport['w'] as num) > 0, isTrue);
    }
  });
}
