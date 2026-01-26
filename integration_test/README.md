# Flutter Native Screenshot Integration Test

This directory contains Flutter integration tests for generating app screenshots, translated from the original Java/fastlane screenshot tests.

## Files

- `screenshot_test.dart` - Main screenshot integration test (Flutter native)

## Key Differences from Java Version

### Architecture

**Java/Fastlane approach:**
- Uses Android UiAutomator to control the app externally
- Launches app via Intent with DEMO_MODE flag
- Uses fastlane screengrab for screenshot capture
- Runs as an Android instrumentation test

**Flutter approach:**
- Uses Flutter integration_test framework
- Seeds demo data directly before launching app
- Uses Flutter's native screenshot capture
- Runs as a Flutter integration test

### Advantages of Flutter Approach

1. **Platform Independence**: Same test can run on Android, iOS, and other platforms
2. **Better Control**: Direct access to Flutter widget tree
3. **Faster Execution**: No need for external UI automation tools
4. **Easier Debugging**: Standard Flutter debugging tools work
5. **More Reliable**: Less flaky than UI automation
6. **Simpler Setup**: No need for fastlane screengrab configuration

### Translation Details

| Java (UiAutomator) | Flutter (integration_test) |
|-------------------|---------------------------|
| `UiDevice.findObject(By.text("..."))` | `find.text("...")` |
| `device.wait(Until.hasObject(...))` | `tester.pumpAndSettle()` |
| `Thread.sleep(millis)` | `await tester.pumpAndSettle(Duration(...))` |
| `element.click()` | `await tester.tap(finder)` |
| `device.swipe(...)` | `await tester.fling(...)` or `tester.drag(...)` |
| `Screengrab.screenshot("name")` | `await binding.takeScreenshot("name")` |
| Intent extras for DEMO_MODE | Direct call to `seedDemoData()` |

## Running the Tests

### Basic execution:
```bash
flutter test integration_test/screenshot_test.dart
```

### On a specific device:
```bash
flutter test integration_test/screenshot_test.dart -d <device_id>
```

### With screenshot capture on Android:
```bash
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/screenshot_test.dart
```

### With screenshot capture on iOS:
```bash
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/screenshot_test.dart \
  -d iPhone
```

## Screenshot Locations

### When using `flutter test`:
- Screenshots are saved in memory only (not written to files)
- Useful for quick test validation

### When using `flutter drive` (recommended):

**IMPORTANT**: The test driver runs on the **host machine**, not the target device.
This means it cannot detect whether you're targeting Android or iOS at runtime.
Use the `SCREENSHOT_DIR` environment variable to specify where screenshots should be saved.

**Via fastlane (recommended):**
```bash
# Android - uses fastlane/metadata/android/en-US/images/phoneScreenshots/
cd android && bundle exec fastlane screenshots

# iOS - uses fastlane/screenshots/en-US/
cd ios && bundle exec fastlane screenshots
```

**Manual Android:**
```bash
SCREENSHOT_DIR=fastlane/metadata/android/en-US/images/phoneScreenshots flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/screenshot_test.dart \
  --flavor fmain \
  -d <device_id>
```

**Manual iOS:**
```bash
SCREENSHOT_DIR=fastlane/screenshots/en-US flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/screenshot_test.dart \
  -d <simulator_id>
```

**Default (no SCREENSHOT_DIR):**
```bash
# Screenshots go to screenshots/ directory
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/screenshot_test.dart
```

### View screenshots:
```bash
# Android (after running fastlane screenshots)
ls -la fastlane/metadata/android/en-US/images/phoneScreenshots/
open fastlane/metadata/android/en-US/images/phoneScreenshots/01-all-sites.png

# iOS (after running fastlane screenshots)
ls -la fastlane/screenshots/en-US/
open fastlane/screenshots/en-US/01-all-sites.png

# Default location (manual runs without SCREENSHOT_DIR)
ls -la screenshots/
open screenshots/01-all-sites.png
```

## Fastlane Integration

The screenshot generation is fully integrated with fastlane:

- **Android**: `cd android && bundle exec fastlane screenshots`
- **iOS**: `cd ios && bundle exec fastlane screenshots`

The fastlane lanes handle:
1. Finding connected devices/simulators
2. Clearing previous screenshots
3. Setting `SCREENSHOT_DIR` to the correct platform-specific path
4. Running the Flutter integration test

## Test Flow

The test captures 10 screenshots:

1. **01-all-sites** - Main screen showing all sites
2. **02-sites-drawer** - Navigation drawer with site list
3. **03-site-webview** - A site's webview (DuckDuckGo)
4. **04-drawer-with-site** - Drawer showing current site highlighted
5. **05-work-webspace** - Work webspace view
6. **06-work-sites-drawer** - Work webspace drawer
7. **07-add-workspace-dialog** - Dialog for adding new workspace
8. **08-workspace-name-entered** - Dialog with workspace name filled
9. **09-workspace-sites-selected** - Dialog with sites selected
10. **10-new-workspace-created** - Main screen with newly created workspace

## Troubleshooting

### Screenshots not saving
- Ensure you're using `IntegrationTestWidgetsFlutterBinding`
- Check device permissions for file storage
- Try using `flutter drive` instead of `flutter test`

### Test timing issues
- Adjust `pumpAndSettle` durations as needed
- Some screens may need more time to load
- Webviews especially need longer wait times

### Element not found
- Check widget tree with Flutter DevTools
- Verify demo data is seeded correctly
- Use `find.byType` if text-based finders fail
