@Tags(['ci'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// CI-only integrity check: the built F-Droid APK must contain zero
/// classes from `com.google.android.gms`, `com.google.firebase`, or
/// `com.google.android.play`. The check is deliberately performed
/// against the *built* APK (not Gradle's dependency graph) because
/// transitive dependencies, vendored jars, and build-time codegen can
/// each smuggle GMS classes past a `./gradlew app:dependencies` audit.
///
/// Run locally:
///   fvm flutter build apk --flavor fdroid --release
///   fvm flutter test --tags ci test/gms_freedom_test.dart
///
/// CI calls `scripts/check_no_gms.sh` directly so a missing APK is a
/// hard failure rather than a skipped test.
void main() {
  test('built fdroid APK contains no com.google.android.gms classes',
      () async {
    final apk =
        File('build/app/outputs/flutter-apk/app-fdroid-release.apk');
    if (!apk.existsSync()) {
      // Local-dev convenience: skip when the build hasn't been run.
      // CI calls the shell script directly so this can't be a false-negative
      // gate there.
      markTestSkipped(
        'APK not built — run `fvm flutter build apk --flavor fdroid --release`',
      );
      return;
    }

    final result = await Process.run(
      'bash',
      ['scripts/check_no_gms.sh', apk.path],
    );

    expect(
      result.exitCode,
      0,
      reason:
          'check_no_gms.sh failed.\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}',
    );
  });
}
