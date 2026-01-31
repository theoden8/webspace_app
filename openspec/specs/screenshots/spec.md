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

Screenshots are generated using Flutter integration tests on both Android and iOS.

**Workflow:**
- Android: `bundle exec fastlane android screenshots`
- iOS: `fastlane ios screenshots`

**Output:** 8 screenshots total (4 per theme)

---

### SCREENSHOT-002 - Demo Data Seeding

Screenshots use demo data seeded automatically via `lib/demo_data.dart`.

**Demo sites:** DuckDuckGo, Piped, Nitter, Reddit, GitHub, Hacker News, Weights & Biases, Wikipedia

**Demo webspaces:**
- **All** - All sites
- **Work** - GitHub, Hacker News, Weights & Biases
- **Privacy** - DuckDuckGo, Piped, Nitter
- **Social** - Nitter, Reddit, Wikipedia

---

### SCREENSHOT-003 - Screenshot Coverage

The test captures 4 screenshots per theme (8 total):

| # | Name | Description |
|---|------|-------------|
| 1 | `01-site-webview` | DuckDuckGo loaded in webview |
| 2 | `02-work-sites-drawer` | Work webspace drawer |
| 3 | `03-work-webspace` | Work webspace view |
| 4 | `04-workspace-sites-selected` | Webspace creation with sites selected |

Each screenshot has `-light` and `-dark` variants.

**Native Screenshots (Android only):** Screenshot 01 uses ADB screencap via `@@NATIVE_SCREENSHOT:<name>@@` marker because Flutter's `convertFlutterSurfaceToImage()` misses webview content. iOS captures webviews normally.

---

### SCREENSHOT-004 - CI/CD Integration

Screenshots are generated in GitHub Actions workflow (`.github/workflows/build-and-test.yml`).

**Trigger conditions** (via `dorny/paths-filter@v3`):
- `integration_test/screenshot_test.dart`
- `lib/demo_data.dart`
- `test_driver/integration_test.dart`
- `android/fastlane/**`, `ios/fastlane/**`
- `.github/workflows/**`
- Manual `workflow_dispatch`

**Android CI setup:**
- Ubuntu runner with KVM acceleration
- Emulator: API 34, Pixel 5, `disk-size: 4096M`
- ImageMagick via AppImage from imagemagick.org (Ubuntu 24 apt v6.9 lacks `magick`)
- Ruby 2.7 + bundler for fastlane

**iOS CI setup:**
- macOS runner
- Dependencies via Homebrew: `dart-sdk`, `cocoapods`, `imagemagick-full`, `fastlane` (all with `brew link --force`)
- Simulator: iPhone 15 Pro (fallback chain)
- FVM for Flutter version management

---

### SCREENSHOT-005 - Device Frame Integration

Frameit adds device bezels and marketing titles.

**Commands:**
```bash
cd android && bundle exec fastlane add_device_frames
cd ios && fastlane add_device_frames
```

**Resizing:** ImageMagick auto-resizes to supported resolutions:
- Android: Pixel 5 (1080x2340 portrait, 2340x1080 landscape)
- iOS: iPhone 13 Pro (1170x2532), iPad Pro 12.9" (2732x2048 landscape)

---

### SCREENSHOT-006 - Theme Support

Screenshots are captured in both light and dark themes via a loop in `screenshot_test.dart`:
1. Seed demo data with target theme
2. Launch app
3. Execute screenshot tour
4. Name files with `-light`/`-dark` suffix

---

## Files

**Test files:**
- `integration_test/screenshot_test.dart` - Main test
- `test_driver/integration_test.dart` - Driver with native screenshot support
- `lib/demo_data.dart` - Demo data seeding

**Fastlane config:**
- `android/fastlane/Fastfile`, `ios/fastlane/Fastfile` - Screenshot lanes
- `fastlane/metadata/android/en-US/images/phoneScreenshots/` - Android output + frameit config
- `fastlane/screenshots/en-US/` - iOS output + frameit config

**CI:**
- `.github/workflows/build-and-test.yml` - Build + conditional screenshots
