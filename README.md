<div align="center">

<img src="assets/featureGraphic.png" alt="WebSpace Feature Graphic" width="100%"/>

---

[![Release](https://img.shields.io/github/v/release/theoden8/webspace_app)](https://github.com/theoden8/webspace_app/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/theoden8/webspace_app/total)](https://github.com/theoden8/webspace_app/releases)
[![Build and Test](https://github.com/theoden8/webspace_app/actions/workflows/build-and-test.yml/badge.svg)](https://github.com/theoden8/webspace_app/actions/workflows/build-and-test.yml)
<a href="https://github.com/sponsors/theoden8">
  <img src="https://img.shields.io/badge/Sponsor-theoden8-ff69b4" alt="Sponsor theoden8">
</a>

<a href="https://gitlab.com/fdroid/fdroiddata/-/merge_requests/31896">
  <img src="https://f-droid.org/badge/get-it-on.png" alt="Get it on F-Droid" height="80" align="middle">
</a>
<a href="https://apps.apple.com/app/webspace-app/id6758049523">
  <img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download on the App Store" width="170" align="middle">
</a>

</div>

## Overview

WebSpace is a mobile app that brings all your favorite websites and web apps together in one organized, streamlined interface.

## Screenshots

<p align="center">
  <img src="fastlane/metadata/android/en-US/images/phoneScreenshots/1.png" width="23%" alt="All Sites"/>
  <img src="fastlane/metadata/android/en-US/images/phoneScreenshots/2.png" width="23%" alt="Sites Drawer"/>
  <img src="fastlane/metadata/android/en-US/images/phoneScreenshots/3.png" width="23%" alt="Work Webspace"/>
  <img src="fastlane/metadata/android/en-US/images/phoneScreenshots/4.png" width="23%" alt="Workspace Sites"/>
</p>

**Features**

- 📱 Organize sites into multiple webspaces
- 🔒 Per-site cookie isolation with secure storage
- 🌍 Per-site language preferences (30+ languages)
- 💾 Import/export settings for backup
- 🔄 Proxy support with authentication (Android)
- 🧹 ClearURLs tracking parameter removal
- 🎨 Light/dark mode with accent colors

## Development

### Prerequisites
- [FVM](https://fvm.app/) (Flutter Version Manager)
- Xcode (for iOS/macOS)
- Android Studio (for Android)

### Setup
```bash
git clone https://github.com/theoden8/webspace_app
cd webspace_app

# Install Flutter version via FVM
fvm install

# Get dependencies
fvm flutter pub get
```

## Platform Support

| Platform | Status | Purpose |
|----------|--------|---------|
| iOS | ✅ Supported | Target |
| Android | ✅ Supported | Target |
| macOS | ✅ Supported | Development |
| Linux | ⏳ Pending flutter_inappwebview support | Development |

## Tech Stack

- **Framework**: Flutter

This project is made possible by [flutter_inappwebview](https://github.com/pichillilorenzo/flutter_inappwebview), which provides the advanced webview functionality at the core of WebSpace.

URL cleaning is powered by rules from [ClearURLs](https://github.com/ClearURLs/Rules) (LGPL-3.0).

## License

This project is licensed under the [MIT License](LICENSE) - Copyright (c) 2023 Kirill Rodriguez.

**Assets**: Icons and images in the `assets/` directory are licensed under [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/) - Copyright (c) Polina Levchenko. See [assets/LICENSE](assets/LICENSE) for details.
