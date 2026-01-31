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
- **THEN** 10 screenshots are captured (5 per theme)

#### Scenario: Generate screenshots on iOS

- **GIVEN** an iOS simulator is running
- **WHEN** the user runs `fastlane ios screenshots`
- **THEN** 10 screenshots are captured (5 per theme)

---

### SCREENSHOT-002 - Demo Data Seeding

Screenshots SHALL use demo data seeded automatically via `lib/demo_data.dart`.

#### Scenario: Seed demo data before screenshots

- **WHEN** the screenshot test starts
- **THEN** demo sites are seeded (SearXNG, Piped, Nitter, Reddit, GitHub, Hacker News, Weights & Biases, Wikipedia)
- **AND** demo webspaces are created (All, Work, Privacy, Social)

---

### SCREENSHOT-003 - Screenshot Coverage

The test SHALL capture 5 screenshots per theme (10 total): `01-site-webview`, `02-site-settings`, `03-work-sites-drawer`, `04-work-webspace`, `05-workspace-sites-selected`.

#### Scenario: Capture all screenshots

- **WHEN** the screenshot test completes
- **THEN** 10 screenshots are saved with `-light` and `-dark` variants

#### Scenario: Capture webview content on Android

- **GIVEN** screenshot 01 includes webview content
- **WHEN** the test requests screenshot on Android
- **THEN** ADB screencap is used via `@@NATIVE_SCREENSHOT:<name>@@` marker

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

## Files

**Test files:**
- `integration_test/screenshot_test.dart` - Main test
- `test_driver/integration_test.dart` - Driver with native screenshot support
- `lib/demo_data.dart` - Demo data seeding

**Fastlane config:**
- `android/fastlane/Fastfile`, `ios/fastlane/Fastfile` - Screenshot lanes
- `screenshots/android/`, `screenshots/ios/` - Output + frameit config

**CI:**
- `.github/workflows/build-and-test.yml` - Build + conditional screenshots
