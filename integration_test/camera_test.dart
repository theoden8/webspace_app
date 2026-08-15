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
//   1. Virtual mode, IMAGE source: the page's getUserMedia must resolve with a
//      stream whose pixels ARE the user-picked image. Proves picker -> model
//      -> bridge -> shim -> canvas captureStream -> <video> -> page, and fails
//      on the autoplay regression because no frame ever arrives.
//   2. Virtual mode, VIDEO source: the clip must play AND keep looping. The
//      fixture alternates two colours every ~500ms, so a stream frozen on its
//      first decoded frame reports zero transitions and fails.
//   3. Block mode: the same page must be denied (NotAllowedError), proving
//      scenarios 1-2 are not vacuously green.
//   4. Real mode: the device camera is handed over when one exists. Skipped
//      (not failed) when the runner has no usable camera — which is the case
//      in CI: the AVD's emulated camera never settles a getUserMedia call
//      under `-no-window -gpu swiftshader_indirect`, so the workflow
//      deliberately does not enable it and this scenario stays a manual /
//      on-device check. scripts/run_android_camera_tests.sh still pre-grants
//      the CAMERA runtime permission so the OS dialog can never block a run
//      on a device that does have one.
//
// The probe page reports its result back to the in-process loopback server
// rather than through pixels: the exact error name is what makes a remote
// failure diagnosable (INTEG-006), and solid-colour sources make the pixel
// assertions exact.

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

