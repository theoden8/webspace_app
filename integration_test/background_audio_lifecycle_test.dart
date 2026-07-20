// Background-audio lifecycle integration test (BGAUDIO-001/002).
//
// CI-testable "background mode": real OS backgrounding cannot be driven from
// a Flutter integration test, but the app's entire lifecycle path hangs off
// `WidgetsBindingObserver.didChangeAppLifecycleState`, and the test binding
// can inject those transitions via `handleAppLifecycleStateChanged` (which
// also synthesizes the legal intermediate states). Two observables make the
// result assertable without reaching into private app state:
//
//   1. The non-sensitive `Lifecycle`/`App background: jsPause=...` LogService
//      line records the engine decision (pause vs background-audio/notif
//      exemption) on every backgrounding — the same line a user would share
//      from App Logs.
//   2. The HTML fixture (integration_test/fixtures/background_audio.html)
//      beacons `GET /beacon?ticks=N&audio=...` to the loopback server every
//      250 ms from a JS interval timer. Beacons observed server-side prove
//      the page's JS is genuinely alive through the backgrounded window —
//      no bridge into the webview needed.
//
// Note on the negative control: on Linux (WPE) and macOS the plugin has no
// `pauseTimers()` implementation, so a *non*-exempt site's JS would keep
// beaconing on these CI targets anyway — "beacons stop" is only assertable
// on Android/iOS hardware. The decision matrix (pause vs exempt, the
// any-loaded-background-audio veto) is covered by
// test/app_lifecycle_engine_test.dart; this test proves the end-to-end
// wiring and real-engine JS liveness for the exempt path.

import 'dart:async';
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
import 'dart:convert';

import 'fixtures/background_audio_fixture.dart';

class _Beacon {
  _Beacon(this.at, this.ticks, this.audioState);
  final DateTime at;
  final int ticks;
  final String audioState;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  late int port;
  final beacons = <_Beacon>[];
  // Served from the embedded mirror, not from disk: the test app cannot read
  // repo files at runtime (macOS CI denies with EPERM under the ad-hoc
  // entitlements). Drift vs the authoritative .html is enforced by
  // test/background_audio_fixture_drift_test.dart.
  const fixtureHtml = backgroundAudioFixtureHtml;

  void log(String m) {
    // ignore: avoid_print
    print('[bgaudio] $m');
  }

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    server.listen((req) {
      if (req.uri.path == '/beacon') {
        beacons.add(_Beacon(
          DateTime.now(),
          int.tryParse(req.uri.queryParameters['ticks'] ?? '') ?? -1,
          req.uri.queryParameters['audio'] ?? '?',
        ));
        req.response
          ..statusCode = 204
          ..close();
        return;
      }
      final res = req.response..headers.contentType = ContentType.html;
      res.write(fixtureHtml);
      res.close();
    });

    isDemoMode = true;
    final audioSite = WebViewModel(
      siteId: 'bg-audio',
      initUrl: 'http://127.0.0.1:$port/',
      name: 'BG Audio',
      backgroundAudioEnabled: true,
    );
    SharedPreferences.setMockInitialValues({
      'webViewModels': [jsonEncode(audioSite.toJson())],
    });
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  testWidgets(
      'background-audio site keeps its JS alive across an app-lifecycle '
      'background window', (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 30));

    // Wall-clock wait that keeps pumping frames: a live WebView wedges
    // pumpAndSettle, and beacon arrival needs no frames but drawer/UI
    // transitions do.
    Future<void> pumpUntil(
      bool Function() predicate, {
      Duration timeout = const Duration(seconds: 60),
      Duration step = const Duration(milliseconds: 250),
      required String description,
    }) async {
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        await tester.pump(step);
        // pump() advances fake-async test time, not wall-clock; the beacons
        // arrive on real time, so also yield real time inside runAsync.
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
        if (predicate()) return;
      }
      throw StateError(
          'Timed out after ${timeout.inSeconds}s waiting for: $description');
    }

    // Activate the site through the drawer, same as lazy_webview_loading.
    await tester.tap(find.byKey(const ValueKey(kAllWebspaceId)));
    await tester.pumpAndSettle(const Duration(seconds: 5));
    final tile = find.text('BG Audio');
    expect(tile, findsOneWidget, reason: 'site should appear in the drawer');
    await tester.tap(tile);

    await pumpUntil(
      () => beacons.isNotEmpty,
      description: 'first beacon from the fixture page (webview mounted, '
          'JS running)',
    );
    log('first beacon: ticks=${beacons.first.ticks} '
        'audio=${beacons.first.audioState}');

    // Send the app to background. handleAppLifecycleStateChanged
    // synthesizes the legal inactive/hidden intermediates; the app handler
    // acts on `paused` only (issue #308). While the state is `paused` the
    // framework stops scheduling frames, so no tester.pump() until after
    // the resume — the observations below need no frames (the handler logs
    // synchronously; beacons arrive on native networking).
    tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final pausedAt = DateTime.now();

    // The decision line must show the background-audio exemption: no JS
    // pause was issued for this backgrounding.
    List<String> decisionLines() => LogService.instance.allEntriesMerged
        .where((e) => e.message.startsWith('App background: '))
        .map((e) => e.message)
        .toList();
    expect(decisionLines(), isNotEmpty,
        reason: 'didChangeAppLifecycleState(paused) logs its plan '
            'synchronously');
    expect(decisionLines().last, contains('jsPause=false'),
        reason: 'a loaded background-audio site must veto the app-lifecycle '
            'JS pause (BGAUDIO-002)');
    expect(decisionLines().last, contains('capture=true'),
        reason: 'state capture is not gated on the exemption');

    // JS liveness through the backgrounded window: >= 4 beacons over 3 s of
    // wall-clock (the fixture fires every 250 ms; the margin absorbs slow CI).
    int beaconsSince(DateTime t) =>
        beacons.where((b) => b.at.isAfter(t)).length;
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 3)));
    final backgrounded = beaconsSince(pausedAt);
    log('beacons while backgrounded: $backgrounded');
    expect(backgrounded, greaterThanOrEqualTo(4),
        reason: 'the fixture page must keep ticking while the app is '
            'backgrounded — the whole point of the background-audio toggle');

    // Ticks must be monotonically increasing (same page, never reloaded or
    // recreated by the pause path).
    final ticksSeq = beacons.map((b) => b.ticks).toList();
    for (var i = 1; i < ticksSeq.length; i++) {
      expect(ticksSeq[i], greaterThan(ticksSeq[i - 1]),
          reason: 'beacon ticks reset — the page was reloaded during the '
              'lifecycle round-trip');
    }

    // Resume and verify the page is still the same live instance.
    tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    final resumedAt = DateTime.now();
    await pumpUntil(
      () => beaconsSince(resumedAt) >= 2,
      description: 'beacons after resume',
    );
    log('audio state on last beacon: ${beacons.last.audioState}');
  });
}
