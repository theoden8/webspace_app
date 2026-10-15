# Screenshot Generation Specification

## Purpose

Automated screenshot generation for app store submissions using Flutter integration tests and Fastlane, with CI/CD support.

## Status

- **Status**: Completed
- **Platforms**: Android, iOS, macOS
- **CI Integration**: GitHub Actions (conditional on file changes)

---

## Requirements

### SCREENSHOT-001 - Cross-Platform Generation

Screenshots SHALL be generated using Flutter integration tests on Android, iOS and macOS.

#### Scenario: Generate screenshots on Android

- **GIVEN** an Android emulator is running
- **WHEN** the user runs `bundle exec fastlane android screenshots`
- **THEN** 8 screenshots are captured (4 per theme)

#### Scenario: Generate screenshots on iOS

- **GIVEN** an iOS simulator is running
- **WHEN** the user runs `fastlane ios screenshots`
- **THEN** 8 screenshots are captured (4 per theme)

#### Scenario: Generate screenshots on macOS

- **GIVEN** a Mac
- **WHEN** the user runs `fastlane mac screenshots`
- **THEN** 8 screenshots are captured (4 per theme) into `screenshots/macos/`

---

### SCREENSHOT-002 - Demo Data Seeding

Screenshots SHALL use demo data seeded automatically via `lib/demo_data.dart`.

#### Scenario: Seed demo data before screenshots

- **WHEN** the screenshot test starts
- **THEN** demo sites are seeded (SearXNG, Piped, Nitter, Reddit, GitHub, Hacker News, Weights & Biases, Wikipedia)
- **AND** demo webspaces are created (All, Work, Privacy, Social)

#### Scenario: The run keeps the installed app's sites

- **GIVEN** a Mac or a physical device where the debug build shares the installed app's storage
- **WHEN** the screenshot test seeds and runs
- **THEN** the seed goes to an in-memory SharedPreferences store (INTEG-004)
- **AND** no orphan sweep runs against the demo site list (INTEG-004)

---

### SCREENSHOT-003 - Screenshot Coverage

The test SHALL capture 4 screenshots per theme (8 total): `01-site-settings`, `02-work-sites-drawer`, `03-work-webspace`, `04-workspace-sites-selected`.

#### Scenario: Capture all screenshots

- **WHEN** the screenshot test completes
- **THEN** 8 screenshots are saved with `-light` and `-dark` variants

---

### SCREENSHOT-004 - CI/CD Integration

Screenshots SHALL be generated in GitHub Actions when relevant files change.

#### Scenario: Trigger screenshot generation in CI

- **GIVEN** changes to screenshot-related files (test, demo data, fastlane, workflow)
- **WHEN** CI workflow runs
- **THEN** screenshots are generated on the Android emulator, the iOS simulator and the macOS runner

#### Scenario: One download for every platform

- **WHEN** a manual (`workflow_dispatch`) run finishes
- **THEN** a `screenshots` artifact holds each platform's set in its own folder (`android-screenshots/`, `ios-screenshots/`, `macos-screenshots/`)
- **AND** a platform that failed leaves its folder out instead of withholding the others

---

### SCREENSHOT-005 - Device Frame Integration

Android and iOS screenshots SHALL be frameable with device bezels using frameit. macOS screenshots are left unframed: frameit has no Mac bezel (SCREENSHOT-007).

#### Scenario: Add device frames

- **WHEN** the user runs `fastlane add_device_frames`
- **THEN** screenshots are resized and framed with device bezels

---

### SCREENSHOT-006 - Theme Support

Screenshots SHALL be captured in both light and dark themes.

#### Scenario: Generate themed screenshots

- **WHEN** the screenshot test runs
- **THEN** it executes twice (once per theme)
- **AND** files are named with `-light`/`-dark` suffix

---

### SCREENSHOT-007 - macOS Window Capture

On macOS a screenshot SHALL be the app's window as the window server composites it, so the site's WKWebView is in it, at a size App Store Connect takes for a Mac app (1280x800, 1440x900, 2560x1600 or 2880x1800). Flutter's macOS `integration_test` plugin does not implement `captureScreenshot`, so the Runner provides a debug-only `window_capture` channel; no release build carries it.

#### Scenario: Capture includes the webview

- **GIVEN** a site is on screen
- **WHEN** the test takes a screenshot on macOS
- **THEN** the image is the window captured with ScreenCaptureKit from the current process's own shareable content (macOS 14.4+, no Screen Recording permission), webview included
- **AND** the driver writes it through `onScreenshot` like an iOS screenshot

#### Scenario: Store size

- **WHEN** the test starts on macOS
- **THEN** the window is set to 1440x900 points, title bar included
- **AND** a capture whose pixel size is not a Mac App Store size fails the test

---

### SCREENSHOT-008 - Android Capture In Texture Mode

On Android every screenshot SHALL be taken by `binding.takeScreenshot`, which after `convertFlutterSurfaceToImage()` is a `PixelCopy` of the FlutterView's rectangle in the activity window, and the run SHALL create its webviews in texture layer hybrid composition (PAUSE-032), so a site's page is in that copy. In hybrid composition, the app's default, Flutter draws into `FlutterImageView`s layered around the WebView and an image view presents the last image it acquired: a shot of a site showed the previous screen (PR #77). In texture mode the page renders into a texture Flutter composites in its own frame. The test turns the mode on through the gate `main()` reads (DEVTOOLS-011), with developer mode and the Texture page rendering switch in its in-memory preferences, and holds off the proxy router that developer mode would also start, so the run keeps PROXY-008. Developer mode shows nothing on the screens SCREENSHOT-003 captures. No other platform changes mode, and nothing captures the screen through adb.

#### Scenario: A site on screen is in the shot

- **GIVEN** Android and a site's page on screen
- **WHEN** the test takes a screenshot
- **THEN** the image is the one `takeScreenshot` returns, with the page in it
- **AND** every webview of the run was created with `useHybridComposition: false`
- **AND** the image has no status or navigation bar, which are windows of their own outside the copy

#### Scenario: The shot is the FlutterView

- **WHEN** the test takes a screenshot on Android
- **THEN** the PNG's pixel size equals the FlutterView's physical size, or the test fails
- **AND** a screenshot that does not arrive within its timeout fails the test

---

## Files

**Test files:**
- `integration_test/screenshot_test.dart` - Main test
- `test_driver/integration_test.dart` - Driver that writes each screenshot the test takes into `SCREENSHOT_DIR`
- `lib/demo_data.dart` - Demo data seeding
- `macos/Runner/WindowCapturePlugin.swift` - Debug-only macOS window capture

**Fastlane config:**
- `android/fastlane/Fastfile`, `ios/fastlane/Fastfile`, `macos/fastlane/Fastfile` - Screenshot lanes
- `screenshots/android/`, `screenshots/ios/` - Output + frameit config
- `screenshots/macos/` - Output (no frameit: Mac screenshots are unframed window captures)

**CI:**
- `.github/workflows/build-and-test.yml` - Build + conditional screenshots