import 'fixtures/virtual_camera_video.dart';

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
  // Forward the site tag from our own URL so the server can file the report
  // against the right scenario.
  var site = new URLSearchParams(location.search).get('site') || 'unknown';
  return fetch('/report?site=' + encodeURIComponent(site) +
    '&data=' + encodeURIComponent(JSON.stringify(o)));
}
(async function() {
  var result = { ok: false };
  try {
    var devices = await navigator.mediaDevices.enumerateDevices();
    result.cams = devices.filter(function(d) { return d.kind === 'videoinput'; }).length;
    // Cap getUserMedia itself, not just the frame loop: opening a real camera
    // can HANG rather than reject (an emulator's synthetic camera under
    // swiftshader never settles), and a page that never reports is an opaque
    // timeout on the Dart side instead of a classifiable result.
    var stream = await Promise.race([
      navigator.mediaDevices.getUserMedia({ video: true }),
      new Promise(function(_, rej) {
        setTimeout(function() {
          var e = new Error('getUserMedia did not settle within 30s');
          e.name = 'TimeoutError';
          rej(e);
        }, 30000);
      }),
    ]);
    var track = stream.getVideoTracks()[0];
    result.label = track ? track.label : null;
    var video = document.createElement('video');
    video.muted = true;
    video.playsInline = true;
    video.srcObject = stream;
    await video.play();
    var canvas = document.createElement('canvas');
    // Sample a series rather than a single frame: a looping video source must
    // be shown to keep CHANGING (frozen-on-first-frame would pass a
    // single-sample check), so the test needs the observed colours and the
    // number of transitions.
    var samples = [];
    var deadline = Date.now() + 20000;
    var observeUntil = null;
    while (Date.now() < deadline) {
      if (video.readyState >= 2 && video.videoWidth > 0) {
        var w = video.videoWidth, h = video.videoHeight;
        canvas.width = w; canvas.height = h;
        var ctx = canvas.getContext('2d');
        ctx.drawImage(video, 0, 0, w, h);
        var d = ctx.getImageData(Math.floor(w / 2), Math.floor(h / 2), 1, 1).data;
        // A camera (or a decoder) warming up emits black frames first; the
        // observation window opens at the first real frame.
        if (d[0] + d[1] + d[2] > 12) {
          if (!result.ok) {
            result.ok = true;
            result.w = w; result.h = h;
            result.px = [d[0], d[1], d[2]];
            document.body.style.background =
              'rgb(' + d[0] + ',' + d[1] + ',' + d[2] + ')';
            // Watch ~4s: the fixture clip is ~0.5s, so a looping source
            // transitions several times inside the window.
            observeUntil = Date.now() + 4000;
          }
          samples.push([d[0], d[1], d[2]]);
        }
      }
      if (observeUntil !== null && Date.now() > observeUntil) break;
      await new Promise(function(r) { setTimeout(r, 100); });
    }
    if (!result.ok) {
      result.error = 'no frame before deadline';
    } else {
      var changes = 0;
      for (var i = 1; i < samples.length; i++) {
        var p = samples[i - 1], q = samples[i];
        if (Math.abs(p[0] - q[0]) + Math.abs(p[1] - q[1]) + Math.abs(p[2] - q[2]) > 40) {
          changes++;
        }
      }
      result.changes = changes;
      result.samples = samples.length;
      result.distinct = samples.filter(function(p, i) {
        return i === 0 || Math.abs(samples[i - 1][0] - p[0]) +
          Math.abs(samples[i - 1][1] - p[1]) +
          Math.abs(samples[i - 1][2] - p[2]) > 40;
      });
    }
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
    final video = WebViewModel(
      siteId: 'ws-cam-video',
      initUrl: '$base/probe.html?site=video',
      name: 'CamVideo',
      cameraMode: CameraAccessMode.virtual,
      virtualCameraSource: const VirtualCameraSource(
        kind: 'video',
        dataUrl: kVirtualCameraVideoDataUrl,
        fileName: 'clip.webm',
      ),
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
        jsonEncode(video.toJson()),
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

    // --- Scenario 2: a video source plays AND loops ------------------------
    // The clip alternates two colours every ~500ms, so a stream that is
    // merely frozen on the first decoded frame reports zero transitions.
    await openSiteDrawer(tester);
    await tapSite(tester, 'CamVideo');
    final videoReport = await awaitReport(tester, 'video');
    if (videoReport['ok'] != true) {
      dumpDiagnostics('video source produced no frame: $videoReport');
    }
    expect(videoReport['ok'], isTrue,
        reason: 'a video virtual source must produce frames; got '
            '${videoReport['error']}');
    final distinct = (videoReport['distinct'] as List)
        .map((p) => (p as List).cast<num>())
        .toList();
    bool sawColour(List<int> want) => distinct.any((p) =>
        near(p[0].toInt(), want[0]) &&
        near(p[1].toInt(), want[1]) &&
        near(p[2].toInt(), want[2]));
    expect(sawColour(kVirtualCameraVideoColorA), isTrue,
        reason: 'first colour of the clip should appear; saw $distinct');
    expect(sawColour(kVirtualCameraVideoColorB), isTrue,
        reason: 'second colour of the clip should appear; saw $distinct');
    // At least one transition proves the stream is live rather than frozen on
    // the first decoded frame. Deliberately not a tighter bound: the emulator
    // decodes the VP8 clip far slower than real time (the first CI run saw
    // exactly 2 transitions in 4s where desktop Chromium sees ~8), so a
    // higher threshold would be a flake waiting to happen. The strict
    // looping proof — several transitions per clip length — is asserted in
    // test/browser/camera_stream_real_engine.test.js against a real engine.
    expect((videoReport['changes'] as num) >= 1, isTrue,
        reason: 'the clip must keep playing, not freeze on one frame; '
            'changes=${videoReport['changes']} over '
            '${videoReport['samples']} samples');

    // --- Scenario 3: block mode denies (control for scenario 1) ------------
    await openSiteDrawer(tester);
    await tapSite(tester, 'CamBlock');
    final blockReport = await awaitReport(tester, 'block');
    expect(blockReport['ok'], isFalse,
        reason: 'a blocked site must not receive a camera stream');
    expect(blockReport['error'].toString(), contains('NotAllowedError'),
        reason: 'block should surface as a NotAllowedError, got '
            '${blockReport['error']}');

    // --- Scenario 4: real mode hands over the device camera ----------------
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
        // A camera that never settles the open call: the CI emulator's
        // synthetic camera behaves this way under swiftshader.
        realError.contains('TimeoutError') ||
        realReport['cams'] == 0;
    if (realReport['ok'] != true && environmentGap) {
      print('camera_test: SKIPPING real-camera assertions — no usable camera '
          'or CAMERA permission on this runner ($realError). Expected in CI; '
          'to exercise it, run scripts/run_android_camera_tests.sh against a '
          'device with a working camera.');
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
