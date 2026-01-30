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
      // Check if this screenshot should use native capture
      // The integration test adds __native__ marker for webview screenshots
      final useNativeForThis = screenshotName.contains('__native__') || useNativeScreenshots;
      
      // Remove the __native__ marker from the filename
      final cleanName = screenshotName.replaceAll('__native__', '');
      final file = File('$screenshotDir/$cleanName.png');
      
      print('[Driver] onScreenshot called: $screenshotName');
      print('[Driver] useNativeForThis: $useNativeForThis');
      print('[Driver] screenshotBytes length: ${screenshotBytes.length}');
      print('[Driver] Output path: ${file.path}');
      
      await file.create(recursive: true);
      
      if (useNativeForThis) {
        // Use ADB screencap to capture the actual screen including webviews
        // This bypasses Flutter's surface capture which misses platform views
        print('[Driver] Using native screenshot for: $cleanName');
        final success = await _takeNativeScreenshot(file.path);
        if (success) {
          print('[Driver] Native screenshot saved: ${file.path}');
          return true;
        }
        // Fall back to Flutter screenshot if native fails
        print('[Driver] Native screenshot failed, falling back to Flutter screenshot');
      }
      
      await file.writeAsBytes(screenshotBytes);
      print('[Driver] Screenshot saved: ${file.path}');
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
    
    print('[Driver] Running: adb shell screencap -p $devicePath');
    
    // Capture screenshot on device
    var result = await Process.run('adb', ['shell', 'screencap', '-p', devicePath]);
    print('[Driver] screencap exitCode: ${result.exitCode}');
    print('[Driver] screencap stdout: ${result.stdout}');
    print('[Driver] screencap stderr: ${result.stderr}');
    if (result.exitCode != 0) {
      print('[Driver] ADB screencap failed: ${result.stderr}');
      return false;
    }
    
    print('[Driver] Running: adb pull $devicePath $outputPath');
    
    // Pull screenshot to host
    result = await Process.run('adb', ['pull', devicePath, outputPath]);
    print('[Driver] pull exitCode: ${result.exitCode}');
    print('[Driver] pull stdout: ${result.stdout}');
    print('[Driver] pull stderr: ${result.stderr}');
    if (result.exitCode != 0) {
      print('[Driver] ADB pull failed: ${result.stderr}');
      return false;
    }
    
    // Verify file exists and has content
    final file = File(outputPath);
    if (await file.exists()) {
      final size = await file.length();
      print('[Driver] Screenshot file size: $size bytes');
    } else {
      print('[Driver] WARNING: Screenshot file does not exist after pull!');
    }
    
    // Clean up temp file on device
    await Process.run('adb', ['shell', 'rm', devicePath]);
    
    return true;
  } catch (e) {
    print('[Driver] Native screenshot error: $e');
    return false;
  }
}
