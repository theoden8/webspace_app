import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/main.dart' as app;
import 'package:webspace/demo_data.dart';

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
  }
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
const Duration _ICON_LOAD_TIMEOUT = Duration(seconds: 10);
const Duration _WEBVIEW_LOAD_TIMEOUT = Duration(seconds: 15);
const Duration _SCREENSHOT_TIMEOUT = Duration(seconds: 10);
const Duration _NATIVE_SCREENSHOT_TIMEOUT = Duration(seconds: 30);
const Duration _DRAWER_TIMEOUT = Duration(seconds: 5);

/// Helper to take a screenshot with both light and dark themes.
/// Takes the current theme screenshot first, then toggles to the other theme,
/// takes that screenshot, and toggles back.
/// 
/// If [useNative] is true on Android, the driver will use ADB screencap to 
/// capture the actual screen including webviews. This is needed because Flutter's
/// convertFlutterSurfaceToImage() only captures Flutter-rendered content.
/// On iOS, useNative is ignored since Flutter screenshots work fine with webviews.
Future<void> _takeThemedScreenshots(
  IntegrationTestWidgetsFlutterBinding binding,
  WidgetTester tester,
  String baseName,
  String currentTheme, {
  bool useNative = false,
}) async {
  final themeSuffix = currentTheme == 'light' ? '-light' : '-dark';
  final screenshotName = '$baseName$themeSuffix';
  
  // Only use native screenshots on Android - iOS Flutter screenshots capture webviews fine
  final isAndroid = Platform.isAndroid;
  final shouldUseNative = useNative && isAndroid;
  
  print('Capturing $screenshotName${shouldUseNative ? ' (native/Android)' : ''}');
  
  // Pump before screenshot to ensure all pending frame updates are processed
  // This is important for native platform views (webviews) which render asynchronously
  await tester.pump();
  
  if (shouldUseNative) {
    // For native screenshots on Android (webviews), use logcat-based signaling
    // because binding.takeScreenshot() only captures Flutter-rendered content.
    await _requestNativeScreenshot(screenshotName);
  } else {
    // For Flutter-only UI or iOS, use the standard screenshot mechanism
    await binding.takeScreenshot(screenshotName).timeout(
      _SCREENSHOT_TIMEOUT,
      onTimeout: () {
        print('Warning: Screenshot $screenshotName timed out after ${_SCREENSHOT_TIMEOUT.inSeconds}s');
        return <int>[];
      },
    );
  }
  await tester.pump();
}

