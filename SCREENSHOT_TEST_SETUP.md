# Android Screenshot Test Setup

This document explains how to generate screenshots for the Android app.

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
3. **Seed test data** - Run `test_data_seeder.dart` on the device to create:
   - 6 sample sites (My Blog, Tasks, Notes, Home Dashboard, Personal Wiki, Media Server)
   - 3 webspaces (All, Work, Home Server)
4. **Run tests** - Execute screenshot tests which navigate and capture images
5. **Save screenshots** - Store images in `android/fastlane/metadata/android/en-US/images/phoneScreenshots/`

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

The seeder runs automatically, but if you want to run it manually:
```bash
flutter run -d <device-id> android/fastlane/test_data_seeder.dart
```

### Customize test data

Edit `android/fastlane/test_data_seeder.dart` to change:
- Site names and URLs
- Webspace organization
- Number of sites/webspaces

## Files

- `android/fastlane/Fastfile` - Automation script (screenshots lane)
- `android/fastlane/test_data_seeder.dart` - Flutter script that seeds test data
- `android/app/src/androidTest/java/.../ScreenshotTest.java` - Screenshot test that navigates and captures
- `android/fastlane/metadata/android/en-US/images/phoneScreenshots/` - Output directory

## Manual Process (Advanced)

If you need to run steps separately:

```bash
# 1. Build APKs
cd android
./gradlew assembleFmainDebug assembleFmainDebugAndroidTest

# 2. Get device ID
adb devices

# 3. Seed data
cd ..
flutter run -d <device-id> android/fastlane/test_data_seeder.dart

# 4. Run screenshot tests
cd android
bundle exec fastlane screengrab
```

But normally, just use `bundle exec fastlane screenshots` and let it handle everything!
