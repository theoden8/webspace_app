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
      
      // Wait for initial site icons to load
      print('Waiting for site icons to load...');
      await Future.delayed(const Duration(seconds: 5));
      await tester.pump();

      // Screenshot 1: All sites view (main screen)
      print('Capturing all sites view');
      await binding.takeScreenshot('01-all-sites');
      await tester.pumpAndSettle(const Duration(seconds: 5));

      // Open drawer to see site list
      print('Opening drawer via menu button...');
      print('Looking for drawer elements...');
      _debugPrintWidgets(tester);
      await _openDrawer(tester);
      print('Drawer opened, waiting for icons to load...');
      await tester.pumpAndSettle(const Duration(seconds: 15));

      // Screenshot 2: Drawer with sites list
      print('Capturing sites drawer');
      await binding.takeScreenshot('02-sites-drawer');
      await tester.pumpAndSettle(const Duration(seconds: 3));

      // Look for a site to select (DuckDuckGo)
      print('Looking for DuckDuckGo site...');
      final duckDuckGoFinder = find.text('DuckDuckGo');
      
      if (duckDuckGoFinder.evaluate().isNotEmpty) {
        print('Selecting DuckDuckGo site');
        await tester.tap(duckDuckGoFinder);
        print('Waiting for webview to load...');
        await tester.pumpAndSettle(const Duration(seconds: 3));
        
        // Extra wait for webview content to fully render
        await Future.delayed(const Duration(seconds: 8));
        await tester.pump();

        // Screenshot 3: Site webview
        print('Capturing site webview');
        await binding.takeScreenshot('03-site-webview');
        await tester.pumpAndSettle(const Duration(seconds: 5));

        // Open drawer again
        print('Opening drawer to show current site');
        await _openDrawer(tester);
        await tester.pumpAndSettle(const Duration(seconds: 5));

        // Screenshot 4: Drawer showing current site
        print('Capturing drawer with site');
        await binding.takeScreenshot('04-drawer-with-site');
        await tester.pumpAndSettle(const Duration(seconds: 3));
      } else {
        print('DuckDuckGo site not found');
      }

      // Close drawer
      await _closeDrawer(tester);
      await tester.pumpAndSettle(const Duration(seconds: 3));

      // Look for "Work" webspace
      print('Looking for Work webspace...');
      final workWebspaceFinder = find.text('Work');
      
      if (workWebspaceFinder.evaluate().isNotEmpty) {
        print('Work webspace found - capturing screenshots');
        print('Selecting Work webspace');
        await tester.tap(workWebspaceFinder);
        await tester.pumpAndSettle(const Duration(seconds: 3));

        // Screenshot 6: Work webspace drawer
        print('Capturing work sites drawer');
        await binding.takeScreenshot('06-work-sites-drawer');
        await tester.pumpAndSettle(const Duration(seconds: 3));

        // Close drawer before capturing the Work webspace sites
        await _closeDrawer(tester);
        await tester.pumpAndSettle(const Duration(seconds: 3));
        
        // Wait for webviews/site icons to load
        print('Waiting for work webspace sites to load...');
        await Future.delayed(const Duration(seconds: 5));
        await tester.pump();

        // Screenshot 5: Work webspace sites
        print('Capturing work webspace');
        await binding.takeScreenshot('05-work-webspace');
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
        await tester.pumpAndSettle(const Duration(seconds: 3));

        // Screenshot 7: Add workspace dialog
        print('Capturing add workspace dialog');
        await binding.takeScreenshot('07-add-workspace-dialog');
        await tester.pumpAndSettle(const Duration(seconds: 3));

        // Look for workspace name field
        print('Looking for workspace name field...');
        final nameFieldFinder = find.byType(TextField).first;
        
        if (nameFieldFinder.evaluate().isNotEmpty) {
          print('Found name field, entering text...');
          await tester.tap(nameFieldFinder);
          await tester.pumpAndSettle(const Duration(seconds: 3));
          await tester.enterText(nameFieldFinder, 'Entertainment');
          await tester.pumpAndSettle(const Duration(seconds: 3));

          // Dismiss keyboard
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await tester.pumpAndSettle(const Duration(seconds: 3));

          // Screenshot 8: Workspace with name entered
          print('Capturing workspace name entered');
          await binding.takeScreenshot('08-workspace-name-entered');
          await tester.pumpAndSettle(const Duration(seconds: 3));

          // Look for site selection checkboxes
          print('Looking for site selection elements...');
          final redditFinder = find.text('Reddit');
          if (redditFinder.evaluate().isNotEmpty) {
            print('Selecting Reddit...');
            await tester.tap(redditFinder);
            await tester.pumpAndSettle(const Duration(seconds: 3));
          }

          final wikipediaFinder = find.text('Wikipedia');
          if (wikipediaFinder.evaluate().isNotEmpty) {
            print('Selecting Wikipedia...');
            await tester.tap(wikipediaFinder);
            await tester.pumpAndSettle(const Duration(seconds: 3));
          }

          // Screenshot 9: Sites selected
          print('Capturing sites selected');
          await binding.takeScreenshot('09-workspace-sites-selected');
          await tester.pumpAndSettle(const Duration(seconds: 3));

          // Look for save/create button
          print('Looking for save button...');
          Finder? saveButton = find.text('Save');
          if (saveButton.evaluate().isEmpty) {
            saveButton = find.text('Create');
          }
          if (saveButton.evaluate().isEmpty) {
            saveButton = find.text('Done');
          }
          if (saveButton.evaluate().isEmpty) {
            saveButton = find.text('OK');
          }

          if (saveButton.evaluate().isNotEmpty) {
            print('Found save button, tapping...');
            await tester.tap(saveButton);
            await tester.pumpAndSettle(const Duration(seconds: 3));

            // Screenshot 10: New workspace in list
            print('Capturing webspaces list with new workspace');
            await binding.takeScreenshot('10-new-workspace-created');
            await tester.pumpAndSettle(const Duration(seconds: 3));
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
  
  // Find the ScaffoldState and open drawer programmatically
  final ScaffoldState scaffoldState = tester.state(find.byType(Scaffold).first);
  scaffoldState.openDrawer();
  
  await tester.pumpAndSettle(const Duration(seconds: 3));
  
  // Verify drawer opened
  final drawerVisible = find.byType(Drawer).evaluate().isNotEmpty;
  print('Drawer opened: $drawerVisible');
  
  await tester.pumpAndSettle(const Duration(seconds: 2));
}

/// Close the navigation drawer
Future<void> _closeDrawer(WidgetTester tester) async {
  // Look for "Back to Webspaces" button
  final backButtonFinder = find.text('Back to Webspaces');
  
  if (backButtonFinder.evaluate().isNotEmpty) {
    await tester.tap(backButtonFinder);
  } else {
    // Fallback: tap outside drawer or use back navigation
    print('Back to Webspaces button not found, tapping barrier');
    // Tap on the drawer barrier (scrim) to close
    final scaffoldFinder = find.byType(Scaffold);
    if (scaffoldFinder.evaluate().isNotEmpty) {
      // Tap in the center-right area (outside drawer)
      await tester.tapAt(const Offset(400, 400));
    }
  }
  
  await tester.pumpAndSettle(const Duration(seconds: 5));
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
