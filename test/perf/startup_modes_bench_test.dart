// Times the cold start in each startup mode, from the first frame to the
// screen the mode lands on and to the end of StartupController.restore.
//
//   WS_PERF=1 fvm flutter test test/perf/startup_modes_bench_test.dart
//
// The real WebSpaceApp runs against a faked platform, so a channel answers at
// once: each number is the Dart work on the UI isolate (which is the Android
// main thread), with none of the device's channel or webview latency. Pair it
// with startup_bench_test.dart beside it, which times the blocker data main() loads
// before runApp. The Home Shortcut mode is not here: a host test runs as
// Linux, where the shortcut channel is never asked.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/app.dart';
import 'package:webspace/screens/webspace_page.dart' show debugStartupRestore;
import 'package:webspace/services/launch_context.dart';
import 'package:webspace/web_view_model.dart';

import '../helpers/real_app.dart';

const _runs = 5;

enum _Mode { launcher, notificationTap, backgroundWake }

List<WebViewModel> _sites(int count) => [
      for (var i = 0; i < count; i++)
        WebViewModel(initUrl: 'https://site$i.example.test', name: 'Site $i')
          ..notificationsEnabled = i % 4 == 0,
    ];

/// One cold start: ms to the first frame, to the screen the mode lands on,
/// and to the end of restore.
Future<({int frame, int landed, int restored})> _coldStart(
  WidgetTester tester, {
  required _Mode mode,
  required int siteCount,
}) async {
  final sites = _sites(siteCount);
  final tapped = sites.last;
  launchedForBackgroundWake = mode == _Mode.backgroundWake;
  await prepareRealApp(
    tester,
    sites: sites,
    launchedByNotificationFor:
        mode == _Mode.notificationTap ? tapped.siteId : null,
  );
  bool landed() => switch (mode) {
        _Mode.notificationTap => find
            .descendant(of: find.byType(AppBar), matching: find.text(tapped.name))
            .evaluate()
            .isNotEmpty,
        _Mode.launcher || _Mode.backgroundWake =>
          find.text('All').evaluate().isNotEmpty,
      };

  var restoreDone = false;
  final sw = Stopwatch()..start();
  await tester.pumpWidget(WebSpaceApp());
  final frame = sw.elapsedMilliseconds;
  unawaited(debugStartupRestore!.then((_) => restoreDone = true));
  int? landedAt;
  while (!restoreDone || landedAt == null) {
    if (landedAt == null && landed()) landedAt = sw.elapsedMilliseconds;
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 16));
    if (sw.elapsed > const Duration(seconds: 30)) {
      fail('$mode with $siteCount sites did not finish');
    }
  }
  final restored = sw.elapsedMilliseconds;
  await tester.pumpWidget(const SizedBox());
  await settleRealApp(tester);
  launchedForBackgroundWake = false;
  return (frame: frame, landed: landedAt, restored: restored);
}

void main() {
  final skip = Platform.environment['WS_PERF'] == null;
  for (final siteCount in [5, 40]) {
    for (final mode in _Mode.values) {
      testWidgets('$mode, $siteCount sites', (tester) async {
        // The first start in a process pays for compiling the app.
        await _coldStart(tester, mode: mode, siteCount: siteCount);
        final runs = [
          for (var i = 0; i < _runs; i++)
            await _coldStart(tester, mode: mode, siteCount: siteCount),
        ];
        int median(int Function(({int frame, int landed, int restored})) f) =>
            (runs.map(f).toList()..sort())[_runs ~/ 2];
        // ignore: avoid_print
        print('${'${mode.name}, $siteCount sites'.padRight(30)}'
            ' first frame ${'${median((r) => r.frame)}'.padLeft(5)} ms'
            '  landed ${'${median((r) => r.landed)}'.padLeft(5)} ms'
            '  restore done ${'${median((r) => r.restored)}'.padLeft(5)} ms');
      }, skip: skip);
    }
  }
}
