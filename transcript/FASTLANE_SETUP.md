# Fastlane Setup for Android and iOS Screenshots

## Overview

This document summarizes the Fastlane configuration and screenshot generation setup for the webspace_app Flutter project. The work was completed across two sessions to enable automated screenshot capture for both Android and iOS platforms.

## Branch

All work was completed on branch: `claude/setup-fastlane-structure-CQmnG`

## Android Screenshot Setup (Completed)

### Summary

Successfully implemented automated screenshot generation for Android with workarounds for Android 13+ scoped storage restrictions.

### Key Components

#### 1. Test Infrastructure
- **File**: `android/app/src/androidTest/java/org/codeberg/theoden8/webspace/ScreenshotTest.java`
- **Purpose**: UI test that captures screenshots using Screengrab
- **Key Details**:
  - Uses `MainActivity` as the launch activity (not `FlutterActivity` directly)
  - Captures screenshots with `Screengrab.screenshot("01-main-screen")`
  - Uses AndroidX test runner: `androidx.test.runner.AndroidJUnitRunner`

#### 2. Screenshot Extraction Script
- **File**: `android/fastlane/extract_screenshots.sh`
- **Purpose**: Manual extraction of screenshots from Android 13+ internal storage
- **Why Needed**: Android 13+ scoped storage prevents Screengrab from accessing `/data/user/0/` directories
- **Approach**:
  1. Creates tar archive in app's private storage using `run-as`
  2. Streams archive via `adb shell "run-as $PACKAGE cat ..."` to avoid permission issues
  3. Extracts directly to `fastlane/metadata/android/en-US/images/phoneScreenshots/`
  4. Archives from `app_screengrab/en_US/images/screenshots/` to avoid nested directory structure

#### 3. Fastlane Configuration
- **File**: `android/fastlane/Fastfile`
- **Screenshots Lane**:
  - Builds Fmain flavor debug APKs
  - Builds androidTest APK
  - Runs Screengrab
  - Automatically falls back to manual extraction script when Screengrab fails (Android 13+)
- **Output**: `fastlane/metadata/android/en-US/images/phoneScreenshots/` (root fastlane directory)

#### 4. Screengrab Configuration
- **File**: `android/fastlane/Screengrabfile`
- **Configuration**:
  - App package: `org.codeberg.theoden8.webspace`
  - Test package: `org.codeberg.theoden8.webspace.test`
  - Instrumentation runner: `androidx.test.runner.AndroidJUnitRunner`
  - Locales: `en-US`
  - Output: `./fastlane/metadata/android/en-US/images/phoneScreenshots`

#### 5. Permissions Configuration

**Debug Manifest** (`android/app/src/debug/AndroidManifest.xml`):
```xml
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" />
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" />
<uses-permission android:name="android.permission.CHANGE_CONFIGURATION" />
```

**Main Manifest** (`android/app/src/main/AndroidManifest.xml`):
```xml
<application android:requestLegacyExternalStorage="true">
```

**AndroidTest Manifest** (`android/app/src/androidTest/AndroidManifest.xml`):
```xml
<instrumentation
    android:name="androidx.test.runner.AndroidJUnitRunner"
    android:targetPackage="org.codeberg.theoden8.webspace" />
```

### Usage

From project root:
```bash
bundle exec fastlane android screenshots
```

Or run extraction script directly after test:
```bash
./android/fastlane/extract_screenshots.sh
```

### Key Issues Resolved

1. **Flavor Naming**: Using `Fmain` flavor for screenshots (not `Fdroid`)
2. **Flutter APK Paths**: Correct path is `build/app/outputs/flutter-apk/app-fmain-debug.apk`
3. **Activity Launch**: Changed from `FlutterActivity` to `MainActivity`
4. **AndroidX Migration**: Updated test runner from `android.support.test.runner.AndroidJUnitRunner` to `androidx.test.runner.AndroidJUnitRunner`
5. **Android 13+ Scoped Storage**: Manual extraction using `adb shell run-as` and tar streaming
6. **Permission Grants**: Removed `maxSdkVersion` restrictions to allow permission grants on all API levels
7. **Script Path Resolution**: Used `File.expand_path` in Ruby and dynamic path calculation in bash
8. **Tar Permission Issues**: Create archive in app storage and stream via cat instead of writing to `/data/local/tmp`
9. **Directory Structure**: Archive from final screenshot directory to avoid nested subdirectories
10. **Output Directory**: Moved from `android/fastlane/` to root `fastlane/` directory

