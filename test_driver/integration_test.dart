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
  
  // Check if we should use native Android screenshots (captures webviews)
  // This is set by the integration test when it needs to capture platform views
  final useNativeScreenshots = Platform.environment['USE_NATIVE_SCREENSHOTS'] == 'true';

  await integrationDriver(
    onScreenshot: (String screenshotName, List<int> screenshotBytes,
        [Map<String, Object?>? args]) async {
      final file = File('$screenshotDir/$screenshotName.png');
      await file.create(recursive: true);
      
      // Check if this specific screenshot should use native capture
      // The integration test can pass 'native: true' in args for webview screenshots
      final useNativeForThis = args?['native'] == true || useNativeScreenshots;
      
      if (useNativeForThis) {
        // Use ADB screencap to capture the actual screen including webviews
        // This bypasses Flutter's surface capture which misses platform views
        print('Using native screenshot for: $screenshotName');
        final success = await _takeNativeScreenshot(file.path);
        if (success) {
          print('Native screenshot saved: ${file.path}');
          return true;
        }
        // Fall back to Flutter screenshot if native fails
        print('Native screenshot failed, falling back to Flutter screenshot');
      }
      
      await file.writeAsBytes(screenshotBytes);
      print('Screenshot saved: ${file.path}');
      return true;
    },
  );
}

/// Takes a native Android screenshot using ADB screencap.
/// This captures the actual screen content including webviews.
Future<bool> _takeNativeScreenshot(String outputPath) async {
  try {
    // Use adb to capture the screen
    // First capture to device, then pull to host
    const devicePath = '/sdcard/screenshot_temp.png';
    
    // Capture screenshot on device
    var result = await Process.run('adb', ['shell', 'screencap', '-p', devicePath]);
    if (result.exitCode != 0) {
      print('ADB screencap failed: ${result.stderr}');
      return false;
    }
    
    // Pull screenshot to host
    result = await Process.run('adb', ['pull', devicePath, outputPath]);
    if (result.exitCode != 0) {
      print('ADB pull failed: ${result.stderr}');
      return false;
    }
    
    // Clean up temp file on device
    await Process.run('adb', ['shell', 'rm', devicePath]);
    
    return true;
  } catch (e) {
    print('Native screenshot error: $e');
    return false;
  }
}
