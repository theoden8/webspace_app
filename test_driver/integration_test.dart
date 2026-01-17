import 'dart:io';
import 'package:integration_test/integration_test_driver_extended.dart';

/// Test driver for integration tests with screenshot capture
/// 
/// This saves screenshots to the 'screenshots/' directory when using
/// `flutter drive` command.
/// 
/// Usage:
///   flutter drive \
///     --driver=test_driver/integration_test.dart \
///     --target=integration_test/screenshot_test.dart
/// 
/// Screenshots will be saved to: screenshots/<name>.png
Future<void> main() async {
  await integrationDriver(
    onScreenshot: (String screenshotName, List<int> screenshotBytes, [Map<String, Object?>? args]) async {
      final file = File('screenshots/$screenshotName.png');
      await file.create(recursive: true);
      await file.writeAsBytes(screenshotBytes);
      print('Screenshot saved: ${file.path}');
      return true;
    },
  );
}
