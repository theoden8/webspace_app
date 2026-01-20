# Screenshot Generation Guide

Complete guide for generating app store screenshots for WebSpace using Flutter integration tests.

## Table of Contents

- [Overview](#overview)
- [Quick Start](#quick-start)
- [How It Works](#how-it-works)
- [What Gets Captured](#what-gets-captured)
- [Running Screenshots](#running-screenshots)
- [Configuration](#configuration)
- [Troubleshooting](#troubleshooting)
- [Migration from Java](#migration-from-java)
- [File Structure](#file-structure)
- [Best Practices](#best-practices)

## Overview

WebSpace uses **Flutter integration tests** for automated screenshot generation. This approach:

- ✅ Works on both Android and iOS (cross-platform)
- ✅ Faster and more reliable than external automation
- ✅ Automatically saves to correct directories for Fastlane/F-Droid/App Store
- ✅ Captures 10 screenshots covering all major app features
- ✅ Seeds realistic demo data automatically

### What Changed

The old Java/UiAutomator test has been **completely replaced** with Flutter integration tests:

| Old (Java) | New (Flutter) |
|------------|---------------|
| External automation | Internal testing |
| Android only | Cross-platform |
| Slower | Faster |
| Uses Intent flags | Direct function call |
| UiDevice API | WidgetTester API |
| ~428 lines | ~280 lines |

## Quick Start

### Prerequisites

**General:**
- Flutter SDK installed and in PATH
- Fastlane installed: `gem install fastlane` or `brew install fastlane`

**Android:**
- Android SDK installed
- Android Emulator or physical device connected
- Device unlocked and visible via `adb devices`

**iOS:**
- macOS required
- Xcode installed
- iOS Simulators installed (included with Xcode)

### Generate Screenshots

**Method 1: Via Fastlane (RECOMMENDED)**

```bash
# Android
cd android
fastlane screenshots

# iOS
cd ios
fastlane screenshots

# Both platforms
fastlane screenshots_all
```

**Method 2: Flutter Driver Directly**

```bash
# With screenshot capture
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/screenshot_test.dart \
  --flavor fmain

# Specific device
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/screenshot_test.dart \
  --flavor fmain \
  -d <device_id>
```

### Check Available Devices

```bash
# Flutter devices
flutter devices

# Android only
adb devices

# iOS only
xcrun simctl list devices
```

### Screenshot Output Locations

Screenshots are automatically saved to:
- **Android**: `fastlane/metadata/android/en-US/images/phoneScreenshots/`
- **iOS**: `fastlane/screenshots/en-US/`
- **Override**: Set `SCREENSHOT_DIR` environment variable

## How It Works

The screenshot generation process:

1. **Initialize test binding** - Sets up Flutter integration test environment
2. **Seed demo data** - Calls `seedDemoData()` directly to populate realistic test data
3. **Launch app** - Starts the app via `main()`
4. **Navigate & capture** - Walks through UI flow taking 10 screenshots
5. **Save screenshots** - Stores in platform-specific fastlane directories

### Architecture

```
┌─────────────────────────────────────────┐
│      Flutter Integration Test           │
│  - screenshot_test.dart                 │
│  - Seeds demo data directly             │
│  - Uses Widget testing API              │
│  - Runs in same process as app          │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│         WebSpace App                    │
│  - Launched via main()                  │
│  - Data already seeded                  │
│  - Full access to widget tree           │
└─────────────────────────────────────────┘
```

### Demo Data

The test automatically creates realistic data:

**Sample Sites:**
- My Blog (https://example.com/blog)
- Tasks (https://tasks.example.com)
- Notes (https://notes.example.com)
- Home Dashboard (http://homeserver.local:8080)
- Personal Wiki (http://192.168.1.100:3000)
- Media Server (http://192.168.1.101:8096)

**Sample Webspaces:**
- **All** - Shows all sites (default view)
- **Work** - Blog, Tasks, and Notes
- **Home Server** - Dashboard, Wiki, and Media Server

To customize test data, edit `lib/demo_data.dart`.

## What Gets Captured

The test captures **10 screenshots** covering the complete app flow:

1. **01-all-sites** - Main screen with all sites
2. **02-sites-drawer** - Navigation drawer with site list
3. **03-site-webview** - DuckDuckGo site loaded
4. **04-drawer-with-site** - Drawer showing selected site
5. **05-work-webspace** - Work webspace view
6. **06-work-sites-drawer** - Work webspace drawer
7. **07-add-workspace-dialog** - New workspace dialog
8. **08-workspace-name-entered** - Dialog with name filled
9. **09-workspace-sites-selected** - Dialog with sites selected
10. **10-new-workspace-created** - Main screen with new workspace

## Running Screenshots

### Commands Cheat Sheet

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

### Adding More Devices

**iOS Simulators:**

```bash
# See available simulators
xcrun simctl list devices

# Create new simulator
xcrun simctl create "iPhone 14 Pro" "iPhone 14 Pro" "iOS 17.0"

# Add to ios/fastlane/Snapfile
devices([
  "iPhone 14 Pro",
  "iPhone 15 Pro Max",
  "iPad Pro (12.9-inch) (6th generation)"
])
```

**Android Emulators:**

```bash
# See available emulators
emulator -list-avds

# Create new emulator
avdmanager create avd -n Pixel_6_API_33 \
  -k "system-images;android-33;google_apis;x86_64" -d pixel_6

# Start emulator
emulator -avd Pixel_6_API_33 &
```

## Configuration

### iOS Configuration

Edit `ios/fastlane/Snapfile`:

```ruby
# Devices
devices([
  "iPhone 15 Pro Max",      # 6.7-inch display
  "iPhone 15 Pro",          # 6.1-inch display
  "iPhone SE (3rd generation)", # 4.7-inch display
  "iPad Pro (12.9-inch) (6th generation)",
  "iPad Pro (11-inch) (4th generation)"
])

# Languages
languages([
  "en-US",
  "de-DE",
  "es-ES",
  "fr-FR"
])

# Dark mode
dark_mode(true)
```

### Android Configuration

Edit `android/fastlane/Screengrabfile`:

```ruby
# Locales
locales(['en-US', 'de-DE', 'es-ES', 'fr-FR'])

# Device types: phone, sevenInch, tenInch, tv, wear
device_type('phone')

# Flavor
app_apk_path('app/build/outputs/apk/fmain/debug/app-fmain-debug.apk')
tests_apk_path('app/build/outputs/apk/androidTest/fmain/debug/app-fmain-debug-androidTest.apk')
```

### Customizing Screenshot Test

Edit `integration_test/screenshot_test.dart`:

```dart
testWidgets('Take screenshots of app flow', (WidgetTester tester) async {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Seed demo data
  await seedDemoData();

  // Launch app
  app.main();
  await tester.pumpAndSettle(const Duration(seconds: 10));

  // Convert surface for platform views
  await binding.convertFlutterSurfaceToImage();
  await tester.pumpAndSettle();

  // Capture screenshot
  await binding.takeScreenshot('01-all-sites');
  await tester.pump();
  await Future.delayed(const Duration(seconds: 2));

  // Add more interactions...
}
```

**Tips:**
- Use `binding.takeScreenshot("name")` to capture screenshots
- Use Flutter's widget finders: `find.text()`, `find.byType()`, `find.byIcon()`
- Use `tester.pumpAndSettle()` to wait for animations
- Add `Future.delayed()` for content loading
- Number screenshots (01-, 02-, etc.) to control ordering

## Troubleshooting

### General Issues

**Test fails with "element not found"**
- Increase wait times in `pumpAndSettle` calls
- Check widget tree with Flutter DevTools
- Verify demo data is seeding correctly

**Screenshots not saving**
- Use `flutter drive` instead of `flutter test`
- Check device storage permissions
- Look for screenshots in test output directory
- Verify `IntegrationTestWidgetsFlutterBinding` is initialized

**Slow execution**
- This is normal - webviews need time to load
- Adjust timing constants if needed
- Timing is more predictable than Java version

**Screenshots are blank**
- Increase sleep/wait times in the test
- Check that app actually launches
- Verify device is unlocked

### Android Issues

**"No connected devices"**
```bash
# Check devices
adb devices

# Start emulator
emulator -avd Pixel_6_API_33 &
```

**"Tests APK not found"**
- APKs are built automatically by fastlane
- Manual build: `./gradlew assembleFmainDebugAndroidTest`

**Build errors with dependencies**
```bash
cd android
./gradlew --refresh-dependencies
./gradlew clean
```

**Test data not loading**
```bash
# Check logcat for demo seeding messages
adb logcat | grep -E "(DEMO_MODE|SEEDING DEMO DATA)"
```

### iOS Issues

**"Unable to find simulator"**
```bash
# See available simulators
xcrun simctl list devices

# Ensure names in Snapfile match exactly
```

**"UI Tests failed to build"**
- Open Xcode and build project manually
- Ensure RunnerTests target is enabled
- Verify `ios/RunnerTests/SnapshotTests.swift` exists

**"Snapshot helper not found"**
```bash
cd ios
fastlane snapshot init
```

**Screenshots show wrong language**
- Check `languages` setting in Snapfile
- Device system language might override settings

### Performance Tips

**Tests time out**
- Increase sleep times between interactions
- Check app isn't stuck on loading screen
- Verify network connectivity

**Want faster execution**
- Run on fewer devices initially
- Test locally on single device first
- Reduce wait times once flow is stable

## Migration from Java

### What Was Done

The Java/UiAutomator screenshot test has been fully replaced:

✅ Replaced `ScreenshotTest.java` with Flutter integration test
✅ Added `integration_test` dependency to `pubspec.yaml`
✅ Created `integration_test/screenshot_test.dart`
✅ Created `test_driver/integration_test.dart` with screenshot saving
✅ Updated Android fastlane to use `flutter drive`
✅ Updated iOS fastlane to use `flutter drive`
✅ Fixed screenshot 3 to capture drawer closing animation
✅ Removed old Java androidTest files
✅ Added comprehensive documentation

### Comparison

**Code Comparison - Finding Elements:**

```java
// Java/UiAutomator
private UiObject2 findElement(String text) {
    UiObject2 obj = device.findObject(By.text(text));
    if (obj == null) {
        obj = device.findObject(By.textContains(text));
    }
    if (obj == null) {
        obj = device.findObject(By.desc(text));
    }
    return obj;
}
```

```dart
// Flutter
final workWebspaceFinder = find.text('Work');
final nameFieldFinder = find.byType(TextField).first;
final addButton = find.byIcon(Icons.add);
```

**Code Comparison - Interactions:**

```java
// Java/UiAutomator
UiObject2 button = findElement("Add Webspace");
button.click();
Thread.sleep(SHORT_DELAY);

UiObject2 nameField = findElement("Workspace name");
nameField.click();
nameField.setText("Entertainment");
device.pressBack();  // Hide keyboard
```

```dart
// Flutter
final addButton = find.text('Add Webspace');
await tester.tap(addButton);
await tester.pumpAndSettle(const Duration(seconds: 3));

final nameField = find.byType(TextField).first;
await tester.tap(nameField);
await tester.enterText(nameField, 'Entertainment');
await tester.testTextInput.receiveAction(TextInputAction.done);
```

**Code Comparison - Screenshots:**

```java
// Java/UiAutomator
Screengrab.screenshot("01-all-sites");
Thread.sleep(MEDIUM_DELAY);
```

```dart
// Flutter
await binding.takeScreenshot('01-all-sites');
await tester.pumpAndSettle(const Duration(seconds: 5));
```

### Advantages of Flutter Approach

**Java/UiAutomator:**
- ✅ Well-established for Android
- ✅ Can test system-level dialogs
- ❌ Android-only (iOS needs separate tests)
- ❌ Slower (external process)
- ❌ More flaky (timing-sensitive)
- ❌ Harder to debug

**Flutter Integration:**
- ✅ Cross-platform (same test for Android/iOS)
- ✅ Faster execution (same process)
- ✅ More reliable (direct widget access)
- ✅ Easier to debug (standard Flutter tools)
- ✅ Better IDE support
- ✅ Can access app state directly
- ✅ Simpler setup
- ❌ Can't test system dialogs easily

### Migration Complete! 🎉

The Flutter screenshot test is now the standard:

✅ Old Java test removed
✅ Fastlane updated to use Flutter driver
✅ Screenshots save to correct directories automatically
✅ Works on both Android and iOS

## File Structure

```
webspace_app/
├── integration_test/
│   ├── screenshot_test.dart     # Main screenshot test
│   └── README.md                # Integration test documentation
├── test_driver/
│   └── integration_test.dart    # Test driver for flutter drive
├── lib/
│   └── demo_data.dart           # Demo data seeding logic
├── android/
│   └── fastlane/
│       ├── Fastfile             # Fastlane automation
│       ├── Screengrabfile       # Android screenshot config
│       └── metadata/android/en-US/images/phoneScreenshots/  # Output
├── ios/
│   └── fastlane/
│       ├── Fastfile             # Fastlane automation
│       ├── Snapfile             # iOS screenshot config
│       └── screenshots/en-US/   # Output
└── transcript/
    └── SCREENSHOTS.md           # This file
```

## Best Practices

1. **Keep tests simple** - Focus on capturing key screens, not comprehensive testing
2. **Use consistent naming** - Number screenshots (01-, 02-, etc.) to control display order
3. **Wait for animations** - Always add delays after navigation or button taps
4. **Test locally first** - Run on single device before generating all screenshots
5. **Don't commit screenshots** - Add large screenshot files to `.gitignore`
6. **Optimize images** - Consider compressing before uploading to stores
7. **Update regularly** - Regenerate when UI changes significantly
8. **Use realistic data** - Demo data should showcase real-world usage
9. **Test on multiple devices** - Verify screenshots look good across form factors
10. **Verify output** - Always check generated screenshots before publishing

## Additional Resources

- **Integration test docs**: See `integration_test/README.md`
- [Fastlane Snapshot (iOS)](https://docs.fastlane.tools/actions/snapshot/)
- [Fastlane Screengrab (Android)](https://docs.fastlane.tools/actions/screengrab/)
- [App Store Screenshot Specifications](https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications)
- [Google Play Screenshot Guidelines](https://support.google.com/googleplay/android-developer/answer/9866151)
- [F-Droid Metadata](https://f-droid.org/docs/All_About_Descriptions_Graphics_and_Screenshots/)

---

**Ready to generate screenshots!**

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
