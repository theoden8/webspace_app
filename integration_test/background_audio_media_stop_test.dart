// Media-stop integration test (BGAUDIO-009).
//
// The bug this reproduces: a site with Background audio OFF kept sounding
// after it lost the screen, because neither pause stops the media pipeline —
// `pauseWebView()` and `pauseForAppLifecycle()` freeze JS timers, and decoding
// runs independently of the JS thread. On iOS that also left the system Now
// Playing controls up for a site the user never opted in for (the `audio`
// UIBackgroundModes entry is app-wide), with a play button that reached a
// frozen page.
//
// The observable is the fixture's own beacon: it carries the media element's
// `paused` flag and `currentTime`, so "did the audio actually stop" is read
// off the page rather than off a Dart-side flag.
//
// Android emulator tier only (scripts/run_android_background_audio_tests.sh):
// it needs a real media pipeline, which WPE in the headless Linux container
// crash-loops on, and it needs `pauseTimers()` to be genuinely implemented so
// the JS-freeze half of the interleaving is real. Self-skips elsewhere; the
// Linux/macOS integration loops exclude it by name.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/main.dart' as app;
import 'package:webspace/demo_data.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/media_session_service.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

import 'fixtures/background_audio_fixture.dart';

class _Beacon {
  _Beacon(this.ticks, this.playState, this.currentTime, this.paused);
  final int ticks;
  final String playState;
  final double currentTime;
  final String paused;

  bool get mediaLive => paused == 'false' && currentTime > 0;
  bool get mediaStopped => paused == 'true';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  late int port;
  final beacons = <_Beacon>[];

  void log(String m) {
    // ignore: avoid_print
    print('[bgaudio-stop] $m');
  }

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    server.listen((req) {
      if (req.uri.path == '/beacon') {
        final q = req.uri.queryParameters;
        beacons.add(_Beacon(
          int.tryParse(q['ticks'] ?? '') ?? -1,
          q['audio'] ?? '?',
          double.tryParse(q['t'] ?? '') ?? 0,
          q['paused'] ?? '?',
        ));
        req.response
          ..statusCode = 204
          ..close();
        return;
      }
      final res = req.response..headers.contentType = ContentType.html;
      res.write(backgroundAudioFixtureHtml);
      res.close();
    });

    isDemoMode = true;
    // Background audio deliberately OFF: this test is about what the toggle
    // promises when it is not set. `?media=stream` is a muted <video> off a
    // canvas captureStream — the same element surface and paused/currentTime
    // predicate as real audio, with no audio device (the emulator boots
    // -noaudio).
    final plainSite = WebViewModel(
      siteId: 'bg-media-stop',
      initUrl: 'http://127.0.0.1:$port/?media=stream',
      name: 'Plain Media Site',
    );
    SharedPreferences.setMockInitialValues({
      'webViewModels': [jsonEncode(plainSite.toJson())],
    });
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  testWidgets('a site without the toggle stops playing when the app backgrounds',
      (tester) async {
    if (!Platform.isAndroid) {
      log('skipped: needs a real media pipeline + pauseTimers() '
          '(platform=${Platform.operatingSystem})');
      return;
    }

    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 30));

