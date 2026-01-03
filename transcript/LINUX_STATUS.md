# Linux Desktop Support Status

## Current State (January 2026)

### ✅ What Works
- **Android**: Fully functional using `flutter_inappwebview`
- **Architecture**: Clean platform abstraction layer ready for Linux support
- **Tests**: Comprehensive unit tests for platform-independent logic

### ⏳ What's Pending
- **Linux Desktop**: Waiting for official Flutter team support

## Technical Details

### Package Strategy
We're using **official packages only** for maintainability and security:

1. **`flutter_inappwebview: ^5.7.2+3`** (Android/iOS/Web)
   - Stable, feature-rich, actively maintained
   - Powers the Android version

2. **`webview_flutter: ^4.0.0`** (Official Flutter team package)
   - Currently supports: Android, iOS, Web
   - **Linux support**: Not yet available (as of Jan 2026)
   - This is the official migration path when Linux support arrives

### Why Not Third-Party Linux Packages?

We evaluated but rejected:
- `flutter_linux_webview`: Unmaintained (17+ months), stability issues
- `webview_cef`: Unstable APIs, breaking changes expected
- Random GitHub packages: Security/maintenance concerns

**Decision**: Wait for official Flutter team Linux support rather than introduce unmaintained dependencies.

### Architecture: Ready for Convergence

The codebase uses a **platform abstraction layer** (`lib/platform/`) that:
- ✅ Abstracts webview differences between platforms
- ✅ Provides unified cookie management
- ✅ Has comprehensive test coverage
- ✅ Will seamlessly adopt official Linux support when available

**When Flutter adds Linux support to `webview_flutter`**, we only need to:
1. Update `webview_flutter` version
2. Test on Linux
3. Ship - no architecture changes needed

## Current Linux Behavior

On Linux desktop, the app will:
- Launch successfully
- Show a message: "WebView not yet supported on Linux desktop"
- All other functionality (UI, settings, persistence) works

## Timeline

- **Now**: Android fully functional
- **Future**: Automatic Linux support when Flutter team ships it
- **Migration effort**: Minimal (just version bump)

## For Contributors

If you want to help:
1. Monitor Flutter's webview_flutter package for Linux support announcements
2. Test the platform abstraction layer
3. Contribute to Flutter's official Linux webview implementation

## References

- Flutter webview_flutter: https://pub.dev/packages/webview_flutter
- Platform abstraction: `lib/platform/`
- Tests: `test/platform_test.dart`, `test/web_view_model_test.dart`
