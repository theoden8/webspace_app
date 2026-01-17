# Flutter Screenshots - Quick Start Guide

## What Was Done

✅ Translated `ScreenshotTest.java` to Flutter integration test  
✅ Added `integration_test` dependency to `pubspec.yaml`  
✅ Created `integration_test/screenshot_test.dart`  
✅ Created `test_driver/integration_test.dart`  
✅ Added comprehensive documentation

## Quick Start

### 1. Install Dependencies
```bash
flutter pub get
```

### 2. Connect Device/Start Emulator
```bash
# List available devices
flutter devices

# Or start an emulator
flutter emulators --launch <emulator_id>
```

### 3. Run the Test

**Option A: Simple test run (no screenshot files saved)**
```bash
flutter test integration_test/screenshot_test.dart
```

**Option B: With screenshot capture**
```bash
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/screenshot_test.dart
```

**Option C: Specific device**
```bash
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/screenshot_test.dart \
  -d <device_id>
```

## What Gets Captured

The test captures 10 screenshots:
1. `01-all-sites` - Main screen with all sites
2. `02-sites-drawer` - Navigation drawer with site list
3. `03-site-webview` - DuckDuckGo site loaded
4. `04-drawer-with-site` - Drawer showing selected site
5. `05-work-webspace` - Work webspace view
6. `06-work-sites-drawer` - Work webspace drawer
7. `07-add-workspace-dialog` - New workspace dialog
8. `08-workspace-name-entered` - Dialog with name filled
9. `09-workspace-sites-selected` - Dialog with sites selected
10. `10-new-workspace-created` - Main screen with new workspace

## How It Works

1. **Seeds demo data** - Calls `seedDemoData()` to populate test data
2. **Launches app** - Starts the app via `main()`
3. **Navigates & captures** - Walks through UI taking screenshots
4. **Saves screenshots** - Stores in platform-specific location

## Differences from Java Version

| Java/UiAutomator | Flutter Integration |
|------------------|---------------------|
| External automation | Internal testing |
| Android only | Cross-platform |
| Slower | Faster |
| Uses Intent flags | Direct function call |
| UiDevice API | WidgetTester API |

## File Locations

- **Test**: `integration_test/screenshot_test.dart`
- **Driver**: `test_driver/integration_test.dart`
- **Docs**: `integration_test/README.md`
- **Comparison**: `transcript/FLUTTER_VS_JAVA_SCREENSHOTS.md`

## Troubleshooting

### Test fails with "element not found"
- Increase wait times in `pumpAndSettle` calls
- Check widget tree with DevTools
- Verify demo data is seeding correctly

### Screenshots not saving
- Use `flutter drive` instead of `flutter test`
- Check device storage permissions
- Look for screenshots in test output directory

### Slow execution
- This is normal - webviews need time to load
- Adjust timing constants if needed
- Timing is more predictable than Java version

## Next Steps

### To replace Java tests completely:
1. Test on multiple devices/emulators
2. Verify screenshot quality
3. Update fastlane configuration
4. Add locale support if needed
5. Set up CI/CD integration

### To keep both approaches:
- Use Flutter for development/debugging
- Use Java for production release screenshots
- Or vice versa - your choice!

## Advantages

✨ **Cross-platform** - Same test for Android/iOS  
✨ **Faster** - Runs in same process as app  
✨ **Reliable** - Direct widget access, less flaky  
✨ **Debuggable** - Use standard Flutter tools  
✨ **Maintainable** - Pure Dart, no Java/Kotlin  

## Commands Cheat Sheet

```bash
# Install dependencies
flutter pub get

# List devices
flutter devices

# Run test (basic)
flutter test integration_test/screenshot_test.dart

# Run with screenshots
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/screenshot_test.dart

# Run on specific device
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/screenshot_test.dart \
  -d emulator-5554

# Debug mode (slower but easier to debug)
flutter run integration_test/screenshot_test.dart
```

## Help

- **Integration test docs**: See `integration_test/README.md`
- **Comparison**: See `transcript/FLUTTER_VS_JAVA_SCREENSHOTS.md`
- **Full details**: See `transcript/FLUTTER_SCREENSHOT_IMPLEMENTATION.md`

---

**Ready to try it!** Just run:
```bash
flutter pub get
flutter drive --driver=test_driver/integration_test.dart --target=integration_test/screenshot_test.dart
```
