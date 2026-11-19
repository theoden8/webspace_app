import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/main.dart' as app;
import 'package:webspace/demo_data.dart';

import 'helpers/library_tour.dart';

/// Check if device is iPad based on screen size
bool _isTablet(WidgetTester tester) {
  final size = tester.view.physicalSize / tester.view.devicePixelRatio;
  // iPad typically has shortest side > 600dp
  final shortestSide = size.shortestSide;
  return shortestSide > 600;
}

/// Set device orientation based on device type
/// iPad: landscape, iPhone: portrait
Future<void> _setDeviceOrientation(WidgetTester tester) async {
  if (Platform.isIOS) {
    if (_isTablet(tester)) {
      print('iPad detected - setting landscape orientation');
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      print('iPhone detected - setting portrait orientation');
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    }
    await tester.pump();
    if (_isTablet(tester)) await _awaitLandscape(tester);
  }
}

/// iPadOS honours the lock only for an app that opts out of multitasking,
/// which the iPad screenshot lane's build does (UIRequiresFullScreen). Any
/// other build would take the iPad set in portrait.
Future<void> _awaitLandscape(WidgetTester tester) async {
  bool portrait() =>
      tester.view.physicalSize.width <= tester.view.physicalSize.height;
  for (var tries = 0; portrait(); tries++) {
    expect(tries, lessThan(50),
        reason: 'the iPad stayed in portrait; take the set with '
            '`fastlane ios screenshots device:ipad`, which builds with '
            'UIRequiresFullScreen');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
}

/// The desktop Runners' debug-only channel (macos/Runner/WindowCapturePlugin.swift,
/// linux/window_capture.cc). Flutter's integration_test plugin cannot capture
/// on either.
const _windowCapture =
    MethodChannel('org.codeberg.theoden8.webspace/window_capture');

final _capturesWindow = Platform.isMacOS || Platform.isLinux;

/// The Mac window, title bar included. It images at 2880x1800 on a 2x display
/// and 1440x900 on a 1x one, both sizes App Store Connect takes for a Mac app.
const _macWindowPoints = Size(1440, 900);
const _macStoreSizes = {(1280, 800), (1440, 900), (2560, 1600), (2880, 1800)};

/// The Linux view. GTK sizes a window below its title bar, and the title bar
/// and shadow it draws around this keep the window inside the 1000x700
/// Flathub sets for a screenshot.
const _linuxViewPoints = Size(1000, 650);

Future<void> _sizeWindow(WidgetTester tester) async {
  if (!_capturesWindow) return;
  final size = Platform.isMacOS ? _macWindowPoints : _linuxViewPoints;
  await _windowCapture.invokeMethod<void>('resize', {
    'width': size.width,
    'height': size.height,
  });
  await tester.pumpAndSettle();
  if (!Platform.isLinux) return;
  // GTK resizes once the window system confirms it, after `resize` returns.
  for (var tries = 0; _viewPoints(tester) != _linuxViewPoints; tries++) {
    expect(tries, lessThan(50),
        reason: 'the view is ${_viewPoints(tester)}, not $_linuxViewPoints');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
}

Size _viewPoints(WidgetTester tester) =>
    tester.view.physicalSize / tester.view.devicePixelRatio;

/// Hands the window to the driver the way [IntegrationTestWidgetsFlutterBinding.takeScreenshot]
/// does on iOS: as an entry of the report's `screenshots` list, which
/// `integrationDriver` writes out through `onScreenshot`.
Future<void> _captureWindow(
  IntegrationTestWidgetsFlutterBinding binding, {
  required String name,
}) async {
  final png = (await _windowCapture.invokeMethod<Uint8List>('capture'))!;
  if (Platform.isMacOS) {
    final size = _pngSize(png);
    expect(_macStoreSizes, contains(size),
        reason: '$name is ${size.$1}x${size.$2}, not a Mac App Store size');
  }
  final report = binding.reportData ??= <String, dynamic>{};
  final shots = (report['screenshots'] ??= <dynamic>[]) as List<dynamic>;
  shots.add(<String, dynamic>{'screenshotName': name, 'bytes': png});
}

/// Flutter integration test for generating F-Droid and Play Store screenshots.
///
/// This test seeds demo data automatically on startup and navigates through
/// the app to capture screenshots at key points. Screenshots are captured
/// for both light and dark themes.
///
/// To run this test and generate screenshots:
/// 1. flutter test integration_test/screenshot_test.dart
/// 2. Or use with flutter_driver for automated screenshot capture

// Timeout constants
const Duration _WEBVIEW_LOAD_TIMEOUT = Duration(seconds: 15);
const Duration _SCREENSHOT_TIMEOUT = Duration(seconds: 10);

/// Android runs the tour with its webviews drawn into a texture (PAUSE-032,
/// SCREENSHOT-008), so the FlutterView that `takeScreenshot` copies holds the page.
final _androidTextureMode = <String, Object>{
  // Through the gate main() reads (DEVTOOLS-011); developer mode adds nothing to the four screens shot.
  AppPref.developerMode.key: true,
  AppPref.experimentalTextureRendering.key: true,
};

/// A PNG's pixel size, read from its IHDR chunk.
(int, int) _pngSize(List<int> png) {
  final header = ByteData.sublistView(Uint8List.fromList(png.take(24).toList()));
  return (header.getUint32(16), header.getUint32(20));
}

/// Helper to take a screenshot with both light and dark themes.
/// Takes the current theme screenshot first, then toggles to the other theme,
/// takes that screenshot, and toggles back.
/// On macOS and Linux the shot is the window, through the Runner's capture
/// channel.
Future<void> _takeThemedScreenshots(
  IntegrationTestWidgetsFlutterBinding binding, {
  required WidgetTester tester,
  required String baseName,
  required String currentTheme,
}) async {
  final themeSuffix = currentTheme == 'light' ? '-light' : '-dark';
  final screenshotName = '$baseName$themeSuffix';

  print('Capturing $screenshotName');

  // Pump before screenshot to ensure all pending frame updates are processed
  // This is important for native platform views (webviews) which render asynchronously
  await tester.pump();

  if (_capturesWindow) {
    await _captureWindow(binding, name: screenshotName);
  } else {
    final png = await binding
        .takeScreenshot(screenshotName)
        .timeout(_SCREENSHOT_TIMEOUT);
    if (Platform.isAndroid) {
      // A PixelCopy of exactly the FlutterView's rectangle: any other size is
      // not the frame this view drew.
      expect(png.length, greaterThan(24),
          reason: '$screenshotName is not a PNG');
      final view = tester.view.physicalSize;
      expect(_pngSize(png), (view.width.round(), view.height.round()),
          reason: '$screenshotName is not the size of the FlutterView');
    }
  }
  await tester.pump();
}


void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  group('Screenshot Test', () {
    for (final theme in ['light', 'dark']) {
      testWidgets('Take screenshots of app flow ($theme theme)', (WidgetTester tester) async {
        // In memory, so the seed never replaces a device's own storage.
        SharedPreferences.setMockInitialValues(<String, Object>{
          if (Platform.isAndroid) ..._androidTextureMode,
        });
        await seedDemoData(theme: theme);
        app.main();
        await tester.pumpAndSettle(const Duration(seconds: 10));
        await _setDeviceOrientation(tester);
        await _sizeWindow(tester);

        // Required before takeScreenshot on Android, which PixelCopies the
        // FlutterView; texture mode puts the webviews inside that frame.
        await binding.convertFlutterSurfaceToImage();
        await tester.pumpAndSettle();

        // pumpAndSettle never settles once a webview is live, so every stop
        // waits on the real clock.
        Future<void> wait(Duration span) async {
          await tester.pump();
          await Future<void>.delayed(span);
          await tester.pump();
        }

        await walkLibraryTour(
          tester,
          host: (
            settle: () => wait(const Duration(seconds: 2)),
            pageLoad: () => wait(_WEBVIEW_LOAD_TIMEOUT),
            shoot: (name) => _takeThemedScreenshots(binding,
                tester: tester, baseName: name, currentTheme: theme),
          ),
        );
      });
    }
  });
}