/// Request a native screenshot by printing a marker that the driver watches for.
/// The driver will take an ADB screenshot when it sees this marker in the logs.
/// This avoids file permission issues on Android.
Future<void> _requestNativeScreenshot(String screenshotName) async {
  // Print a unique marker that the driver can detect in logcat
  // Format: @@NATIVE_SCREENSHOT:<name>@@
  print('@@NATIVE_SCREENSHOT:$screenshotName@@');
  
  // Give the driver time to capture the screenshot
  // The driver watches logcat and takes a screenshot when it sees the marker
  await Future.delayed(const Duration(seconds: 3));
  
  print('Native screenshot requested: $screenshotName');
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Enable native screenshot capture
  // This will save screenshots to the device/emulator
  if (binding is IntegrationTestWidgetsFlutterBinding) {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  }

  group('Screenshot Test', () {
    for (final theme in ['light', 'dark']) {
      testWidgets('Take screenshots of app flow ($theme theme)', (WidgetTester tester) async {
        print('========================================');
        print('Setting up screenshot test ($theme theme)');
        print('========================================');

        // Seed demo data before launching the app
        print('Seeding demo data with $theme theme...');
        await seedDemoData(theme: theme);
        print('Demo data seeded successfully');

        // Launch the app
        print('Launching app...');
        app.main();

        // Wait for app to fully load and render
        await tester.pumpAndSettle(const Duration(seconds: 10));
        print('App launched and settled');

        // Set orientation based on device type (iPad: landscape, iPhone: portrait)
        await _setDeviceOrientation(tester);

        // Theme is already set via seedDemoData
        String currentTheme = theme;

        print('========================================');
        print('STARTING SCREENSHOT TOUR ($theme theme)');
        print('========================================');

        // Convert Flutter surface to image for screenshot capture (required on Android).
        // NOTE: This only captures Flutter-rendered content, not native platform views like webviews.
        // For screenshots that include webviews (01, 02), we pass useNative: true to use
        // ADB screencap instead, which captures the actual screen including platform views.
        await binding.convertFlutterSurfaceToImage();
        await tester.pumpAndSettle();

        // Open drawer to select a site
        print('Opening drawer via menu button...');
        print('Looking for drawer elements...');
        _debugPrintWidgets(tester);
        await _openDrawer(tester);
        await tester.pump();
        await Future.delayed(const Duration(seconds: 2));

        // Look for a site to select (DuckDuckGo)
        print('Looking for DuckDuckGo site...');
        final duckDuckGoFinder = find.text('DuckDuckGo');

        if (duckDuckGoFinder.evaluate().isNotEmpty) {
          print('Selecting DuckDuckGo site');
          await tester.tap(duckDuckGoFinder);

          // Pump to process the tap event and trigger Navigator.pop + _setCurrentIndex
          await tester.pump();
          
          // Wait for drawer closing animation to complete
          // Standard Material drawer animation is typically 300ms
          print('Completing animation and waiting for webview to load...');
          await tester.pumpAndSettle(const Duration(seconds: 2));
          
          // Now wait for webview to actually load the page content
          // The webview is a native platform view that renders outside Flutter's surface
          print('Waiting for webview to load DuckDuckGo page...');
          await Future.delayed(_WEBVIEW_LOAD_TIMEOUT);
          
          // Pump a few frames to ensure the native view is fully rendered
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));

          // Screenshot 1: DuckDuckGo webview loaded
          // Use native screenshot to capture the webview content (Flutter surface misses platform views)
          await _takeThemedScreenshots(binding, tester, '01-site-webview', currentTheme, useNative: true);
          print('Screenshot 1 captured successfully (site selected)');

          // Use pump() instead of pumpAndSettle() to avoid timeout with webviews
          await tester.pump(const Duration(seconds: 2));
          await Future.delayed(const Duration(seconds: 2));

          // Ensure drawer is fully closed before reopening
          if (find.byType(Drawer).evaluate().isNotEmpty) {
            print('Drawer still open, closing first...');
            await _closeDrawerByTappingOutside(tester);
            await tester.pump();
            await Future.delayed(const Duration(seconds: 1));
          }

          // Open drawer again - with retry to ensure it opens
          print('Opening drawer to show current site');
          bool drawerOpened = false;
          for (int attempt = 0; attempt < 3 && !drawerOpened; attempt++) {
            if (attempt > 0) {
              print('Retry attempt $attempt to open drawer...');
              await Future.delayed(const Duration(seconds: 1));
            }
            await _openDrawer(tester);
            await Future.delayed(const Duration(seconds: 2));
            await tester.pump();
            drawerOpened = find.byType(Drawer).evaluate().isNotEmpty;
            print('Drawer visible after attempt ${attempt + 1}: $drawerOpened');
          }

          if (!drawerOpened) {
            print('WARNING: Drawer may not be fully open for screenshot 2');
          }

          // Screenshot 2: Drawer showing current site (with webview visible behind drawer)
          // Use native screenshot to capture the webview content behind the drawer
          await _takeThemedScreenshots(binding, tester, '02-drawer-with-site', currentTheme, useNative: true);
          print('Screenshot 2 captured successfully');
          await tester.pump();
          await Future.delayed(const Duration(seconds: 2));

          // Navigate back to webspaces using "Back to Webspaces" button
          print('Navigating back to webspaces list...');
          final backButtonFinder = find.text('Back to Webspaces');
          if (backButtonFinder.evaluate().isNotEmpty) {
            await tester.tap(backButtonFinder);
            await tester.pump();
            await Future.delayed(const Duration(seconds: 2));
            print('Back to webspaces list');
          } else {
            print('Back to Webspaces button not found');
          }
        } else {
          print('DuckDuckGo site not found');
        }

        // Look for "Work" webspace
        print('Looking for Work webspace...');
        final workWebspaceFinder = find.text('Work');

        if (workWebspaceFinder.evaluate().isNotEmpty) {
          print('Work webspace found - capturing screenshots');
          print('Selecting Work webspace');
          await tester.tap(workWebspaceFinder);
          await tester.pump();
          await Future.delayed(const Duration(seconds: 2));

          // Screenshot 4: Work webspace drawer
          await _takeThemedScreenshots(binding, tester, '04-work-sites-drawer', currentTheme);
          print('Screenshot 4 captured successfully');
          await tester.pump();
          await Future.delayed(const Duration(seconds: 2));

          // Close drawer before capturing the Work webspace sites
          await _closeDrawer(tester);
          await tester.pump();
          await Future.delayed(const Duration(seconds: 2));

          // Screenshot 3: Work webspace sites
          await _takeThemedScreenshots(binding, tester, '03-work-webspace', currentTheme);
          await tester.pumpAndSettle(const Duration(seconds: 3));
        }

        // Demonstrate workspace creation
        print('Starting workspace creation demonstration...');
        print('Looking for add workspace button...');

        // Try different possible button labels
        Finder? addButton = find.text('Add Webspace');
        if (addButton.evaluate().isEmpty) {
          addButton = find.text('Add');
        }
        if (addButton.evaluate().isEmpty) {
          addButton = find.text('+');
        }
        if (addButton.evaluate().isEmpty) {
          addButton = find.text('Create Webspace');
        }
        if (addButton.evaluate().isEmpty) {
          addButton = find.text('New Webspace');
        }
        // Also try to find by icon
        if (addButton.evaluate().isEmpty) {
          addButton = find.byIcon(Icons.add);
        }

        if (addButton.evaluate().isNotEmpty) {
          print('Found add button, tapping...');
          await tester.tap(addButton);
          await tester.pump();
          await Future.delayed(const Duration(seconds: 2));

          await Future.delayed(const Duration(seconds: 2));

          // Look for workspace name field
          print('Looking for workspace name field...');
          final nameFieldFinder = find.byType(TextField).first;

          if (nameFieldFinder.evaluate().isNotEmpty) {
            print('Found name field, entering text...');
            await tester.tap(nameFieldFinder);
            await tester.pump();
            await Future.delayed(const Duration(seconds: 1));
            await tester.enterText(nameFieldFinder, 'Entertainment');
            await tester.pump();
            await Future.delayed(const Duration(seconds: 1));

            // Dismiss keyboard
            await tester.testTextInput.receiveAction(TextInputAction.done);
            await tester.pump();
            await Future.delayed(const Duration(seconds: 1));

            await Future.delayed(const Duration(seconds: 1));

            // Look for site selection checkboxes (in CheckboxListTile)
            print('Looking for site selection elements...');

            // Find CheckboxListTile containing "Reddit" text
            final redditCheckbox = find.ancestor(
              of: find.text('Reddit'),
              matching: find.byType(CheckboxListTile),
            );
            if (redditCheckbox.evaluate().isNotEmpty) {
              print('Selecting Reddit checkbox...');
              await tester.tap(redditCheckbox.first);
              await tester.pump();
              await Future.delayed(const Duration(seconds: 1));
            } else {
              print('Reddit checkbox not found');
            }

            // Find CheckboxListTile containing "Wikipedia" text
            final wikipediaCheckbox = find.ancestor(
              of: find.text('Wikipedia'),
              matching: find.byType(CheckboxListTile),
            );
            if (wikipediaCheckbox.evaluate().isNotEmpty) {
              print('Selecting Wikipedia checkbox...');
              await tester.tap(wikipediaCheckbox.first);
              await tester.pump();
              await Future.delayed(const Duration(seconds: 1));
            } else {
              print('Wikipedia checkbox not found');
            }

            // Screenshot 5: Sites selected
            await _takeThemedScreenshots(binding, tester, '05-workspace-sites-selected', currentTheme);
            await Future.delayed(const Duration(seconds: 1));

            // Look for save button (check icon in AppBar)
            print('Looking for save button...');
            Finder? saveButton = find.byIcon(Icons.check);

            // Fallback to text-based save buttons
            if (saveButton.evaluate().isEmpty) {
              saveButton = find.text('Save');
            }
            if (saveButton.evaluate().isEmpty) {
              saveButton = find.text('Create');
            }
            if (saveButton.evaluate().isEmpty) {
              saveButton = find.text('Done');
            }

            if (saveButton.evaluate().isNotEmpty) {
              print('Found save button (check icon), tapping...');
              await tester.tap(saveButton);
              await tester.pump();
              await Future.delayed(const Duration(seconds: 2));
            } else {
              print('Could not find save button');
            }
          } else {
            print('Could not find name field');
          }
        } else {
          print('Could not find add workspace button');
        }

        print('========================================');
        print('Screenshot tour completed ($theme theme)');
        print('========================================');
      });
    }
  });
}

