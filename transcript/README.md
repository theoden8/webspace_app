# WebSpace App - Documentation

## Overview

WebSpace is a Flutter app for managing multiple webviews in a single application. It provides a convenient way to organize and access multiple web-based applications.

---

## Documentation Structure

### 📋 Project Information
- **[summary.md](summary.md)** - Project exploration, architecture, and findings
- **[0-gpt4-coding.md](0-gpt4-coding.md)** - Original GPT-4 development transcript

### 🚀 Implementation Guides
- **[IMPLEMENTATION_NOTES.md](IMPLEMENTATION_NOTES.md)** - Technical implementation details
- **[README_IMPLEMENTATION.md](README_IMPLEMENTATION.md)** - Quick start guide
- **[LINUX_STATUS.md](LINUX_STATUS.md)** - Linux support roadmap

### ✨ Features Documentation
- **[EDIT_FEATURE.md](EDIT_FEATURE.md)** - Site editing and page title display
- **[THEME_FEATURE.md](THEME_FEATURE.md)** - Dark/light mode for webviews
- **[RESIZE_FIX.md](RESIZE_FIX.md)** - Desktop window resizing

### 🐛 Maintenance
- **[CLEANUP_SUMMARY.md](CLEANUP_SUMMARY.md)** - Codebase cleanup status
- **[KNOWN_ISSUES.md](KNOWN_ISSUES.md)** - Known bugs and workarounds

---

## Quick Reference

### Platform Support
- ✅ **iOS**: WKWebView (Development)
- ✅ **Android**: flutter_inappwebview (Development)
- ✅ **macOS**: WKWebView (Development)
- 🚧 **Linux**: Planned (Development)

### Key Features
- Multi-site webview management
- Automatic page title extraction
- Smart favicon detection (HTML parsing)
- Theme preference injection
- URL editing with protocol inference
- Cookie management per site
- Find-in-page functionality
- Domain isolation (external links)

### Tech Stack
```
Flutter SDK: >=3.0.0-417.1.beta <4.0.0
Platform: iOS, Android, macOS (Linux planned)
Architecture: Platform abstraction layer
State: setState + SharedPreferences
```

---

## Project Structure

```
lib/
├── main.dart                    # App entry, UI, persistence
├── platform/
│   ├── platform_info.dart      # Platform detection
│   ├── unified_webview.dart    # Cookie & controller abstractions
│   └── webview_factory.dart    # Platform-specific webview creation
├── screens/
│   ├── add_site.dart           # Add URL screen
│   ├── inappbrowser.dart       # External link viewer
│   └── settings.dart           # Per-site settings
├── settings/
│   └── proxy.dart              # Proxy configuration model
├── web_view_model.dart         # Core site data model
└── widgets/
    └── find_toolbar.dart       # In-page search UI

test/
├── fixtures/                   # HTML test files
├── integration_test.dart       # Integration tests
├── platform_test.dart          # Platform abstraction tests
├── title_extraction_test.dart  # Title parsing tests
└── web_view_model_test.dart   # Model tests
```

---

## Development Workflow

### Building
```bash
# Debug build
flutter run -d ios
flutter run -d android
flutter run -d macos

# Release build
flutter build ios --release
flutter build apk --release
flutter build macos --release
```

### Testing
```bash
# Run all tests
flutter test

# Specific test file
flutter test test/integration_test.dart

# With coverage
flutter test --coverage
```

### Code Quality
```bash
# Analyze code
flutter analyze

# Check for linter issues
flutter analyze lib/

# Format code
flutter format lib/
```

---

## Contributing

When adding new features, update:
1. Relevant feature documentation in `transcript/`
2. Tests in `test/`
3. Platform abstraction if needed
4. This README with any new docs

---

## License

This project was initially created using GPT-4 assistance. See [0-gpt4-coding.md](0-gpt4-coding.md) for the development transcript.
