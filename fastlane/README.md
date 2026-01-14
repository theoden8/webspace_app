# Fastlane Setup for Webspace

This directory contains Fastlane configuration for building and deploying the Webspace app to both Android and iOS platforms.

## Prerequisites

### General
- Install Fastlane: `gem install fastlane` or `brew install fastlane`
- Install Flutter SDK
- Ensure Flutter is in your PATH

### Android
- Android SDK installed
- `key.properties` file in `android/` directory for release signing
- Google Play Console service account JSON key (for deployment)

### iOS
- Xcode installed (macOS only)
- Apple Developer account
- Provisioning profiles and certificates set up

## Structure

```
fastlane/
├── Fastfile          # Root Fastfile with cross-platform lanes
├── Appfile           # Root app configuration
├── metadata/         # Play Store metadata
└── README.md         # This file

android/fastlane/
├── Fastfile          # Android-specific lanes
├── Appfile           # Android app configuration
└── .gitignore        # Android fastlane gitignore

ios/fastlane/
├── Fastfile          # iOS-specific lanes
├── Appfile           # iOS app configuration
└── .gitignore        # iOS fastlane gitignore
```

## Available Lanes

### Cross-Platform Lanes (run from project root)

```bash
# Build both Android and iOS apps
fastlane build_all

# Run Flutter tests
fastlane test_all

# Deploy both platforms
fastlane deploy_all
```

### Android Lanes (run from project root or android/)

```bash
# Build lanes
fastlane android build_debug       # Build debug APK (fdebug flavor)
fastlane android build_fdroid      # Build F-Droid flavor APK
fastlane android build_release     # Build release APK (fmain flavor)
fastlane android build_bundle      # Build AAB for Play Store

# Deploy lanes
fastlane android deploy_internal   # Deploy to internal testing track
fastlane android deploy_beta       # Deploy to beta track
fastlane android deploy_production # Deploy to production

# Utility lanes
fastlane android test             # Run Android tests
fastlane android update_metadata  # Update Play Store metadata only
fastlane android bump_version     # Increment version code
fastlane android clean            # Clean build artifacts
```

### iOS Lanes (run from project root or ios/)

```bash
# Build lanes
fastlane ios build_debug       # Build debug IPA
fastlane ios build_release     # Build release IPA for App Store
fastlane ios build_adhoc       # Build ad-hoc IPA

# Deploy lanes
fastlane ios deploy_beta       # Deploy to TestFlight
fastlane ios deploy_production # Deploy to App Store

# Utility lanes
fastlane ios test              # Run iOS tests
fastlane ios sync_certificates # Update code signing
fastlane ios update_metadata   # Update App Store metadata only
fastlane ios bump_build        # Increment build number
fastlane ios bump_version      # Increment version number
fastlane ios screenshots       # Take App Store screenshots
fastlane ios clean             # Clean build artifacts
```

## Setup Instructions

### Android Setup

1. **Configure signing** (if not already done):
   - Create `android/key.properties` with your keystore details:
     ```
     storePassword=your_store_password
     keyPassword=your_key_password
     keyAlias=your_key_alias
     storeFile=path/to/your/keystore.jks
     ```

2. **Configure Play Store deployment**:
   - Create a service account in Google Play Console
   - Download the JSON key file
   - Update `android/fastlane/Appfile` with the path to your JSON key:
     ```ruby
     json_key_file("path/to/your-service-account.json")
     ```

### iOS Setup

1. **Configure Apple ID**:
   - Update `ios/fastlane/Appfile` with your Apple Developer email:
     ```ruby
     apple_id("your-apple-id@example.com")
     ```

2. **Configure code signing**:
   - Set up certificates and provisioning profiles in Xcode
   - Or use `fastlane match` for team-based certificate management

3. **TestFlight/App Store deployment**:
   - Ensure you have appropriate permissions in App Store Connect
   - You may need to provide your Apple ID password or use App Store Connect API key

## Usage Examples

### Building a release for Android

```bash
# From project root
fastlane android build_release

# Or from android directory
cd android
fastlane build_release
```

### Deploying to TestFlight

```bash
# From project root
fastlane ios deploy_beta

# Or from ios directory
cd ios
fastlane deploy_beta
```

### Building both platforms

```bash
# From project root
fastlane build_all
```

## Customization

You can customize the Fastfiles to add your own lanes or modify existing ones:

- **Root Fastfile** (`fastlane/Fastfile`): Cross-platform lanes
- **Android Fastfile** (`android/fastlane/Fastfile`): Android-specific lanes
- **iOS Fastfile** (`ios/fastlane/Fastfile`): iOS-specific lanes

## Troubleshooting

### Android
- **Signing errors**: Ensure `key.properties` is configured correctly
- **Build failures**: Check that Android SDK is properly installed
- **Flavor issues**: The app uses product flavors (fdroid, fdebug, fmain)

### iOS
- **Signing errors**: Run `fastlane ios sync_certificates` or check Xcode signing settings
- **Build failures**: Ensure Xcode command line tools are installed: `xcode-select --install`
- **Workspace not found**: Ensure you're running from the ios/ directory or project root

## Resources

- [Fastlane Documentation](https://docs.fastlane.tools/)
- [Fastlane for Android](https://docs.fastlane.tools/getting-started/android/setup/)
- [Fastlane for iOS](https://docs.fastlane.tools/getting-started/ios/setup/)
- [Flutter Deployment Guide](https://docs.flutter.dev/deployment)