/// Open the navigation drawer
Future<void> _openDrawer(WidgetTester tester) async {
  print('Opening drawer programmatically...');

  try {
    bool drawerOpened = false;

    // Approach 1: Try swipe gesture from left edge (works well on iOS)
    print('Trying swipe gesture to open drawer...');
    final screenSize = tester.view.physicalSize / tester.view.devicePixelRatio;
    await tester.dragFrom(
      Offset(0, screenSize.height / 2),
      Offset(screenSize.width * 0.5, 0),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    drawerOpened = find.byType(Drawer).evaluate().isNotEmpty;
    print('Drawer opened via swipe: $drawerOpened');

    // Approach 2: Try tapping the menu icon
    if (!drawerOpened) {
      final menuIcon = find.byIcon(Icons.menu);
      if (menuIcon.evaluate().isNotEmpty) {
        print('Found menu icon, tapping...');
        await tester.tap(menuIcon);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        drawerOpened = find.byType(Drawer).evaluate().isNotEmpty;
        print('Drawer opened via menu icon: $drawerOpened');
      } else {
        print('Menu icon not found');
      }
    }

    // Approach 3: Try any IconButton in the leading position of AppBar
    if (!drawerOpened) {
      print('Trying to find leading IconButton in AppBar...');
      final appBar = find.byType(AppBar);
      if (appBar.evaluate().isNotEmpty) {
        final iconButtons = find.descendant(
          of: appBar,
          matching: find.byType(IconButton),
        );
        if (iconButtons.evaluate().isNotEmpty) {
          print('Found ${iconButtons.evaluate().length} IconButton(s) in AppBar, tapping first...');
          await tester.tap(iconButtons.first);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          drawerOpened = find.byType(Drawer).evaluate().isNotEmpty;
          print('Drawer opened via AppBar IconButton: $drawerOpened');
        }
      }
    }

    // Approach 4: Try opening drawer via ScaffoldState
    if (!drawerOpened) {
      print('Previous approaches failed, trying ScaffoldState...');
      final scaffoldFinder = find.byType(Scaffold);
      final scaffolds = scaffoldFinder.evaluate();
      print('Found ${scaffolds.length} Scaffold(s)');

      for (int i = 0; i < scaffolds.length && !drawerOpened; i++) {
        try {
          final scaffoldElement = scaffolds.elementAt(i);
          final scaffoldWidget = scaffoldElement.widget as Scaffold;
          print('Scaffold $i drawer property: ${scaffoldWidget.drawer != null}');

          final ScaffoldState scaffoldState = tester.state(find.byWidget(scaffoldWidget));
          print('Scaffold $i hasDrawer: ${scaffoldState.hasDrawer}');

          if (scaffoldState.hasDrawer) {
            print('Scaffold $i has drawer via state, attempting to open...');
            scaffoldState.openDrawer();
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            drawerOpened = find.byType(Drawer).evaluate().isNotEmpty;
            print('Drawer opened via Scaffold $i: $drawerOpened');
          }
        } catch (e) {
          print('Failed to open drawer via Scaffold $i: $e');
        }
      }
    }

    // Give drawer animation time to complete
    await Future.delayed(const Duration(seconds: 2));
    await tester.pump();

    // Final verification
    final drawerVisible = find.byType(Drawer).evaluate().isNotEmpty;
    print('Drawer opened: $drawerVisible');

    await Future.delayed(const Duration(seconds: 2));
  } catch (e) {
    print('Error opening drawer: $e');
  }
}

/// Close the navigation drawer by tapping outside of it
Future<void> _closeDrawerByTappingOutside(WidgetTester tester) async {
  print('Closing drawer by tapping outside...');
  try {
    final screenSize = tester.view.physicalSize / tester.view.devicePixelRatio;
    // Tap on the right side of the screen (outside the drawer)
    await tester.tapAt(Offset(screenSize.width * 0.9, screenSize.height / 2));
    await tester.pump();
    await Future.delayed(const Duration(milliseconds: 500));
    await tester.pump();
  } catch (e) {
    print('Error closing drawer by tapping outside: $e');
  }
}

/// Close the navigation drawer
Future<void> _closeDrawer(WidgetTester tester) async {
  print('Closing drawer...');

  try {
    // Look for "Back to Webspaces" button
    final backButtonFinder = find.text('Back to Webspaces');

    if (backButtonFinder.evaluate().isNotEmpty) {
      await tester.tap(backButtonFinder);
    } else {
      // Fallback: Find the scaffold with an open drawer and close it
      print('Back to Webspaces button not found, closing programmatically');
      final scaffoldFinder = find.byType(Scaffold);
      final scaffolds = scaffoldFinder.evaluate();

      for (int i = 0; i < scaffolds.length; i++) {
        try {
          final scaffoldElement = scaffolds.elementAt(i);
          final scaffoldWidget = scaffoldElement.widget as Scaffold;

          if (scaffoldWidget.drawer != null) {
            final ScaffoldState scaffoldState = tester.state(find.byWidget(scaffoldWidget));
            if (scaffoldState.isDrawerOpen) {
              Navigator.of(scaffoldState.context).pop();
              break;
            }
          }
        } catch (e) {
          print('Failed to close drawer via Scaffold $i: $e');
        }
      }
    }

    // Use pump() instead of pumpAndSettle to avoid webview timeout
    await tester.pump();
    await Future.delayed(const Duration(seconds: 2));
    await tester.pump();

    print('Drawer closed');
  } catch (e) {
    print('Error closing drawer: $e');
  }
}

/// Debug helper to print visible widgets
void _debugPrintWidgets(WidgetTester tester) {
  try {
    // Check for common widgets
    print('--- Widget Debug Info ---');
    print('AppBar found: ${find.byType(AppBar).evaluate().isNotEmpty}');
    print('Scaffold found: ${find.byType(Scaffold).evaluate().isNotEmpty}');
    print('Drawer found: ${find.byType(Drawer).evaluate().isNotEmpty}');
    print('IconButton count: ${find.byType(IconButton).evaluate().length}');
    print('Menu icon found: ${find.byIcon(Icons.menu).evaluate().isNotEmpty}');

    // Try to find any text widgets
    final textWidgets = find.byType(Text);
    print('Text widgets found: ${textWidgets.evaluate().length}');
    if (textWidgets.evaluate().length <= 10) {
      for (final element in textWidgets.evaluate()) {
        final widget = element.widget as Text;
        if (widget.data != null) {
          print('  Text: "${widget.data}"');
        }
      }
    }
    print('--- End Debug Info ---');
  } catch (e) {
    print('Debug info error: $e');
  }
}