## iOS Screenshot Setup (Incomplete - Requires macOS)

### Summary

iOS Fastlane configuration has been set up but cannot be completed on Linux. Requires macOS with Xcode to create UI test target.

### Current State

#### Configuration Files

**Snapfile** (`ios/fastlane/Snapfile`):
- Devices: iPhone 15 Pro Max, iPhone 15 Pro, iPhone SE (3rd gen), iPad Pro variants
- Languages: `en-US`
- Scheme: `Runner`
- Workspace: `Runner.xcworkspace`
- Project: `Runner.xcodeproj`
- Output: `../../fastlane/screenshots` (root fastlane directory)
- Status bar override enabled

**Fastfile** (`ios/fastlane/Fastfile`):
- Screenshots lane configured to use Snapfile settings
- Frame screenshots lane configured for device frame overlays

#### Test File

**File**: `ios/RunnerTests/SnapshotTests.swift`
- Contains UI test code for screenshots
- Uses Fastlane's snapshot helper
- **Problem**: Not added to any UI test target

### Blocking Issues

1. **No UI Test Target**:
   - Current target: `RunnerTests` is a **unit test** target (product type: `com.apple.product-type.bundle.unit-test`)
   - Required: UI test target (product type: `com.apple.product-type.bundle.ui-testing`)
   - Fastlane's `snapshot` requires a UI test target to run

2. **Linux Environment**:
   - iOS screenshot generation requires macOS with Xcode
   - Needs iOS Simulator
   - Cannot run on Linux

### Required Setup Steps (macOS Only)

Must be performed on macOS with Xcode installed:

1. **Open Project in Xcode**:
   ```bash
   open ios/Runner.xcworkspace
   ```

2. **Create UI Test Target**:
   - File → New → Target
   - Select "iOS UI Testing Bundle"
   - Name: `RunnerUITests`
   - Target: Runner
   - Finish

3. **Add Target to Scheme**:
   - Product → Scheme → Edit Scheme
   - Select "Test" action
   - Click "+" to add test target
   - Check `RunnerUITests`

4. **Initialize Fastlane Snapshot Helper**:
   ```bash
   cd ios
   fastlane snapshot init
   ```
   This creates `SnapshotHelper.swift`

5. **Add Files to UI Test Target**:
   - In Xcode Project Navigator, select `ios/RunnerTests/SnapshotTests.swift`
   - In File Inspector (right panel), check the box for `RunnerUITests` target
   - Drag `SnapshotHelper.swift` into `RunnerUITests` group
   - Ensure it's added to `RunnerUITests` target

6. **Update Scheme**:
   - Ensure the Runner scheme includes the UI test target
   - Product → Scheme → Edit Scheme → Test
   - Verify `RunnerUITests` is checked

7. **Run Screenshots**:
   ```bash
   cd ios
   bundle exec fastlane ios screenshots
   ```

### Output Structure

Screenshots will be stored at:
```
fastlane/screenshots/
├── en-US/
│   ├── iPhone 15 Pro Max-01-main-screen.png
│   ├── iPhone 15 Pro-01-main-screen.png
│   └── ...
```

## Directory Structure

```
fastlane/                                    # Root fastlane directory (shared)
├── metadata/
│   └── android/
│       └── en-US/
│           └── images/
│               └── phoneScreenshots/
│                   ├── 01-main-screen.png
│                   └── ...
└── screenshots/                             # iOS screenshots (when generated)
    └── en-US/
        └── ...

android/
├── fastlane/
│   ├── Fastfile                            # Android lanes
│   ├── Screengrabfile                      # Screengrab configuration
│   └── extract_screenshots.sh              # Android 13+ extraction script
└── app/
    └── src/
        ├── androidTest/
        │   ├── AndroidManifest.xml         # Test instrumentation configuration
        │   └── java/.../ScreenshotTest.java
        ├── debug/
        │   └── AndroidManifest.xml         # Debug-only screenshot permissions
        └── main/
            └── AndroidManifest.xml         # requestLegacyExternalStorage

ios/
├── fastlane/
│   ├── Fastfile                            # iOS lanes
│   └── Snapfile                            # Snapshot configuration
└── RunnerTests/
    ├── SnapshotTests.swift                 # UI test for screenshots
    └── RunnerTests.swift
```

