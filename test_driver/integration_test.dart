import 'dart:io';
import 'package:integration_test/integration_test_driver_extended.dart';

/// Test driver for integration tests with screenshot capture
/// 
/// This saves screenshots to platform-specific directories when using
/// `flutter drive` command.
/// 
/// Usage:
///   flutter drive \
///     --driver=test_driver/integration_test.dart \
///     --target=integration_test/screenshot_test.dart
/// 
/// Screenshots locations:
///   - Android: fastlane/metadata/android/en-US/images/phoneScreenshots/
///   - iOS: fastlane/metadata/ios/en-US/images/phoneScreenshots/ (if uncommented)
///   - Desktop: screenshots/
/// 
/// Set SCREENSHOT_DIR environment variable to override:
///   SCREENSHOT_DIR=my/custom/path flutter drive ...
Future<void> main() async {
  await integrationDriver(
    onScreenshot: (String screenshotName, List<int> screenshotBytes, [Map<String, Object?>? args]) async {
      // Check for custom directory from environment variable
      String? screenshotDir = Platform.environment['SCREENSHOT_DIR'];
      
      // If not set, use platform-specific defaults
      if (screenshotDir == null) {
        // Detect the actual runtime platform
        if (Platform.isAndroid) {
          // Save to fastlane directory for Android
          screenshotDir = 'fastlane/metadata/android/en-US/images/phoneScreenshots';
        } else if (Platform.isIOS) {
          // For iOS, you can use fastlane directory too
          // screenshotDir = 'fastlane/metadata/ios/en-US/images/phoneScreenshots';
          screenshotDir = 'screenshots';
        } else {
          // Desktop or other platforms
          screenshotDir = 'screenshots';
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
