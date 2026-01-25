import 'dart:io';
import 'package:integration_test/integration_test_driver_extended.dart';

/// Test driver for integration tests with screenshot capture
///
/// This saves screenshots to platform-specific directories when using
/// `flutter drive` command.
///
/// Usage:
///   # For Android
///   TARGET_PLATFORM=android flutter drive \
///     --driver=test_driver/integration_test.dart \
///     --target=integration_test/screenshot_test.dart
///
///   # For iOS
///   TARGET_PLATFORM=ios flutter drive \
///     --driver=test_driver/integration_test.dart \
///     --target=integration_test/screenshot_test.dart
///
/// Screenshots locations:
///   - Android: fastlane/metadata/android/en-US/images/phoneScreenshots/
///   - iOS: fastlane/metadata/ios/en-US/images/phoneScreenshots/
///   - Other: screenshots/
///
/// Environment variables:
///   - TARGET_PLATFORM: 'android' or 'ios' (required for correct path)
///   - SCREENSHOT_DIR: Override screenshot directory (optional)
Future<void> main() async {
  await integrationDriver(
    onScreenshot: (String screenshotName, List<int> screenshotBytes, [Map<String, Object?>? args]) async {
      // Check for custom directory from environment variable
      String? screenshotDir = Platform.environment['SCREENSHOT_DIR'];

      // If not set, use platform-specific defaults based on TARGET_PLATFORM
      if (screenshotDir == null) {
        final targetPlatform = Platform.environment['TARGET_PLATFORM']?.toLowerCase();

        if (targetPlatform == 'android') {
          screenshotDir = 'fastlane/metadata/android/en-US/images/phoneScreenshots';
        } else if (targetPlatform == 'ios') {
          screenshotDir = 'fastlane/metadata/ios/en-US/images/phoneScreenshots';
        } else {
          // Fallback for unspecified platform
          screenshotDir = 'screenshots';
          if (targetPlatform == null) {
            print('Warning: TARGET_PLATFORM not set. Using default screenshots/ directory.');
            print('Set TARGET_PLATFORM=android or TARGET_PLATFORM=ios for correct paths.');
          }
        }
      }

      final file = File('$screenshotDir/$screenshotName.png');
      await file.create(recursive: true);
      await file.writeAsBytes(screenshotBytes);
      print('Screenshot saved: ${file.path}');
      return true;
    },
  );
}
