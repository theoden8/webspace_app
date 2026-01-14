# Linux Desktop Support Status

## Current State (January 2026)

### ✅ What Works
- **iOS**: Fully functional using `flutter_inappwebview`
- **Android**: Fully functional using `flutter_inappwebview`
- **macOS**: Fully functional using `flutter_inappwebview`
- **Architecture**: Clean platform abstraction layer ready for Linux support
- **Tests**: Comprehensive unit tests for platform-independent logic

### ⏳ What's Pending
- **Linux Desktop**: Waiting for flutter_inappwebview to add Linux support

## Technical Details

### Package Strategy
We're using `flutter_inappwebview` as our webview solution:

1. **`flutter_inappwebview`**
   - Currently supports: Android, iOS, macOS, Web
   - Stable, feature-rich, actively maintained
   - Powers all platforms in this app
   - **Linux support**: Not yet available (as of Jan 2026)

### Why Not Third-Party Linux Packages?

We evaluated but rejected:
- `flutter_linux_webview`: Unmaintained, stability issues
- `webview_cef`: Unstable APIs, breaking changes expected
- `webview_flutter`: Less feature-rich than flutter_inappwebview
- Random GitHub packages: Security/maintenance concerns

**Decision**: Wait for flutter_inappwebview to add Linux support rather than introduce unmaintained or less capable dependencies.

### Architecture: Ready for Linux Support

The codebase uses a **platform abstraction layer** (`lib/platform/`) that:
- ✅ Abstracts webview differences between platforms
- ✅ Provides unified cookie management
- ✅ Has comprehensive test coverage
- ✅ Will seamlessly adopt Linux support when available

**When flutter_inappwebview adds Linux support**, we only need to:
1. Update `flutter_inappwebview` version
2. Test on Linux
3. Ship - no architecture changes needed

## Current Linux Behavior

On Linux desktop:
- The app may not launch or webviews may not function
- Waiting for flutter_inappwebview to add Linux platform support
- UI, settings, and persistence logic is platform-agnostic and ready

## Timeline

- **Now**: iOS, Android, and macOS fully functional
- **Future**: Automatic Linux support when flutter_inappwebview adds it
- **Migration effort**: Minimal (just version bump + testing)

## For Contributors

If you want to help:
1. Monitor flutter_inappwebview for Linux support announcements
2. Test the platform abstraction layer
3. Contribute to flutter_inappwebview's Linux implementation

## References

- flutter_inappwebview: https://pub.dev/packages/flutter_inappwebview
- GitHub: https://github.com/pichillilorenzo/flutter_inappwebview
- Platform abstraction: `lib/platform/`
- Tests: `test/platform_test.dart`, `test/web_view_model_test.dart`
