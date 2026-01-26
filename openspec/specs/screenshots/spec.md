# Screenshot Generation Specification

## Overview

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
**Then** 10 screenshots are captured and saved

---

### Requirement: SCREENSHOT-002 - Demo Data Seeding

Screenshots SHALL use realistic demo data seeded automatically.

Demo sites:
- My Blog (https://example.com/blog)
- Tasks (https://tasks.example.com)
- Notes (https://notes.example.com)
- Home Dashboard (http://homeserver.local:8080)
- Personal Wiki (http://192.168.1.100:3000)
- Media Server (http://192.168.1.101:8096)

Demo webspaces:
- **All** - Shows all sites
- **Work** - Blog, Tasks, Notes
- **Home Server** - Dashboard, Wiki, Media Server

---

### Requirement: SCREENSHOT-003 - Screenshot Coverage

The test SHALL capture 10 screenshots covering all major app features:

1. `01-all-sites` - Main screen with all sites
2. `02-sites-drawer` - Navigation drawer with site list
3. `03-site-webview` - DuckDuckGo site loaded
4. `04-drawer-with-site` - Drawer showing selected site
5. `05-work-webspace` - Work webspace view
6. `06-work-sites-drawer` - Work webspace drawer
7. `07-add-workspace-dialog` - New workspace dialog
8. `08-workspace-name-entered` - Dialog with name filled
9. `09-workspace-sites-selected` - Dialog with sites selected
10. `10-new-workspace-created` - Main screen with new workspace

---

### Requirement: SCREENSHOT-004 - Output Locations

Screenshots SHALL be saved to platform-specific directories:
- **Android**: `fastlane/metadata/android/en-US/images/phoneScreenshots/`
- **iOS**: `fastlane/screenshots/en-US/`

---

### Requirement: SCREENSHOT-005 - Fastlane Integration

Screenshots SHALL be triggerable via Fastlane commands.

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
| Lines of code | ~428 | ~280 |

---

## Files

### Created
- `integration_test/screenshot_test.dart` - Main screenshot test
- `test_driver/integration_test.dart` - Test driver with screenshot saving
- `lib/demo_data.dart` - Demo data seeding logic

### Modified
- `android/fastlane/Fastfile` - Android screenshot lane
- `ios/fastlane/Fastfile` - iOS screenshot lane
- `android/fastlane/Screengrabfile` - Android configuration
- `ios/fastlane/Snapfile` - iOS configuration
