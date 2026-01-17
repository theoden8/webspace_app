import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/main.dart' as app;
import 'package:webspace/demo_data.dart';

/// Flutter integration test for generating F-Droid and Play Store screenshots.
///
/// This test seeds demo data automatically on startup and navigates through
/// the app to capture screenshots at key points.
///
/// To run this test and generate screenshots:
/// 1. flutter test integration_test/screenshot_test.dart
/// 2. Or use with flutter_driver for automated screenshot capture

// Timeout constants
const Duration _ICON_LOAD_TIMEOUT = Duration(seconds: 10);
const Duration _WEBVIEW_LOAD_TIMEOUT = Duration(seconds: 15);
const Duration _SCREENSHOT_TIMEOUT = Duration(seconds: 5);
const Duration _DRAWER_TIMEOUT = Duration(seconds: 5);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Enable native screenshot capture
  // This will save screenshots to the device/emulator
  if (binding is IntegrationTestWidgetsFlutterBinding) {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  }

  group('Screenshot Test', () {
    testWidgets('Take screenshots of app flow', (WidgetTester tester) async {
      print('========================================');
      print('Setting up screenshot test');
      print('========================================');

      // Seed demo data before launching the app
      print('Seeding demo data...');
      await seedDemoData();
      print('Demo data seeded successfully');

      // Launch the app
      print('Launching app...');
      app.main();

      // Wait for app to fully load and render
      await tester.pumpAndSettle(const Duration(seconds: 10));
      print('App launched and settled');

      // Wait briefly for webspaces list to render
      print('Waiting for webspaces list...');
      await tester.pumpAndSettle(const Duration(seconds: 3));

      print('========================================');
      print('STARTING SCREENSHOT TOUR');
      print('========================================');

      // Convert Flutter surface to image for screenshot capture
      await binding.convertFlutterSurfaceToImage();
      await tester.pumpAndSettle();
      
      // Wait for initial site icons to load (with timeout)
      print('Waiting for site icons to load (timeout: ${_ICON_LOAD_TIMEOUT.inSeconds}s)...');
      await Future.delayed(_ICON_LOAD_TIMEOUT);
      await tester.pump();

      // Screenshot 1: All sites view (main screen)
      print('Capturing all sites view');
      await binding.takeScreenshot('01-all-sites').timeout(
        _SCREENSHOT_TIMEOUT,
        onTimeout: () {
          print('Warning: Screenshot 1 timed out');
          return <int>[];
        },
      );
      await tester.pump();
      await Future.delayed(const Duration(seconds: 2));

      // Open drawer to see site list
      print('Opening drawer via menu button...');
      print('Looking for drawer elements...');
      _debugPrintWidgets(tester);
      await _openDrawer(tester);
      
      print('Drawer opened, waiting for icons to load (timeout: ${_ICON_LOAD_TIMEOUT.inSeconds}s)...');
      await Future.delayed(_ICON_LOAD_TIMEOUT);
      await tester.pump();

      // Screenshot 2: Drawer with sites list
      print('Capturing sites drawer');
      await binding.takeScreenshot('02-sites-drawer').timeout(
        _SCREENSHOT_TIMEOUT,
        onTimeout: () {
          print('Warning: Screenshot 2 timed out');
          return <int>[];
        },
      );
      await tester.pump();
      await Future.delayed(const Duration(seconds: 2));

      // Look for a site to select (DuckDuckGo)
      print('Looking for DuckDuckGo site...');
      final duckDuckGoFinder = find.text('DuckDuckGo');
      
      if (duckDuckGoFinder.evaluate().isNotEmpty) {
        print('Selecting DuckDuckGo site');
        await tester.tap(duckDuckGoFinder);
        await tester.pump();
        
        print('Waiting for webview to load (timeout: ${_WEBVIEW_LOAD_TIMEOUT.inSeconds}s)...');
        await Future.delayed(_WEBVIEW_LOAD_TIMEOUT);
        await tester.pump();

        // Screenshot 3: Site webview
        print('Capturing site webview');
        await binding.takeScreenshot('03-site-webview').timeout(
          _SCREENSHOT_TIMEOUT,
          onTimeout: () {
            print('Warning: Screenshot 3 timed out');
            return <int>[];
          },
        );
        print('Screenshot 3 captured successfully');
        
        // Use pump() instead of pumpAndSettle() to avoid timeout with webviews
        await tester.pump(const Duration(seconds: 2));
        await Future.delayed(const Duration(seconds: 2));

        // Open drawer again
        print('Opening drawer to show current site');
        await _openDrawer(tester);
        await Future.delayed(const Duration(seconds: 2));

        // Screenshot 4: Drawer showing current site
        print('Capturing drawer with site');
        await binding.takeScreenshot('04-drawer-with-site').timeout(
          _SCREENSHOT_TIMEOUT,
          onTimeout: () {
            print('Warning: Screenshot 4 timed out');
            return <int>[];
          },
        );
        print('Screenshot 4 captured successfully');
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

        // Screenshot 6: Work webspace drawer
        print('Capturing work sites drawer');
        await binding.takeScreenshot('06-work-sites-drawer').timeout(
          _SCREENSHOT_TIMEOUT,
          onTimeout: () {
            print('Warning: Screenshot 6 timed out');
            return <int>[];
          },
        );
        print('Screenshot 6 captured successfully');
        await tester.pump();
        await Future.delayed(const Duration(seconds: 2));

        // Close drawer before capturing the Work webspace sites
        await _closeDrawer(tester);
        await tester.pump();
        await Future.delayed(const Duration(seconds: 2));
        
        // Wait for webviews/site icons to load
        print('Waiting for work webspace sites to load (timeout: ${_ICON_LOAD_TIMEOUT.inSeconds}s)...');
        await Future.delayed(_ICON_LOAD_TIMEOUT);
        await tester.pump();

        // Screenshot 5: Work webspace sites
        print('Capturing work webspace');
        await binding.takeScreenshot('05-work-webspace').timeout(
          _SCREENSHOT_TIMEOUT,
          onTimeout: () {
            print('Warning: Screenshot 5 timed out');
            return <int>[];
          },
        );
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

        // Screenshot 7: Add workspace dialog
        print('Capturing add workspace dialog');
        await binding.takeScreenshot('07-add-workspace-dialog').timeout(
          _SCREENSHOT_TIMEOUT,
          onTimeout: () {
            print('Warning: Screenshot 7 timed out');
            return <int>[];
          },
        );
        await tester.pump();
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

          // Screenshot 8: Workspace with name entered
          print('Capturing workspace name entered');
          await binding.takeScreenshot('08-workspace-name-entered').timeout(
            _SCREENSHOT_TIMEOUT,
            onTimeout: () {
              print('Warning: Screenshot 8 timed out');
              return <int>[];
            },
          );
          await tester.pump();
          await Future.delayed(const Duration(seconds: 1));

          // Look for site selection checkboxes
          print('Looking for site selection elements...');
          final redditFinder = find.text('Reddit');
          if (redditFinder.evaluate().isNotEmpty) {
            print('Selecting Reddit...');
            await tester.tap(redditFinder);
            await tester.pump();
            await Future.delayed(const Duration(seconds: 1));
          }

          final wikipediaFinder = find.text('Wikipedia');
          if (wikipediaFinder.evaluate().isNotEmpty) {
            print('Selecting Wikipedia...');
            await tester.tap(wikipediaFinder);
            await tester.pump();
            await Future.delayed(const Duration(seconds: 1));
          }

          // Screenshot 9: Sites selected
          print('Capturing sites selected');
          await binding.takeScreenshot('09-workspace-sites-selected').timeout(
            _SCREENSHOT_TIMEOUT,
            onTimeout: () {
              print('Warning: Screenshot 9 timed out');
              return <int>[];
            },
          );
          await tester.pump();
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

            // Screenshot 10: New workspace in list
            print('Capturing webspaces list with new workspace');
            await binding.takeScreenshot('10-new-workspace-created').timeout(
              _SCREENSHOT_TIMEOUT,
              onTimeout: () {
                print('Warning: Screenshot 10 timed out');
                return <int>[];
              },
            );
            await tester.pump();
            await Future.delayed(const Duration(seconds: 1));
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
      print('Screenshot tour completed');
      print('========================================');
    });
  });
}

/// Open the navigation drawer
Future<void> _openDrawer(WidgetTester tester) async {
  print('Opening drawer programmatically...');
  
  try {
    // Find the ScaffoldState and open drawer programmatically
    final ScaffoldState scaffoldState = tester.state(find.byType(Scaffold).first);
    scaffoldState.openDrawer();
    
    // Use pump() with timeout instead of pumpAndSettle to avoid webview issues
    await tester.pump();
    await Future.delayed(const Duration(seconds: 2));
    await tester.pump();
    
    // Verify drawer opened
    final drawerVisible = find.byType(Drawer).evaluate().isNotEmpty;
    print('Drawer opened: $drawerVisible');
    
    await Future.delayed(const Duration(seconds: 2));
  } catch (e) {
    print('Error opening drawer: $e');
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
      // Fallback: Use ScaffoldState to close drawer programmatically
      print('Back to Webspaces button not found, closing programmatically');
      final ScaffoldState scaffoldState = tester.state(find.byType(Scaffold).first);
      if (scaffoldState.isDrawerOpen) {
        Navigator.of(scaffoldState.context).pop();
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
