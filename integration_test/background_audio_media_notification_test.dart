// Background-audio media-notification integration test (BGAUDIO-006).
//
// The other two background-audio tests load the fixture with `?media=none`
// and assert JS-timer liveness (BGAUDIO-001/002). That leaves the media
// notification — the user-visible half of the feature — with no runtime
// coverage at all: nothing plays, so the shim never reports `playing: true`,
// `MediaSessionService` never invokes the channel, and the foreground service
// never starts.
//
// This test closes that gap on the one platform the notification exists on.
// It plays real media in the real Android WebView and asserts the end of the
// chain the user actually sees: `NotificationManager.getActiveNotifications()`
// contains our notification. That distinguishes the two failure modes a Dart
// -side assertion cannot — "the channel call was made" versus "the OS put
// something on screen" — which is exactly the difference a denied
// POST_NOTIFICATIONS produces.
//
// Runs in the Android emulator tier only
// (scripts/run_android_background_audio_tests.sh, which pre-grants
// POST_NOTIFICATIONS); it self-skips elsewhere, and the Linux/macOS
// integration loops exclude it by name.

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
  _Beacon(this.at, this.ticks, this.playState, this.currentTime, this.paused);
  final DateTime at;
  final int ticks;
  final String playState;
  final double currentTime;
  final String paused;

  /// What the BGAUDIO-006 shim's own predicate looks for.
  bool get mediaLive => paused == 'false' && currentTime > 0;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  late int port;
  final beacons = <_Beacon>[];

  void log(String m) {
    // ignore: avoid_print
    print('[bgaudio-notif] $m');
  }

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    server.listen((req) {
      if (req.uri.path == '/beacon') {
        final q = req.uri.queryParameters;
        beacons.add(_Beacon(
          DateTime.now(),
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
    // `?media=stream`: a muted <video> off a canvas captureStream. It hits the
    // same element surface and playing/currentTime predicate the shim watches,
    // without depending on an audio device — the CI emulator boots -noaudio.
    final audioSite = WebViewModel(
      siteId: 'bg-audio-notif',
      initUrl: 'http://127.0.0.1:$port/?media=stream',
      name: 'BG Audio Notif',
      backgroundAudioEnabled: true,
    );
    SharedPreferences.setMockInitialValues({
      'webViewModels': [jsonEncode(audioSite.toJson())],
    });
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  testWidgets('playing background-audio site posts an OS media notification',
      (tester) async {
    if (!Platform.isAndroid) {
      log('skipped: BGAUDIO-006 is Android-only '
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

    Future<bool> posted() async {
      final result = await tester
          .runAsync(() => MediaSessionService.instance.notificationPosted());
      return result ?? false;
    }

    List<String> mediaLines() => LogService.instance.allEntriesMerged
        .where((e) => e.tag == 'MediaSession')
        .map((e) => e.message)
        .toList();

    await tester.tap(find.byKey(const ValueKey(kAllWebspaceId)));
    await tester.pumpAndSettle(const Duration(seconds: 5));
    final tile = find.text('BG Audio Notif');
    expect(tile, findsOneWidget, reason: 'site should appear in the drawer');
    await tester.tap(tile);

    await pumpUntil(
      () => beacons.isNotEmpty,
      description: 'first beacon (webview mounted, JS running)',
    );
    log('first beacon: play=${beacons.first.playState}');

    // The whole chain is downstream of the page actually playing something, so
    // fail here with the page's own diagnosis rather than blaming the bridge.
    await pumpUntil(
      () => beacons.any((b) => b.mediaLive),
      description: 'the fixture media to report itself playing '
          '(last beacon: ${beacons.isEmpty ? "none" : beacons.last.playState})',
    );
    log('media live: play=${beacons.lastWhere((b) => b.mediaLive).playState}');

    // Page JS -> wsMediaSession -> MediaSessionService -> method channel.
    await pumpUntil(
      () => mediaLines().any((m) => m.contains('Notification raised')),
      description: 'MediaSessionService to raise the notification '
          '(BGAUDIO-006 page-JS bridge)',
    );
    expect(MediaSessionService.instance.isActive, isTrue);

    // ...and the part no Dart-side assertion can stand in for: the OS has it.
    await pumpUntil(
      () => true,
      timeout: const Duration(seconds: 2),
      description: 'settle after the raise',
    );
    expect(await posted(), isTrue,
        reason: 'the mediaPlayback foreground service must post a notification '
            'the user can actually see. A false here with "Notification '
            'raised" logged means the service started but the OS suppressed '
            'the notification — check POST_NOTIFICATIONS.');
    expect(
        mediaLines().any((m) => m.contains('not posted by the OS')), isFalse);

    // The notification exists to survive backgrounding — assert it does, and
    // that the page kept feeding it (BGAUDIO-002's exemption still applies).
    final beforeBackground = beacons.length;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 3)));
    expect(beacons.length, greaterThan(beforeBackground),
        reason: 'background-audio site must keep ticking while backgrounded');
    expect(await posted(), isTrue,
        reason: 'the media notification must survive app-background — that is '
            'the whole point of the foreground service');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    // Teardown: `_updateBackgroundAudioSession` calls stopAll when no
    // background-audio site is loaded. Drive the same public entry point and
    // assert the OS notification is really gone, not just the Dart flag.
    await tester.runAsync(() => MediaSessionService.instance.stopAll());
    await pumpUntil(
      () => true,
      timeout: const Duration(seconds: 2),
      description: 'settle after teardown',
    );
    expect(MediaSessionService.instance.isActive, isFalse);
    expect(await posted(), isFalse,
        reason: 'stopAll must remove the notification, not just stop the '
            'foreground state');
    log('teardown verified');
  });
}
