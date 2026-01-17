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
Screenshots are automatically saved to the `screenshots/` directory:
```
screenshots/01-all-sites.png
screenshots/02-sites-drawer.png
screenshots/03-site-webview.png
screenshots/04-drawer-with-site.png
screenshots/05-work-webspace.png
screenshots/06-work-sites-drawer.png
screenshots/07-add-workspace-dialog.png
screenshots/08-workspace-name-entered.png
screenshots/09-workspace-sites-selected.png
screenshots/10-new-workspace-created.png
```

The `test_driver/integration_test.dart` file uses the `onScreenshot` callback 
to save screenshots locally.

### View screenshots:
```bash
# After running flutter drive
ls -la screenshots/

# View with image viewer
open screenshots/01-all-sites.png  # macOS
xdg-open screenshots/01-all-sites.png  # Linux
start screenshots/01-all-sites.png  # Windows
```

**Note**: The old fastlane screenshots in `fastlane/metadata/android/en-US/images/phoneScreenshots/` 
are from the Java/UiAutomator tests, not from the Flutter integration tests.

## Next Steps

To fully integrate with fastlane for automated Play Store/F-Droid screenshots:

1. Create a test_driver file (if using flutter drive)
2. Configure fastlane to run the Flutter integration test
3. Set up screenshot locations in fastlane/Screengrabfile
4. Add metadata for different locales

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
