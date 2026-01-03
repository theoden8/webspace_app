# WebSpace

Multi-site webview manager for Flutter.

## Overview

WebSpace allows you to run multiple webviews in a single app, making it convenient to manage multiple web-based applications.

**Features:**
- 🌐 Multiple webviews in tabs
- 🎨 Auto-detect page titles and favicons
- 🌙 Theme preference for webviews
- 🔒 Cookie isolation per site
- 🔍 Find-in-page functionality
- ✏️ Edit site names and URLs
- 🖥️ Linux desktop support

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
# Linux
flutter run -d linux

# Android
flutter run -d android
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

| Platform | Status | WebView Engine |
|----------|--------|----------------|
| Android | ✅ Stable | flutter_inappwebview |
| Linux | ✅ Working | webview_cef (CEF) |
| Windows | ⏳ Planned | webview_cef |
| macOS | ⏳ Planned | webview_cef |
| iOS | ❌ Not planned | - |

## Tech Stack

- **Framework**: Flutter
- **State Management**: setState + SharedPreferences
- **Android Webview**: flutter_inappwebview ^5.7.2+3
- **Linux Webview**: webview_cef ^0.2.0
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
flutter build linux --release
flutter build apk --release
```

### Code Analysis
```bash
flutter analyze
```

## License

Created with GPT-4 assistance. See [`transcript/0-gpt4-coding.md`](transcript/0-gpt4-coding.md).
