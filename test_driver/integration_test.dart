import 'dart:async';
import 'dart:io';
import 'package:flutter_driver/flutter_driver.dart';
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

/// Flag to stop the watcher when test completes
bool _stopWatcher = false;

/// Check if we're running on Android (by checking for adb)
Future<bool> _isAndroidTarget() async {
  try {
    final result = await Process.run('adb', ['devices']);
    return result.exitCode == 0 && result.stdout.toString().contains('device');
  } catch (e) {
    return false;
  }
}

Future<void> main() async {
  final screenshotDir = Platform.environment['SCREENSHOT_DIR'] ?? 'screenshots';
  
  // Connect to the Flutter driver
  final FlutterDriver driver = await FlutterDriver.connect();
  
  // Only start the native screenshot watcher on Android
  final isAndroid = await _isAndroidTarget();
  if (isAndroid) {
    _stopWatcher = false;
    unawaited(_watchForNativeScreenshotRequests(screenshotDir));
    print('[Driver] Native screenshot watcher started (Android detected)');
  } else {
    print('[Driver] Skipping native screenshot watcher (not Android)');
  }

  await integrationDriver(
    driver: driver,
    onScreenshot: (String screenshotName, List<int> screenshotBytes,
        [Map<String, Object?>? args]) async {
      final file = File('$screenshotDir/$screenshotName.png');
      
      print('[Driver] onScreenshot called: $screenshotName');
      print('[Driver] screenshotBytes length: ${screenshotBytes.length}');
      print('[Driver] Output path: ${file.path}');
      
      await file.create(recursive: true);
      await file.writeAsBytes(screenshotBytes);
      print('[Driver] Screenshot saved: ${file.path}');
      return true;
    },
  );
  
  // Stop the watcher
  _stopWatcher = true;
  if (isAndroid) {
    print('[Driver] Native screenshot watcher stopped');
  }
}

/// Helper to run a future without awaiting (avoids lint warnings)
void unawaited(Future<void> future) {}

/// Watches logcat for native screenshot markers and takes screenshots via ADB.
/// The test prints @@NATIVE_SCREENSHOT:<name>@@ when it wants a native screenshot.
Future<void> _watchForNativeScreenshotRequests(String screenshotDir) async {
  print('[Driver] Native screenshot watcher: starting logcat monitor...');
  
  // Clear logcat first
  await Process.run('adb', ['logcat', '-c']);
  
  // Start logcat process to watch for markers
  final logcat = await Process.start('adb', ['logcat', '-v', 'brief', 'flutter:I', '*:S']);
  
  // Track which screenshots we've already taken to avoid duplicates
  final takenScreenshots = <String>{};
  
  logcat.stdout.transform(const SystemEncoding().decoder).listen((data) async {
    // Look for the marker pattern: @@NATIVE_SCREENSHOT:<name>@@
    final regex = RegExp(r'@@NATIVE_SCREENSHOT:([^@]+)@@');
    final matches = regex.allMatches(data);
    
    for (final match in matches) {
      final screenshotName = match.group(1);
      if (screenshotName != null && !takenScreenshots.contains(screenshotName)) {
        takenScreenshots.add(screenshotName);
        
        print('[Driver] Detected native screenshot request: $screenshotName');
        
        // Small delay to ensure the screen is fully rendered
        await Future.delayed(const Duration(milliseconds: 500));
        
        // Take the screenshot
        final outputPath = '$screenshotDir/$screenshotName.png';
        final success = await _takeNativeScreenshot(outputPath);
        
        if (success) {
          print('[Driver] Native screenshot saved: $outputPath');
        } else {
          print('[Driver] Native screenshot failed: $screenshotName');
        }
      }
    }
  });
  
  // Keep the watcher running until stopped
  while (!_stopWatcher) {
    await Future.delayed(const Duration(milliseconds: 100));
  }
  
  // Kill logcat when done
  logcat.kill();
  print('[Driver] Native screenshot watcher: stopped');
}

/// Takes a native Android screenshot using ADB screencap.
/// This captures the actual screen content including webviews.
/// Hides status bar and navigation bar for clean screenshots.
Future<bool> _takeNativeScreenshot(String outputPath) async {
  try {
    // Hide status bar and navigation bar for clean screenshots
    print('[Driver] Hiding system bars...');
    await Process.run('adb', ['shell', 'settings', 'put', 'global', 'policy_control', 'immersive.full=*']);
    // Give time for the system bars to hide
    await Future.delayed(const Duration(milliseconds: 300));
    
    // Use adb to capture the screen
    // First capture to device, then pull to host
    const devicePath = '/sdcard/screenshot_temp.png';
    
    print('[Driver] Running: adb shell screencap -p $devicePath');
    
    // Capture screenshot on device
    var result = await Process.run('adb', ['shell', 'screencap', '-p', devicePath]);
    if (result.exitCode != 0) {
      print('[Driver] ADB screencap failed: ${result.stderr}');
      await _restoreSystemBars();
      return false;
    }
    
    // Create output directory if needed
    await Directory(outputPath).parent.create(recursive: true);
    
    // Pull screenshot to host
    result = await Process.run('adb', ['pull', devicePath, outputPath]);
    if (result.exitCode != 0) {
      print('[Driver] ADB pull failed: ${result.stderr}');
      await _restoreSystemBars();
      return false;
    }
    
    // Verify file exists and has content
    final file = File(outputPath);
    if (await file.exists()) {
      final size = await file.length();
      print('[Driver] Screenshot file size: $size bytes');
    } else {
      print('[Driver] WARNING: Screenshot file does not exist after pull!');
      await _restoreSystemBars();
      return false;
    }
    
    // Clean up temp file on device
    await Process.run('adb', ['shell', 'rm', devicePath]);
    
    // Restore system bars
    await _restoreSystemBars();
    
    return true;
  } catch (e) {
    print('[Driver] Native screenshot error: $e');
    await _restoreSystemBars();
    return false;
  }
}

/// Restore system status and navigation bars
Future<void> _restoreSystemBars() async {
  print('[Driver] Restoring system bars...');
  await Process.run('adb', ['shell', 'settings', 'put', 'global', 'policy_control', 'null']);
}
