# Screenshot Generation Guide

This guide explains how to generate screenshots for both iOS App Store and Android F-Droid/Play Store using Fastlane.

## Prerequisites

### General
- **Fastlane installed**: `gem install fastlane` or `brew install fastlane`
- **Flutter SDK** installed and in PATH

### iOS Screenshots
- **macOS** required
- **Xcode** installed
- **iOS Simulators** installed (they're included with Xcode)
- Simulators must be booted or will be automatically booted by Fastlane

### Android Screenshots
- **Android SDK** installed
- **Android Emulator** or physical device connected
- **ADB** in PATH
- Device/emulator must be running and unlocked before generating screenshots

## Quick Start

### Generate iOS Screenshots

```bash
# From project root
cd ios
fastlane screenshots

# Or from project root
fastlane ios screenshots
```

Screenshots will be saved to: `ios/fastlane/screenshots/`

### Generate Android Screenshots

```bash
# From project root
cd android
fastlane screenshots

# Or from project root
fastlane android screenshots
```

Screenshots will be saved to: `android/fastlane/metadata/android/en-US/images/phoneScreenshots/`

### Generate F-Droid Specific Screenshots

```bash
# From android directory
cd android
fastlane screenshots_fdroid

# Or from project root
fastlane android screenshots_fdroid
```

## Configuration

### iOS Configuration

Edit `ios/fastlane/Snapfile` to customize:

**Devices**: Choose which iPhone/iPad models to generate screenshots for
```ruby
devices([
  "iPhone 15 Pro Max",      # 6.7-inch display
  "iPhone 15 Pro",          # 6.1-inch display
  "iPhone SE (3rd generation)", # 4.7-inch display
  "iPad Pro (12.9-inch) (6th generation)",
  "iPad Pro (11-inch) (4th generation)"
])
```

**Languages**: Add more locales for internationalization
```ruby
languages([
  "en-US",
  "de-DE",
  "es-ES",
  "fr-FR",
  "ja-JP"
])
```

**Dark Mode**: Enable dark mode screenshots
```ruby
dark_mode(true)
```

### Android Configuration

Edit `android/fastlane/Screengrabfile` to customize:

**Locales**: Add multiple languages
```ruby
locales(['en-US', 'de-DE', 'es-ES', 'fr-FR', 'it-IT'])
```

**Device Types**: Choose device form factors
```ruby
# Valid types: phone, sevenInch, tenInch, tv, wear
device_type('phone')
```

**Flavor**: Switch between fdroid and fdebug flavors
```ruby
# For F-Droid
app_apk_path('app/build/outputs/apk/fdroid/debug/app-fdroid-debug.apk')
tests_apk_path('app/build/outputs/apk/androidTest/fdroid/debug/app-fdroid-debug-androidTest.apk')
```

## Screenshot Test Data

The Android screenshot test automatically seeds the app with realistic test data using the **DEMO_MODE flag approach**. When the test launches the app with `DEMO_MODE=true`, Flutter automatically seeds demo data on startup.

### How It Works

1. **ScreenshotTest.java** launches the app with `intent.putExtra("DEMO_MODE", true)`
2. **MainActivity.kt** exposes this flag via method channel to Flutter
3. **main.dart** detects the flag on startup and calls `seedDemoData()`
4. **demo_data.dart** creates realistic test data using Flutter's native data models

### Sample Sites
- **My Blog** - Personal blog (https://example.com/blog)
- **Tasks** - Task management app (https://tasks.example.com)
- **Notes** - Notes application (https://notes.example.com)
- **Home Dashboard** - Home server dashboard (http://homeserver.local:8080)
- **Personal Wiki** - Local wiki server (http://192.168.1.100:3000)
- **Media Server** - Media streaming server (http://192.168.1.101:8096)

### Sample Webspaces
- **All** - Shows all sites (default view)
- **Work** - Organized workspace with Blog, Tasks, and Notes
- **Home Server** - Contains Dashboard, Wiki, and Media Server

This realistic test data helps potential users understand how the app organizes and manages multiple web applications.

To customize the test data, edit `lib/demo_data.dart`.

## Customizing Screenshot Content

### iOS: Edit Screenshot Test

Edit `ios/RunnerTests/SnapshotTests.swift`:

```swift
func testTakeScreenshots() throws {
    let app = XCUIApplication()

    // Wait for app to load
    sleep(2)

    // Capture main screen
    snapshot("01-main-screen")

    // Interact with UI elements
    let addButton = app.buttons["Add"]
    if addButton.exists {
        addButton.tap()
        sleep(1)
        snapshot("02-add-webview")
    }

    // Capture settings
    let settingsButton = app.buttons["Settings"]
    if settingsButton.exists {
        settingsButton.tap()
        sleep(1)
        snapshot("03-settings")
    }
}
```

**Tips:**
- Use `snapshot("name")` to capture a screenshot
- Use accessibility identifiers to find UI elements
- Add `sleep()` calls to wait for animations
- Each screenshot should have a unique descriptive name

### Android: Edit Screenshot Test

Edit `android/app/src/androidTest/java/org/codeberg/theoden8/webspace/ScreenshotTest.java`:

```java
@Test
public void takeScreenshots() throws InterruptedException {
    Screengrab.setDefaultScreenshotStrategy(new UiAutomatorScreenshotStrategy());

    // Wait for app to load
    Thread.sleep(3000);

    // Capture main screen
    Screengrab.screenshot("01-main-screen");

    // Interact with UI using UiAutomator
    UiDevice device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation());
    UiObject button = device.findObject(new UiSelector().text("Add"));
    if (button.exists()) {
        button.click();
        Thread.sleep(1000);
        Screengrab.screenshot("02-add-webview");
    }

    // Add more interactions as needed
}
```

**Note**: The current implementation includes a comprehensive screenshot tour with:
- Automatic demo data seeding via DEMO_MODE flag (see `lib/demo_data.dart`)
- Automated navigation through multiple screens including webspaces list, sites drawer, webview, and menu
- 8 screenshots covering the main app features for store listings

**Tips:**
- Use `Screengrab.screenshot("name")` to capture a screenshot
- Use UiAutomator's `UiDevice` and `UiSelector` to interact with UI
- Add `Thread.sleep()` to wait for animations and transitions
- Name screenshots with numbers to control ordering (01-, 02-, etc.)

## Adding More Devices/Simulators

### iOS Simulators

To see available simulators:
```bash
xcrun simctl list devices
```

To add a new simulator:
```bash
# iOS 17.0 iPhone 14 Pro
xcrun simctl create "iPhone 14 Pro" "iPhone 14 Pro" "iOS 17.0"
```

Then add it to `ios/fastlane/Snapfile`:
```ruby
devices([
  "iPhone 14 Pro",
  # ... other devices
])
```

### Android Emulators

To see available emulators:
```bash
emulator -list-avds
```

To create a new emulator:
```bash
# Create a Pixel 6 emulator
avdmanager create avd -n Pixel_6_API_33 -k "system-images;android-33;google_apis;x86_64" -d pixel_6
```

Start the emulator before running screenshots:
```bash
emulator -avd Pixel_6_API_33 &
```

## Troubleshooting

### iOS Issues

**"Unable to find simulator"**
- Run `xcrun simctl list devices` to see available simulators
- Make sure the simulator names in Snapfile match exactly
- Simulators are automatically booted by Fastlane

**"UI Tests failed to build"**
- Open Xcode and build the project manually
- Ensure RunnerTests target is enabled
- Check that `ios/RunnerTests/SnapshotTests.swift` exists

**"Snapshot helper not found"**
- First time setup: Run `fastlane snapshot init` from ios/ directory
- Then manually add `setupSnapshot(app)` to your test (already done)

**Screenshots are blank**
- Increase sleep times in the test
- Check that your app actually launches in the simulator
- Verify accessibility identifiers for UI elements

### Android Issues

**"No connected devices"**
- Start an Android emulator or connect a physical device
- Verify with `adb devices`
- Ensure device is unlocked

**"Tests APK not found"**
- The APKs are built automatically by the screenshots lane
- If issues persist, manually build: `./gradlew assembleFdebugAndroidTest`

**"ScreenshotTest not found"**
- Verify `android/app/src/androidTest/java/org/codeberg/theoden8/webspace/ScreenshotTest.java` exists
- Run `./gradlew clean` and try again

**Build errors with dependencies**
- Run `./gradlew --refresh-dependencies` from android/
- Check that `android/app/build.gradle` includes all required dependencies

**"Permission denied" errors**
- Grant all permissions to the app before running tests
- Consider adding permission grants in the test setup

### General Issues

**Screenshots show status bar/system UI**
- iOS: Set `override_status_bar(true)` in Snapfile (already enabled)
- Android: Status bar is captured by default; use image editing if needed

**Wrong language/locale**
- Check the `languages`/`locales` setting in Snapfile/Screengrabfile
- Device/simulator system language might override settings

**Tests time out**
- Increase sleep times between interactions
- Check that your app isn't stuck on a loading screen
- Verify network connectivity if app requires it

## Output Locations

### iOS Screenshots
```
ios/fastlane/screenshots/
├── en-US/
│   ├── iPhone 15 Pro Max-01-main-screen.png
│   ├── iPhone 15 Pro-01-main-screen.png
│   ├── iPad Pro (12.9-inch)-01-main-screen.png
│   └── ...
└── screenshots.html (preview file)
```

### Android Screenshots
```
android/fastlane/metadata/android/
└── en-US/
    └── images/
        └── phoneScreenshots/
            ├── 01-main-screen.png
            ├── 02-add-webview.png
            └── ...
```

## Frame Screenshots (Optional)

### iOS Device Frames

Add device frames around screenshots:

```bash
cd ios
fastlane frame_screenshots
```

This uses the `frameit` tool to add iPhone/iPad bezels. Configure in Fastfile:
```ruby
frameit(
  path: "./fastlane/screenshots",
  white: true  # or false for black bezels
)
```

Note: Device frame images must be downloaded separately.

### Android Device Frames

Android screenshot framing typically uses third-party tools or manual editing.

## Best Practices

1. **Keep tests simple**: Focus on capturing key screens, not comprehensive testing
2. **Use consistent naming**: Number screenshots to control display order (01-, 02-, etc.)
3. **Wait for animations**: Always add sleep/wait after navigation or button taps
4. **Test locally first**: Run on a single device before generating all screenshots
5. **Version control**: Don't commit large screenshot files; add to .gitignore if needed
6. **Optimize images**: Consider compressing screenshots before uploading to stores
7. **Update regularly**: Regenerate screenshots when UI changes significantly

## Additional Resources

- [Fastlane Snapshot (iOS)](https://docs.fastlane.tools/actions/snapshot/)
- [Fastlane Screengrab (Android)](https://docs.fastlane.tools/actions/screengrab/)
- [App Store Screenshot Specifications](https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications)
- [Google Play Screenshot Guidelines](https://support.google.com/googleplay/android-developer/answer/9866151)
- [F-Droid Metadata](https://f-droid.org/docs/All_About_Descriptions_Graphics_and_Screenshots/)