    // Wall-clock wait that keeps pumping frames: a live WebView wedges
    // pumpAndSettle, and beacon arrival needs no frames but UI transitions do.
    Future<void> pumpUntil(
      bool Function() predicate, {
      Duration timeout = const Duration(seconds: 60),
      Duration step = const Duration(milliseconds: 250),
      required String description,
    }) async {
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        await tester.pump(step);
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
        if (predicate()) return;
      }
      throw StateError(
          'Timed out after ${timeout.inSeconds}s waiting for: $description');
    }

    await tester.tap(find.byKey(const ValueKey(kAllWebspaceId)));
    await tester.pumpAndSettle(const Duration(seconds: 5));
    final tile = find.text('Plain Media Site');
    expect(tile, findsOneWidget, reason: 'site should appear in the drawer');
    await tester.tap(tile);

    await pumpUntil(
      () => beacons.any((b) => b.mediaLive),
      description: 'the fixture media to report itself playing '
          '(last beacon: ${beacons.isEmpty ? "none" : beacons.last.playState})',
    );
    log('media live at t=${beacons.lastWhere((b) => b.mediaLive).currentTime}');

    // The toggle is off, so nothing should have armed the media bridge — the
    // BGAUDIO-007 line that tells "toggle off" from "bridge broken".
    final mediaLines = LogService.instance.allEntriesMerged
        .where((e) => e.tag == 'MediaSession')
        .map((e) => e.message)
        .toList();
    expect(mediaLines.any((m) => m.contains('Bridge armed')), isFalse,
        reason: 'the media-session shim is only injected for sites with the '
            'Background audio toggle on');

    // Sample the media clock as late as possible. Everything between a beacon
    // and the background dispatch is foreground time the element is entitled
    // to advance through, and on a loaded emulator the assertions above cost
    // more of it than a fixed budget can allow for.
    beacons.clear();
    await pumpUntil(
      () => beacons.isNotEmpty,
      description: 'a fresh beacon to sample the media clock from',
    );
    final before = beacons.last;
    expect(before.mediaLive, isTrue,
        reason: 'the media must still be playing when the app backgrounds');
    log('before background: t=${before.currentTime}');

    const backgroundHold = Duration(seconds: 3);
    final leftForeground = DateTime.now();
    beacons.clear();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.runAsync(() => Future<void>.delayed(backgroundHold));

    // BGAUDIO-002's negative control already owns "the JS froze"; what matters
    // here is that the media stop was dispatched BEFORE that freeze, so the
    // page comes back with its player stopped rather than still running.
    expect(
      LogService.instance.allEntriesMerged.any((e) =>
          e.tag == 'Lifecycle' &&
          e.message.contains('jsPause=true') &&
          e.message.contains('bgAudio=0')),
      isTrue,
      reason: 'a site without the toggle takes the ordinary background path',
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    beacons.clear();

    await pumpUntil(
      () => beacons.isNotEmpty,
      description: 'beacons to resume after foregrounding',
    );
    final wallClock = DateTime.now().difference(leftForeground);
    final after = beacons.first;
    log('after resume: paused=${after.paused} t=${after.currentTime} '
        'wall=${wallClock.inMilliseconds}ms');
    expect(after.mediaStopped, isTrue,
        reason: 'the media of a site with Background audio OFF must be paused '
            'when the app goes to background (BGAUDIO-009). A `paused=false` '
            'here is the reported bug: the audio kept playing, and on iOS the '
            'system transport controls stayed up with it.');

    // The element may legitimately advance over the two foreground slivers
    // around the background window — the stop's dispatch latency going in, and
    // the resume that precedes the first beacon coming out — but not through
    // the window itself. So the budget is the wall clock actually spent, minus
    // the hold it had to sit out, plus a second for those two dispatches. A
    // site that kept sounding lands a whole hold above it, whatever the
    // emulator's pace, which a fixed budget cannot say.
    final advance = after.currentTime - before.currentTime;
    final wallSeconds = wallClock.inMilliseconds / 1000.0;
    final budget = wallSeconds - backgroundHold.inSeconds + 1.0;
    expect(advance, lessThanOrEqualTo(budget),
        reason: 'the media clock advanced ${advance}s across ${wallSeconds}s '
            'of wall clock holding a ${backgroundHold.inSeconds}s background: '
            'it kept playing while the app was away, and was only paused on '
            'the way back');

    await pumpUntil(
      () => beacons.length >= 2,
      description: 'a second beacon to confirm the media clock stands still',
    );
    expect(beacons[1].currentTime, closeTo(after.currentTime, 0.05),
        reason: 'a paused element does not advance its currentTime');

    // The other half of the report: no media surface for a site that never
    // opted in. Android raises the notification only from a shim report, and
    // no shim was injected — this asserts the end of that chain.
    final posted = await tester
        .runAsync(() => MediaSessionService.instance.notificationPosted());
    expect(posted, isFalse,
        reason: 'no media notification may exist for a site with the toggle '
            'off');
  });
}
