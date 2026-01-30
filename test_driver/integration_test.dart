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

/// Directory on device for screenshot signal files
const _signalDir = '/sdcard/screenshot_signals';

/// Flag to stop the watcher when test completes
bool _stopWatcher = false;

Future<void> main() async {
  final screenshotDir = Platform.environment['SCREENSHOT_DIR'] ?? 'screenshots';
  
  // Connect to the Flutter driver
  final FlutterDriver driver = await FlutterDriver.connect();
  
  // Start background task to watch for native screenshot requests
  // This runs concurrently with the integration driver
  _stopWatcher = false;
  unawaited(_watchForNativeScreenshotRequests(screenshotDir));
  print('[Driver] Native screenshot watcher started');

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
  print('[Driver] Native screenshot watcher stopped');
}

/// Helper to run a future without awaiting (avoids lint warnings)
void unawaited(Future<void> future) {}

/// Watches for native screenshot request files on the device.
/// When a request is found, takes a screenshot via ADB and signals completion.
Future<void> _watchForNativeScreenshotRequests(String screenshotDir) async {
  print('[Driver] Native screenshot watcher: initializing...');
  
  // Create signal directory on device
  var result = await Process.run('adb', ['shell', 'mkdir', '-p', _signalDir]);
  print('[Driver] mkdir result: ${result.exitCode}');
  
  // Clean up any old signal files
  await Process.run('adb', ['shell', 'rm', '-rf', '$_signalDir/*']);
  print('[Driver] Cleaned up old signal files');
  
  print('[Driver] Native screenshot watcher: polling for requests...');
  
  while (!_stopWatcher) {
    try {
      // List request files using find instead of ls for better reliability
      final result = await Process.run('adb', ['shell', 'find', _signalDir, '-name', '*_request', '-type', 'f']);
      final output = result.stdout.toString().trim();
      
      if (output.isNotEmpty && !output.contains('No such file')) {
        // Parse request files
        final requestFiles = output.split('\n').where((f) => f.trim().isNotEmpty && f.endsWith('_request')).toList();
        
        for (final requestFile in requestFiles) {
          // Extract screenshot name from request file path
          final fileName = requestFile.split('/').last;
          final screenshotName = fileName.replaceAll('_request', '');
          
          print('[Driver] Found native screenshot request: $screenshotName');
          
          // Take the screenshot
          final outputPath = '$screenshotDir/$screenshotName.png';
          final success = await _takeNativeScreenshot(outputPath);
          
          if (success) {
            print('[Driver] Native screenshot saved: $outputPath');
          } else {
            print('[Driver] Native screenshot failed: $screenshotName');
          }
          
          // Signal completion by creating done file
          final doneFile = '$_signalDir/${screenshotName}_done';
          await Process.run('adb', ['shell', 'touch', doneFile]);
          print('[Driver] Signaled completion: $doneFile');
          
          // Remove the request file
          await Process.run('adb', ['shell', 'rm', '-f', requestFile]);
        }
      }
    } catch (e) {
      print('[Driver] Watcher error: $e');
    }
    
    // Poll every 100ms for faster response
    await Future.delayed(const Duration(milliseconds: 100));
  }
  
  print('[Driver] Native screenshot watcher: stopped');
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
    if (result.exitCode != 0) {
      print('[Driver] ADB screencap failed: ${result.stderr}');
      return false;
    }
    
    // Create output directory if needed
    await Directory(outputPath).parent.create(recursive: true);
    
    // Pull screenshot to host
    result = await Process.run('adb', ['pull', devicePath, outputPath]);
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
      return false;
    }
    
    // Clean up temp file on device
    await Process.run('adb', ['shell', 'rm', devicePath]);
    
    return true;
  } catch (e) {
    print('[Driver] Native screenshot error: $e');
    return false;
  }
}
