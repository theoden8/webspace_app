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
Screenshots are automatically saved to platform-specific directories:

**Android:**
```
fastlane/metadata/android/en-US/images/phoneScreenshots/01-all-sites.png
fastlane/metadata/android/en-US/images/phoneScreenshots/02-sites-drawer.png
fastlane/metadata/android/en-US/images/phoneScreenshots/03-site-webview.png
... (all 10 screenshots)
```

**iOS/Desktop:**
```
screenshots/01-all-sites.png
screenshots/02-sites-drawer.png
... (all 10 screenshots)
```

The `test_driver/integration_test.dart` file detects the platform and saves 
screenshots to the appropriate directory for fastlane integration.

### Custom directory:
```bash
# Override screenshot directory
SCREENSHOT_DIR=my/custom/path flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/screenshot_test.dart
```

### View screenshots:
```bash
# Android
ls -la fastlane/metadata/android/en-US/images/phoneScreenshots/
open fastlane/metadata/android/en-US/images/phoneScreenshots/01-all-sites.png

# iOS/Desktop
ls -la screenshots/
open screenshots/01-all-sites.png
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

## Separate App Installation (Android)

Screenshot tests on Android use the `fscreenshot` flavor with a different application ID:

- **Production app**: `org.codeberg.theoden8.webspace`
- **Screenshot app**: `org.codeberg.theoden8.webspace.screenshot`

**Benefits:**
- Both apps can be installed simultaneously on the same device
- Screenshot tests don't affect your production app data
- You can run tests without losing your personal setup
- Production TestFlight/Play Store app remains untouched

**Usage:**
When running via fastlane (`cd android && fastlane screenshots`), the `fscreenshot` flavor is automatically used.

**Verification:**
After running screenshot tests, you should see two apps in your launcher:
- "WebSpace" (production)
- "WebSpace (screenshot)" (test app)

## Demo Mode Data Isolation

The screenshot test calls `seedDemoData()` which:

1. **Sets demo mode marker**: `wasDemoMode = true` in SharedPreferences
2. **Enables demo mode flag**: `isDemoMode = true` (in-memory)
3. **Writes demo data to separate keys**: Uses `demo_*` prefixed keys

### Key Separation

| User Data Keys | Demo Data Keys |
|----------------|----------------|
| `webViewModels` | `demo_webViewModels` |
| `webspaces` | `demo_webspaces` |
| `selectedWebspaceId` | `demo_selectedWebspaceId` |

**User data is never overwritten or modified during screenshot tests.**

### Data Cleanup

When you open the app normally after screenshot tests:
1. App calls `clearDemoDataIfNeeded()` on startup
2. Detects `wasDemoMode` marker
3. Removes all `demo_*` keys
4. Loads from regular keys (your original data)

### Demo Data Content

**8 Sites**: DuckDuckGo, Piped, Nitter, Reddit, GitHub, Hacker News, Weights & Biases, Wikipedia

**4 Workspaces**: All, Work, Privacy, Social

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

### Data concerns

**Android**:
- Production app and screenshot app are completely separate installations
- No data is shared between them
- Screenshot tests cannot affect production app

**iOS**:
- Uses same bundle ID but separate `demo_*` keys
- Demo data is automatically cleaned up on next normal app launch
- User data preserved through key separation

**Debug Logging**:
Check logs for `[DEMO MODE]` and `[APP STATE]` prefixes to see:
- Which keys are being used (demo vs regular)
- Data counts before/after operations
- Verification that user data is preserved
