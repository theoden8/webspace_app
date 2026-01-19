# Flutter Screenshots - Quick Start Guide

## What Was Done

✅ Replaced `ScreenshotTest.java` with Flutter integration test  
✅ Added `integration_test` dependency to `pubspec.yaml`  
✅ Created `integration_test/screenshot_test.dart`  
✅ Created `test_driver/integration_test.dart` with screenshot saving  
✅ Updated Android fastlane to use `flutter drive`  
✅ Updated iOS fastlane to use `flutter drive`  
✅ Fixed screenshot 3 to capture drawer closing animation  
✅ Removed old Java androidTest files  
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

### 3. Run via Fastlane (RECOMMENDED)

**Android:**
```bash
cd android
fastlane screenshots
```

**iOS:**
```bash
cd ios
fastlane screenshots
```

**Both platforms:**
```bash
fastlane screenshots_all
```

### 4. Or Run Flutter Driver Directly

**With screenshot capture:**
```bash
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/screenshot_test.dart \
  --flavor fmain
```

**Specific device:**
```bash
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/screenshot_test.dart \
  --flavor fmain \
  -d <device_id>
```

**Where are screenshots saved?**
- **Android**: `fastlane/metadata/android/en-US/images/phoneScreenshots/`
- **iOS**: `fastlane/screenshots/en-US/`
- **Override**: `SCREENSHOT_DIR=path/to/dir flutter drive ...`

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

## What Changed from Java Version

The old Java/UiAutomator test has been **completely replaced** with Flutter:

| Old (Java) | New (Flutter) |
|------------|---------------|
| External automation | Internal testing |
| Android only | Cross-platform |
| Slower | Faster |
| Uses Intent flags | Direct function call |
| UiDevice API | WidgetTester API |
| Separate test codebase | Unified with Flutter tests |

**Migration Complete:** The Java androidTest directory has been removed.

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

## Migration Complete! 🎉

The Java screenshot test has been fully replaced:

✅ Old Java test removed  
✅ Fastlane updated to use Flutter driver  
✅ Screenshots save to correct directories automatically  
✅ Works on both Android and iOS  

## Optional Next Steps

1. Test on multiple devices/form factors
2. Add locale support for internationalization
3. Set up CI/CD integration
4. Verify screenshot quality on real devices

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

# Via Fastlane (RECOMMENDED)
cd android && fastlane screenshots  # Android
cd ios && fastlane screenshots      # iOS
fastlane screenshots_all            # Both platforms

# Via Flutter Driver directly
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/screenshot_test.dart \
  --flavor fmain

# Run on specific device
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/screenshot_test.dart \
  --flavor fmain \
  -d emulator-5554
```

## Help

- **Integration test docs**: See `integration_test/README.md`
- **Comparison**: See `transcript/FLUTTER_VS_JAVA_SCREENSHOTS.md`
- **Full details**: See `transcript/FLUTTER_SCREENSHOT_IMPLEMENTATION.md`

---

**Ready to generate screenshots!** Just run:
```bash
flutter pub get
cd android && fastlane screenshots  # For Android
cd ios && fastlane screenshots      # For iOS
```

Or use Flutter driver directly:
```bash
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/screenshot_test.dart \
  --flavor fmain
```
