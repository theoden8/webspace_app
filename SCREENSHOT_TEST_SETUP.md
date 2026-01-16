# Android Screenshot Test Setup

This document explains how to generate screenshots for the Android app using the automated DEMO_MODE approach.

## Automated Process

The screenshot generation is fully automated via Fastlane. Just run one command:

```bash
cd android
bundle exec fastlane screenshots
```

Or from project root:
```bash
bundle exec fastlane android screenshots
```

## What Happens Automatically

Fastlane will:

1. **Build APKs** - Build debug APK and androidTest APK
2. **Detect device** - Find connected Android device or emulator
3. **Launch app with DEMO_MODE** - The test launches the app with `DEMO_MODE=true` intent extra
4. **Seed test data** - Flutter automatically seeds demo data on startup when DEMO_MODE is detected:
   - 6 sample sites (My Blog, Tasks, Notes, Home Dashboard, Personal Wiki, Media Server)
   - 3 webspaces (All, Work, Home Server)
5. **Run tests** - Execute screenshot tests which navigate and capture images
6. **Save screenshots** - Store images in `android/fastlane/metadata/android/en-US/images/phoneScreenshots/`

## Prerequisites

- Android device connected or emulator running
- Device unlocked and visible via `adb devices`
- Flutter SDK in PATH

## Screenshots Captured

The automated tour captures 8 screenshots:

1. Webspaces list
2. All sites view (main screen)
3. Sites drawer
4. Site webview
5. Drawer with current site
6. Webspaces overview
7. Work webspace
8. Work webspace drawer

## How Demo Mode Works

The demo data seeding uses a clean flag-based approach:

1. **ScreenshotTest.java** launches the app with `intent.putExtra("DEMO_MODE", true)`
2. **MainActivity.kt** exposes this flag via method channel
3. **main.dart** checks the flag on startup and calls `seedDemoData()` if true
4. **demo_data.dart** contains all demo data logic (sites, webspaces, preferences)

This architecture ensures:
- Clean separation of concerns
- No code duplication between Java and Flutter
- Proper use of Flutter's data models
- Automatic demo data seeding without manual intervention

## Troubleshooting

### No device found

Error: "No Android device connected"

Solution:
```bash
# Check devices
adb devices

# Start an emulator if needed
emulator -avd <your_avd_name> &
```

### Test data not loading

Check the logcat output for demo seeding messages:
```bash
adb logcat | grep -E "(DEMO_MODE|SEEDING DEMO DATA)"
```

You should see:
- "DEMO_MODE enabled - seeding demo data" from main.dart
- "SEEDING DEMO DATA" from demo_data.dart
- "DEMO DATA SEEDING COMPLETE" when finished

### Customize test data

Edit `lib/demo_data.dart` to change:
- Site names and URLs
- Webspace organization
- Number of sites/webspaces
- Initial theme mode and preferences

## Files

- `android/fastlane/Fastfile` - Automation script (screenshots lane)
- `lib/demo_data.dart` - Demo data seeding logic (sites and webspaces)
- `lib/main.dart` - Checks DEMO_MODE flag and triggers seeding
- `android/app/src/main/kotlin/.../MainActivity.kt` - Exposes DEMO_MODE via method channel
- `android/app/src/androidTest/java/.../ScreenshotTest.java` - Screenshot test that launches with DEMO_MODE and navigates
- `android/fastlane/metadata/android/en-US/images/phoneScreenshots/` - Output directory

## Manual Process (Advanced)

If you need to run steps separately:

```bash
# 1. Build APKs
cd android
./gradlew assembleFmainDebug assembleFmainDebugAndroidTest

# 2. Get device ID
adb devices

# 3. Run screenshot tests (demo data seeds automatically on launch)
cd android
bundle exec fastlane screengrab
```

The demo data is automatically seeded when the test launches the app with DEMO_MODE=true, so no manual seeding step is needed.

But normally, just use `bundle exec fastlane screenshots` and let it handle everything!
