import 'dart:io';
import 'package:integration_test/integration_test_driver_extended.dart';

/// Test driver for integration tests with screenshot capture
///
/// IMPORTANT: The SCREENSHOT_DIR environment variable should be set by the
/// calling script (e.g., fastlane) to specify where screenshots should be saved.
/// This driver runs on the HOST machine, not the target device, so it cannot
/// reliably detect the target platform at runtime.
///
/// Usage:
///   SCREENSHOT_DIR=path/to/screenshots flutter drive \
///     --driver=test_driver/integration_test.dart \
///     --target=integration_test/screenshot_test.dart
///
/// Fastlane sets SCREENSHOT_DIR automatically based on the target platform.
/// For manual runs without SCREENSHOT_DIR, screenshots go to 'screenshots/'.
Future<void> main() async {
  final screenshotDir = Platform.environment['SCREENSHOT_DIR'] ?? 'screenshots';

  await integrationDriver(
    onScreenshot: (String screenshotName, List<int> screenshotBytes,
        [Map<String, Object?>? args]) async {
      final file = File('$screenshotDir/$screenshotName.png');
      await file.create(recursive: true);
      await file.writeAsBytes(screenshotBytes);
      print('Screenshot saved: ${file.path}');
      return true;
    },
  );
}
