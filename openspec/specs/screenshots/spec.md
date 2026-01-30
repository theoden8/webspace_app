# Screenshot Generation Specification

## Purpose

Automated screenshot generation for app store submissions using Flutter integration tests and Fastlane.

## Status

- **Status**: Completed
- **Platforms**: Android (working), iOS (requires macOS)

---

## Requirements

### Requirement: SCREENSHOT-001 - Cross-Platform Generation

Screenshots SHALL be generated using Flutter integration tests that work on both Android and iOS.

#### Scenario: Generate Android screenshots

**Given** an Android emulator is running
**When** the user runs `fastlane screenshots` in the android directory
**Then** 10 screenshots are captured and saved (5 light theme, 5 dark theme)

---

### Requirement: SCREENSHOT-002 - Demo Data Seeding

Screenshots SHALL use realistic demo data seeded automatically.

#### Scenario: Seed demo data before screenshots

- **WHEN** the screenshot test starts
- **THEN** demo sites are seeded
- **AND** demo webspaces are created

Demo sites:
- DuckDuckGo (https://duckduckgo.com)
- Piped (https://piped.video)
- Nitter (https://nitter.net)
- Reddit (https://www.reddit.com)
- GitHub (https://github.com)
- Hacker News (https://news.ycombinator.com)
- Weights & Biases (https://wandb.ai)
- Wikipedia (https://www.wikipedia.org)

Demo webspaces:
- **All** - Shows all sites
- **Work** - GitHub, Hacker News, Weights & Biases
- **Privacy** - DuckDuckGo, Piped, Nitter
- **Social** - Nitter, Reddit, Wikipedia

---

### Requirement: SCREENSHOT-003 - Screenshot Coverage

The test SHALL capture 5 screenshots per theme (10 total) covering all major app features in both light and dark themes.

#### Scenario: Capture all required screenshots

- **WHEN** the screenshot test completes
- **THEN** 10 screenshots are saved covering webview, drawer, and workspace features in both themes
- **AND** frameit is used to add device frames and marketing titles

Screenshots (light theme):
1. `01-site-webview-light` - DuckDuckGo site loaded in webview
2. `02-drawer-with-site-light` - Drawer showing selected site (with webview behind)
3. `03-work-webspace-light` - Work webspace view
4. `04-work-sites-drawer-light` - Work webspace drawer
5. `05-workspace-sites-selected-light` - Dialog with sites selected

Screenshots (dark theme):
6. `01-site-webview-dark` - DuckDuckGo site loaded in webview
7. `02-drawer-with-site-dark` - Drawer showing selected site (with webview behind)
8. `03-work-webspace-dark` - Work webspace view
9. `04-work-sites-drawer-dark` - Work webspace drawer
10. `05-workspace-sites-selected-dark` - Dialog with sites selected

#### Screenshot Processing Workflow

1. **Generation**: Flutter integration test captures 5 screenshots per theme (10 total)
2. **Resizing**: ImageMagick resizes screenshots to appropriate resolution based on orientation:
   - Portrait: Pixel 5 (1080x2340) for Android, iPhone 13 Pro (1170x2532) for iOS
   - Landscape: Pixel 5 landscape (2340x1080) for Android, iPad Pro 12.9" (2732x2048) for iOS
3. **Framing**: Frameit adds device bezels and marketing titles from keyword.strings
4. **Output**: Final framed screenshots ready for app store submission

#### Native Screenshots for Webviews (Android)

On Android, screenshots 01 and 02 which include webview content use native ADB screencap instead of Flutter's screenshot mechanism. This is because Flutter's `convertFlutterSurfaceToImage()` only captures Flutter-rendered content and misses native platform views like webviews.

The test prints a marker `@@NATIVE_SCREENSHOT:<name>@@` which the test driver detects via logcat monitoring, then takes an ADB screenshot that captures the full screen including webviews.

On iOS, the standard Flutter screenshot mechanism captures webviews correctly, so native screenshots are not needed.

---

### Requirement: SCREENSHOT-004 - Output Locations

Screenshots SHALL be saved to platform-specific directories.

#### Scenario: Save screenshots to correct directories

- **WHEN** screenshots are generated on Android
- **THEN** files are saved to `fastlane/metadata/android/en-US/images/phoneScreenshots/`

#### Scenario: Save iOS screenshots to correct directories

- **WHEN** screenshots are generated on iOS
- **THEN** files are saved to `fastlane/screenshots/en-US/`

---

### Requirement: SCREENSHOT-005 - Fastlane Integration

Screenshots SHALL be triggerable via Fastlane commands.

#### Scenario: Run screenshots via Fastlane

- **WHEN** the user runs `fastlane screenshots` in the android or ios directory
- **THEN** screenshots are captured and saved to the appropriate location

```bash
# Android
cd android && fastlane screenshots

# iOS
cd ios && fastlane screenshots

# Both platforms
fastlane screenshots_all
```

---

### Requirement: SCREENSHOT-006 - Flutter Driver Alternative

Screenshots SHALL also be capturable via Flutter driver directly.

```bash
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/screenshot_test.dart \
  --flavor fmain
```

---

### Requirement: SCREENSHOT-007 - Theme Support

Screenshots SHALL be captured in both light and dark themes.

#### Scenario: Generate screenshots for both themes

- **WHEN** the screenshot test runs
- **THEN** the test runs twice (once per theme)
- **AND** light theme screenshots are captured with `-light` suffix
- **AND** dark theme screenshots are captured with `-dark` suffix

#### Implementation Details

The test uses a `for` loop to iterate over `['light', 'dark']` themes:
1. Demo data is seeded fresh for each theme run
2. App is launched with default (light) theme
3. Theme is toggled to target theme using the app's theme button
4. Full screenshot tour is executed
5. Screenshots are named with theme suffix (e.g., `01-all-sites-light`)

---

### Requirement: SCREENSHOT-008 - Device Frame Integration

Screenshots SHALL be frameable with device bezels and marketing titles using frameit.

#### Scenario: Add device frames to screenshots

- **WHEN** the user runs `fastlane add_device_frames` in the android or ios directory
- **THEN** screenshots are framed with device bezels
- **AND** marketing titles from keyword.strings are added
- **AND** styling from Framefile.json is applied

#### Scenario: Generate and frame in one step

- **WHEN** the user runs `fastlane screenshots_framed`
- **THEN** screenshots are generated via integration tests
- **AND** device frames and titles are added automatically

```bash
# Android - frame existing screenshots
cd android && fastlane add_device_frames

# iOS - frame existing screenshots
cd ios && fastlane add_device_frames

# Both platforms - frame existing
fastlane frame_all

# Generate and frame in one step
cd android && fastlane screenshots_framed
cd ios && fastlane screenshots_framed
fastlane screenshots_framed_all
```

#### Configuration Files

**keyword.strings** - Marketing titles for each screenshot:
```
"01-all-sites-light" = "Organize all your web apps in one place"
"02-sites-drawer-light" = "Quick access to your favorite sites"
...
```

**Framefile.json** - Visual styling configuration:
```json
{
  "default": {
    "keyword": {
      "fonts": [{"font": "Arial-BoldMT", "supported": ["*"]}],
      "color": "#545454"
    },
    "background": "#FFFFFF",
    "padding": 50
  },
  "data": [
    {
      "filter": "*-dark",
      "keyword": {"color": "#E0E0E0"},
      "background": "#1A1A1A"
    }
  ]
}
```

#### Implementation Details

- Light theme screenshots use white background and dark text (#545454)
- Dark theme screenshots use white background and light text (#E0E0E0)
- Theme detection uses filename pattern matching (`*-dark`)
- Same marketing titles used across both themes for consistency
- **Automatic resizing**: Screenshots are automatically resized to supported resolutions before framing (orientation-aware)
  - Android Portrait: Resized to Pixel 5 resolution (1080x2340)
  - Android Landscape: Resized to Pixel 5 landscape (2340x1080)
  - iOS Portrait: Resized to iPhone 13 Pro resolution (1170x2532)
  - iOS Landscape: Resized to iPad Pro 12.9" resolution (2732x2048) - required by frameit for landscape
- Resizing uses ImageMagick's `magick` command (must be installed)

#### Requirements

- **ImageMagick** must be installed for screenshot resizing:
  ```bash
  # macOS
  brew install imagemagick

  # Linux (Debian/Ubuntu)
  sudo apt-get install imagemagick
  ```

---

## Architecture

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

---

## Comparison: Old (Java) vs New (Flutter)

| Aspect | Old (Java) | New (Flutter) |
|--------|------------|---------------|
| Automation | External | Internal |
| Platforms | Android only | Cross-platform |
| Speed | Slower | Faster |
| Reliability | More flaky | More reliable |
| Debug | Harder | Standard Flutter tools |
| Theme support | Manual | Automated (light + dark) |
| Lines of code | ~428 | ~540 |

---

## Files

### Created
- `integration_test/screenshot_test.dart` - Main screenshot test
- `test_driver/integration_test.dart` - Test driver with screenshot saving
- `lib/demo_data.dart` - Demo data seeding logic
- `fastlane/metadata/android/en-US/images/phoneScreenshots/keyword.strings` - Android marketing titles
- `fastlane/metadata/android/en-US/images/phoneScreenshots/Framefile.json` - Android frameit config
- `fastlane/screenshots/en-US/keyword.strings` - iOS marketing titles
- `fastlane/screenshots/en-US/Framefile.json` - iOS frameit config

### Modified
- `android/fastlane/Fastfile` - Android screenshot and frameit lanes
- `ios/fastlane/Fastfile` - iOS screenshot and frameit lanes
- `fastlane/Fastfile` - Root-level screenshot coordination lanes
- `android/fastlane/Screengrabfile` - Android configuration
- `ios/fastlane/Snapfile` - iOS configuration
