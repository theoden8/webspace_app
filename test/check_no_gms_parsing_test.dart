@Tags(['ci'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Parsing-level guard for `scripts/check_no_gms.sh`. The full
/// `gms_freedom_test.dart` needs a real APK + the Android SDK's
/// `apkanalyzer`, so it skips locally. This test instead stubs
/// `apkanalyzer` with canned `dex packages` output and asserts the script
/// classifies it correctly — in particular that a *referenced* (state "r")
/// forbidden class fails the check, since Flutter's embedding only
/// references com.google.android.play.core.* and an earlier
/// `--defined-only` scan let that slip past F-Droid's stricter scanner.
void main() {
  late Directory tmp;
  final script = File('scripts/check_no_gms.sh').absolute.path;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('check_no_gms_test');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// Writes an executable `apkanalyzer` stub emitting [tree] for any
  /// invocation, returns the result of running the checker against it.
  Future<ProcessResult> runWithStub(String tree) async {
    final stub = File('${tmp.path}/apkanalyzer');
    stub.writeAsStringSync('#!/usr/bin/env bash\ncat <<\'EOF\'\n$tree\nEOF\n');
    Process.runSync('chmod', ['+x', stub.path]);

    final apk = File('${tmp.path}/app-fdroid-release.apk')..writeAsStringSync('stub');

    return Process.run(
      'bash',
      [script, apk.path],
      environment: {'PATH': '${tmp.path}:${Platform.environment['PATH']}'},
    );
  }

  test('referenced (state r) play.core class fails the check', () async {
    // Column layout mirrors `apkanalyzer dex packages`: node-type, state,
    // counts, then the fully-qualified name as the final field. The
    // play.core rows are state "r" (referenced, not defined) — exactly what
    // --defined-only used to hide.
    final result = await runWithStub('''
P d 3 3 100 com.example.app
C d 2 2 80 com.example.app.MainActivity
P r 0 2 0 com.google.android.play.core.splitinstall
C r 0 1 0 com.google.android.play.core.splitinstall.SplitInstallManager
C r 0 1 0 com.google.android.play.core.tasks.OnSuccessListener
''');

    expect(result.exitCode, 1,
        reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}');
    expect(result.stderr.toString(),
        contains('com.google.android.play.core.splitinstall'));
  });

  test('clean tree passes', () async {
    final result = await runWithStub('''
P d 3 3 100 com.example.app
C d 2 2 80 com.example.app.MainActivity
P d 1 1 40 androidx.webkit
C d 1 1 40 androidx.webkit.WebViewCompat
''');

    expect(result.exitCode, 0,
        reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}');
  });

  test('defined gms class still fails', () async {
    final result = await runWithStub('''
P d 1 1 40 com.google.android.gms.common
C d 1 1 40 com.google.android.gms.common.GoogleApiAvailability
''');

    expect(result.exitCode, 1,
        reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}');
  });

  test('apkanalyzer failure is a hard error, not a false OK', () async {
    final stub = File('${tmp.path}/apkanalyzer');
    stub.writeAsStringSync('#!/usr/bin/env bash\necho "boom" >&2\nexit 1\n');
    Process.runSync('chmod', ['+x', stub.path]);
    final apk = File('${tmp.path}/app-fdroid-release.apk')..writeAsStringSync('stub');

    final result = await Process.run(
      'bash',
      [script, apk.path],
      environment: {'PATH': '${tmp.path}:${Platform.environment['PATH']}'},
    );

    expect(result.exitCode, 2,
        reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}');
  });
}
