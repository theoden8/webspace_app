# Screenshot Generation Specification

## Purpose

Automated screenshot generation for app store submissions using Flutter integration tests and Fastlane, with CI/CD support.

## Status

- **Status**: Completed
- **Platforms**: Android, iOS, macOS, Linux
- **CI Integration**: GitHub Actions (conditional on file changes)

---

## Requirements

### SCREENSHOT-001 - Cross-Platform Generation

Screenshots SHALL be generated using Flutter integration tests on Android, iOS, macOS and Linux.

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

#### Scenario: Generate screenshots on Linux

- **GIVEN** a Linux desktop session, or the CI session `scripts/linux_test_session.sh` sets up
- **WHEN** the user runs `fastlane linux screenshots`
- **THEN** 8 screenshots are captured (4 per theme) into `screenshots/linux/`

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

Screenshots SHALL be generated in GitHub Actions on a manual (`workflow_dispatch`) run and on every release PR, so a release cannot go green without them. The plan job decides which runs make them.

#### Scenario: Manual run

- **WHEN** Build and Test is run by hand
- **THEN** screenshots are generated on the Android emulator, the iOS simulator, the macOS runner and the Linux container

#### Scenario: Release PR

- **GIVEN** a pull request whose `pubspec.yaml` version line differs from its base (docs/releasing.md)
- **WHEN** CI runs on it
- **THEN** the same screenshot steps run
- **AND** a failed screenshot step leaves the release PR red

#### Scenario: One download for every platform

- **WHEN** a manual (`workflow_dispatch`) run finishes
- **THEN** a `screenshots` artifact holds each platform's set in its own folder (`android-screenshots/` as taken, `android-framed-screenshots/`, `ios-screenshots/`, `macos-screenshots/`, `linux-screenshots/`)
- **AND** a platform that failed leaves its folder out instead of withholding the others

---

### SCREENSHOT-005 - Device Frame Integration

Android and iOS screenshots SHALL be frameable with device bezels using frameit. macOS and Linux screenshots are left unframed: frameit has no desktop bezel, and the window captures carry their own title bar (SCREENSHOT-007, SCREENSHOT-009).

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
- **AND** on a screen shorter than that (a CI runner's) the window keeps its size, the rest below the screen's edge, and a resize the window does not take fails the test
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

### SCREENSHOT-009 - Linux Window Capture

On Linux a screenshot SHALL be the app's GTK window drawn into an image, with the title bar, shadow and rounded corners GTK draws for it, so the site's WPE view is in it and the window carries the native decoration Flathub's quality guidelines require of a screenshot. FlView paints through `gdk_cairo_draw_from_gl`, which reads its GL frame back for any cairo target, and the WPE view is a texture inside that frame, so the capture reads nothing back from the display server and works with the window covered or larger than the screen. The Runner provides the debug-only `window_capture` channel macOS has (`linux/window_capture.cc`); no release build carries it.

#### Scenario: Capture includes the webview

- **GIVEN** a site is on screen
- **WHEN** the test takes a screenshot on Linux
- **THEN** the image is the window drawn with `gtk_widget_draw`, webview included
- **AND** the driver writes it through `onScreenshot` like an iOS screenshot

#### Scenario: Window within Flathub's size

- **WHEN** the test starts on Linux
- **THEN** the Flutter view is set to 1000x650 logical pixels, which GTK's title bar brings to a window within the 1000x700 Flathub sets
- **AND** a view that has not reached that size 5 seconds after the resize fails the test

#### Scenario: Native decoration in CI

- **GIVEN** the CI session, which runs a headless weston beside Xvfb
- **WHEN** the screenshot lane runs
- **THEN** GTK opens the window on Wayland and draws its header bar and shadow, which the capture includes

---

## Files

**Test files:**
- `integration_test/screenshot_test.dart` - Main test
- `test_driver/integration_test.dart` - Driver that writes each screenshot the test takes into `SCREENSHOT_DIR`
- `lib/demo_data.dart` - Demo data seeding
- `macos/Runner/WindowCapturePlugin.swift` - Debug-only macOS window capture
- `linux/window_capture.cc` - Debug-only Linux window capture

**Fastlane config:**
- `android/fastlane/Fastfile`, `ios/fastlane/Fastfile`, `macos/fastlane/Fastfile`, `linux/fastlane/Fastfile` - Screenshot lanes
- `screenshots/android/`, `screenshots/ios/` - Output + frameit config
- `screenshots/macos/` - Output (no frameit: Mac screenshots are unframed window captures)
- `screenshots/linux/` - Output (no frameit, as on macOS)

**CI:**
- `.github/workflows/build-and-test.yml` - Build + conditional screenshots
- `scripts/linux_test_session.sh` - The Linux CI desktop session the lane runs in
