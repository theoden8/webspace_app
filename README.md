<div align="center">

<img src="assets/webspace_icon.png" alt="WebSpace Icon" width="120"/>

# WebSpace

[![Build and Test](https://github.com/theoden8/webspace_app/actions/workflows/build-and-test.yml/badge.svg)](https://github.com/theoden8/webspace_app/actions/workflows/build-and-test.yml)

Multi-site webview manager for Flutter.

</div>

## Overview

WebSpace allows you to run multiple webviews in a single app, making it convenient to manage multiple web-based applications.

**Features:**
- 🌐 Multiple webviews in tabs
- 🎨 Auto-detect page titles and favicons
- 🌙 Theme preference for webviews
- 🔒 Cookie isolation per site
- 🔍 Find-in-page functionality
- ✏️ Edit site names and URLs

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

| Platform | Status | WebView Engine | Purpose |
|----------|--------|----------------|---------|
| iOS | ✅ Supported | WKWebView | Development |
| Android | ✅ Supported | flutter_inappwebview | Development |
| macOS | ✅ Supported | WKWebView | Development |
| Linux | 🚧 Planned | webview_cef (CEF) | Development |

## Tech Stack

- **Framework**: Flutter
- **State Management**: setState + SharedPreferences
- **Webview**: flutter_inappwebview ^5.7.2+3
- **HTTP**: http ^1.2.0
- **HTML Parsing**: html ^0.15.4
- **Image Caching**: cached_network_image ^3.2.3

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

## License

Created with GPT-4 assistance. See [`transcript/0-gpt4-coding.md`](transcript/0-gpt4-coding.md).

**Note**: Assets (including icons and images) are distributed under a separate license.
