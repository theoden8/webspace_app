<div align="center">

[![Release](https://img.shields.io/github/v/release/theoden8/webspace_app)](https://github.com/theoden8/webspace_app/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/theoden8/webspace_app/total)](https://github.com/theoden8/webspace_app/releases)
<a href="https://github.com/sponsors/theoden8">
  <img src="https://img.shields.io/badge/Sponsor-theoden8-ff69b4" alt="Sponsor theoden8">
</a>

<img src="assets/webspace_icon.png" alt="WebSpace Icon" width="120"/>

# WebSpace

[![Build and Test](https://github.com/theoden8/webspace_app/actions/workflows/build-and-test.yml/badge.svg)](https://github.com/theoden8/webspace_app/actions/workflows/build-and-test.yml)

**Your favorite web apps, now on your phone.**

</div>

## Overview

WebSpace is a mobile app that brings all your favorite websites and web apps together in one organized, streamlined interface.

**Features:**

- 🌐 Create multiple webspaces for your favorite sites
- 🔒 Cookie isolation per site
- 🔍 Find-in-page functionality
- 🔄 Proxy support

## Quick Start

### Prerequisites
```bash
flutter --version  # >= 3.0.0
```

### Installation
```bash
git clone <repository>
cd webspace_app
flutter pub get
```

### Run
```bash
# iOS
flutter run -d ios

# Android
flutter run -d android

# macOS
flutter run -d macos
```

## Usage

1. **Add Site**: Click the "+" button, enter URL (e.g., `example.com:8080`)
2. **Switch Sites**: Open drawer (☰), tap a site
3. **Edit Site**: Click title in app bar or edit icon in drawer
4. **Refresh Title**: Click refresh icon in drawer to re-fetch page title

## Documentation

Detailed documentation is in [`transcript/`](transcript/README.md):
- Feature guides
- Implementation notes
- Known issues
- Development guides

## Platform Support

| Platform | Status | Purpose |
|----------|--------|---------|
| iOS | ✅ Supported | Target |
| Android | ✅ Supported | Target |
| macOS | ✅ Supported | Development |
| Linux | ⏳ Pending flutter_inappwebview support | Development |

## Tech Stack

- **Framework**: Flutter
- **State Management**: setState + SharedPreferences

This project is made possible by [flutter_inappwebview](https://github.com/pichillilorenzo/flutter_inappwebview), which provides the advanced webview functionality at the core of WebSpace.

## Development

### Tests
```bash
flutter test
```

### Build
```bash
# Release build
flutter build ios --release
flutter build apk --release
flutter build macos --release
```

### Code Analysis
```bash
flutter analyze
```

This project was initially created with GPT-4 assistance. See [`transcript/0-gpt4-coding.md`](transcript/0-gpt4-coding.md) for the initial development process.

## License

This project is licensed under the [MIT License](LICENSE) - Copyright (c) 2023 Kirill Rodriguez.

**Assets**: Icons and images in the `assets/` directory are licensed under [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/) - Copyright (c) Polina Levchenko. See [assets/LICENSE](assets/LICENSE) for details.