## Commits on claude/setup-fastlane-structure-CQmnG

All commits from this work (chronological order):

1. Initial Fastlane structure and Android configuration
2. Add Screengrab configuration and screenshot test
3. Fix activity launch in screenshot test (MainActivity vs FlutterActivity)
4. Update to AndroidX test runner
5. Add storage permissions for screenshot capture
6. Remove maxSdkVersion from storage permissions
7. Add requestLegacyExternalStorage to main manifest
8. Create extract_screenshots.sh for Android 13+ manual extraction
9. Update Fastfile to automatically run extraction script on Screengrab failure
10. Fix screenshot extraction and move output to root fastlane directory
11. Fix extract_screenshots.sh path in Fastfile
12. Strip directory structure when extracting screenshots
13. Fix script path resolution for extract_screenshots.sh
14. Fix tar archive to extract screenshots without extra directory (FINAL ANDROID FIX)
15. Configure iOS screenshot paths to use root fastlane directory
16. Fix iOS snapshot workspace path configuration
17. Add project fallback to iOS Snapfile configuration

**Final commit**: `51b6373` - "Add project fallback to iOS Snapfile configuration"

## Testing Status

### Android
✅ **Working on Linux**
- Test execution: Working
- Screenshot capture: Working
- Screenshot extraction: Working (with manual script)
- Output location: Correct (`fastlane/metadata/android/en-US/images/phoneScreenshots/`)
- Directory structure: Correct (no extra nested directories)

### iOS
❌ **Incomplete - Requires macOS**
- Configuration: Complete
- Test file: Exists but not in UI test target
- Blocking: No UI test target exists
- Environment: Requires macOS + Xcode
- Status: Cannot proceed on Linux

## Known Limitations

### Android
1. **Android 13+ Limitation**: Screengrab cannot directly access internal storage on Android 13+. Workaround implemented using manual extraction script.
2. **Permission Grants**: WRITE_EXTERNAL_STORAGE permission must be declared on all API levels for Fastlane's permission granting logic to work, even though it's not used on Android 13+.

### iOS
1. **macOS Only**: iOS screenshot generation cannot be performed on Linux
2. **UI Test Target Required**: Must create proper UI test target in Xcode
3. **Simulator Required**: Needs iOS Simulator to run tests
4. **Code Signing**: May require Apple Developer account and proper provisioning profiles

## Next Steps

### For Android
Android screenshot setup is complete and production-ready.

Optional improvements:
- Add more screenshots to `ScreenshotTest.java` for different app screens
- Configure additional locales in `Screengrabfile`
- Add screenshot comparison/validation

### For iOS
**Must be completed on macOS with Xcode:**

1. Create UI test target as documented above
2. Add SnapshotTests.swift to UI test target
3. Initialize and configure Fastlane snapshot helper
4. Test screenshot generation
5. Commit UI test target changes to project.pbxproj

## References

- [Fastlane Screengrab Documentation](https://docs.fastlane.tools/actions/screengrab/)
- [Fastlane Snapshot Documentation](https://docs.fastlane.tools/actions/snapshot/)
- [Android 13 Scoped Storage Changes](https://developer.android.com/about/versions/13/behavior-changes-13#granular-media-permissions)
- [AndroidX Test Documentation](https://developer.android.com/training/testing/set-up-project)

## Summary

The Fastlane setup successfully implemented automated screenshot generation for Android with robust workarounds for Android 13+ restrictions. The iOS configuration is complete but requires macOS with Xcode to finish the UI test target setup. All configuration files use a common root `fastlane/` directory for cross-platform consistency.
