// Background-audio negative-control integration test (BGAUDIO-002).
//
// Companion to background_audio_lifecycle_test.dart. That test proves the
// *exempt* direction (a background-audio site keeps ticking when backgrounded).
// This one proves the *non-exempt* direction: a plain site with no background
// audio must have its JS frozen on app-background.
//
// The universal assertion is the engine decision line `jsPause=true` — true on
// every platform. The observable freeze (beacons stop) only holds where the
// plugin actually implements `pauseTimers()`, which is **Android** (and iOS);
// on Linux/WPE and macOS `pauseTimers()` is a no-op, so there the JS keeps
// ticking and the freeze is not asserted. Wiring this test into the Android
// emulator tier (scripts/run_android_background_audio_tests.sh) is what makes
// the freeze provable in CI — the direction the pure-Dart engine tests can't
// exercise against a real WebView.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/main.dart' as app;
import 'package:webspace/demo_data.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

import 'fixtures/background_audio_fixture.dart';

class _Beacon {
  _Beacon(this.at, this.ticks);
  final DateTime at;
  final int ticks;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  late int port;
  final beacons = <_Beacon>[];

  void log(String m) {
    // ignore: avoid_print
    print('[bgaudio-freeze] $m');
  }

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    server.listen((req) {
      if (req.uri.path == '/beacon') {
        beacons.add(_Beacon(DateTime.now(),
            int.tryParse(req.uri.queryParameters['ticks'] ?? '') ?? -1));
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
    // A PLAIN site: backgroundAudioEnabled defaults false. ?noMedia=1 keeps the
    // fixture off the media stack (WPE CI has no audio sink) — the claim here
    // is purely JS-timer freeze.
    final plainSite = WebViewModel(
      siteId: 'plain',
      initUrl: 'http://127.0.0.1:$port/?noMedia=1',
      name: 'Plain Site',
    );
    SharedPreferences.setMockInitialValues({
      'webViewModels': [jsonEncode(plainSite.toJson())],
    });
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  testWidgets('plain site JS is frozen on app-background (Android)',
      (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 30));

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
    final tile = find.text('Plain Site');
    expect(tile, findsOneWidget, reason: 'site should appear in the drawer');
    await tester.tap(tile);

    await pumpUntil(
      () => beacons.isNotEmpty,
      description: 'first beacon (webview mounted, JS running)',
    );
    log('first beacon: ticks=${beacons.first.ticks}');

    // Background the app. No pump() while paused (the framework stops
    // scheduling frames); the decision logs synchronously and beacons arrive
    // on native networking.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);

    List<String> decisionLines() => LogService.instance.allEntriesMerged
        .where((e) => e.message.startsWith('App background: '))
        .map((e) => e.message)
        .toList();
    expect(decisionLines(), isNotEmpty);
    // Universal: a plain, loaded, non-notification active site is planned for
    // a JS pause on every platform.
    expect(decisionLines().last, contains('jsPause=true'),
        reason: 'a plain site with no background-audio exemption must be '
            'planned for the app-lifecycle JS pause');

    // Drain any beacon already in flight when the pause landed, then measure a
    // clean window.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 1)));
    final windowStart = DateTime.now();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 2)));
    final duringFreeze =
        beacons.where((b) => b.at.isAfter(windowStart)).length;
    log('beacons during 2s post-pause window: $duringFreeze '
        '(platform=${Platform.operatingSystem})');

    if (Platform.isAndroid || Platform.isIOS) {
      // pauseTimers() is real here: setInterval is frozen, so the beacon loop
      // stops. Allow a single straggler for scheduler slack.
      expect(duringFreeze, lessThanOrEqualTo(1),
          reason: 'Android/iOS pauseTimers() must freeze the plain site\'s JS '
              'timers on background — beacons should stop');
    } else {
      // Linux/WPE + macOS: pauseTimers() is a no-op, so JS keeps ticking. Not
      // a failure — just not the platform this direction is provable on.
      log('non-Android platform: JS-freeze not asserted (pauseTimers no-op)');
    }

    // Resume and confirm the timers thaw (beacons flow again) everywhere.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    final resumedAt = DateTime.now();
    await pumpUntil(
      () => beacons.where((b) => b.at.isAfter(resumedAt)).length >= 2,
      description: 'beacons resume after foreground',
    );
    log('resumed: beacons flowing again');
  });
}
