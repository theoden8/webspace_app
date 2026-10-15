# Screenshot Generation Specification

## Purpose

Automated screenshot generation for app store submissions using Flutter integration tests and Fastlane, with CI/CD support.

## Status

- **Status**: Completed
- **Platforms**: Android, iOS
- **CI Integration**: GitHub Actions (conditional on file changes)

---

## Requirements

### SCREENSHOT-001 - Cross-Platform Generation

Screenshots SHALL be generated using Flutter integration tests on both Android and iOS.

#### Scenario: Generate screenshots on Android

- **GIVEN** an Android emulator is running
- **WHEN** the user runs `bundle exec fastlane android screenshots`
- **THEN** 8 screenshots are captured (4 per theme)

#### Scenario: Generate screenshots on iOS

- **GIVEN** an iOS simulator is running
- **WHEN** the user runs `fastlane ios screenshots`
- **THEN** 8 screenshots are captured (4 per theme)

---

### SCREENSHOT-002 - Demo Data Seeding

Screenshots SHALL use demo data seeded automatically via `lib/demo_data.dart`.

#### Scenario: Seed demo data before screenshots

- **WHEN** the screenshot test starts
- **THEN** demo sites are seeded (SearXNG, Piped, Nitter, Reddit, GitHub, Hacker News, Weights & Biases, Wikipedia)
- **AND** demo webspaces are created (All, Work, Privacy, Social)

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
- **THEN** screenshots are generated on both Android emulator and iOS simulator

---

### SCREENSHOT-005 - Device Frame Integration

Screenshots SHALL be frameable with device bezels using frameit.

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

**Fastlane config:**
- `android/fastlane/Fastfile`, `ios/fastlane/Fastfile` - Screenshot lanes
- `screenshots/android/`, `screenshots/ios/` - Output + frameit config

**CI:**
- `.github/workflows/build-and-test.yml` - Build + conditional screenshots
