# Android Screenshot Test Setup

This document explains how to generate screenshots for the Android app.

## Two-Step Process

### Step 1: Seed Test Data with Flutter

First, use Flutter to create and persist the test data:

```bash
# Get your device ID
flutter devices

# Run the seeder script on your device
flutter run -d <device-id> test_data_seeder.dart
```

For example:
```bash
flutter run -d R58T11JQ0SX test_data_seeder.dart
```

This script will:
- Clear existing app data
- Create 6 sample sites (My Blog, Tasks, Notes, Home Dashboard, Personal Wiki, Media Server)
- Create 3 webspaces (All, Work, Home Server)
- Save everything to SharedPreferences using Flutter's native format
- Verify the data was saved correctly

The app will briefly run and you'll see logs confirming the data was saved.

### Step 2: Run Screenshot Tests

Once the data is seeded, run the Fastlane screenshot tests:

```bash
cd android
bundle exec fastlane screenshots
```

Or from project root:
```bash
bundle exec fastlane android screenshots
```

The test will:
- Launch the app (which loads the seeded data)
- Navigate through different screens
- Capture 8 screenshots showing:
  1. Webspaces list
  2. All sites view
  3. Sites drawer
  4. Site webview
  5. Drawer with current site
  6. Webspaces overview
  7. Work webspace
  8. Work webspace drawer

## Why This Approach?

Flutter's `shared_preferences` plugin uses a specific encoding format on Android that's difficult to replicate from Java. By using Flutter itself to create the data, we ensure:

- ✅ Correct encoding format
- ✅ All fields properly populated
- ✅ Data persists correctly
- ✅ No encoding bugs

## Troubleshooting

### Data not loading?

Re-run the seeder:
```bash
flutter run -d <device-id> test_data_seeder.dart
```

Check the logs to confirm data was saved.

### Screenshots show empty app?

Make sure you ran Step 1 (seeder) before Step 2 (screenshot test).

### Need to change test data?

Edit `test_data_seeder.dart` and re-run Step 1.

## Files

- `test_data_seeder.dart` - Flutter script that seeds test data
- `android/app/src/androidTest/java/.../ScreenshotTest.java` - Screenshot test that uses the seeded data
- `android/app/src/androidTest/java/.../TestDataHelper.java` - Helper for clearing data (legacy, kept for reference)
