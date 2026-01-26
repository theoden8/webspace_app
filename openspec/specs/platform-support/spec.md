# Platform Support Specification

## Purpose

Platform abstraction layer and support status for WebSpace app across different operating systems.

## Status

- **Status**: Completed
- **Architecture**: Clean platform abstraction ready for future platforms

---

## Requirements

### Requirement: PLATFORM-001 - Primary Platform Support

The following platforms SHALL be fully supported:
- iOS
- Android
- macOS

#### Scenario: Run on supported platforms

**Given** the app is built for iOS, Android, or macOS
**When** the app is launched
**Then** all features work including webviews, cookies, proxy, and find-in-page

---

### Requirement: PLATFORM-002 - Platform Abstraction Layer

The system SHALL use a platform abstraction layer to hide platform differences.

#### Scenario: Create platform-agnostic webview

**Given** the app is running
**When** a webview is created
**Then** the platform abstraction layer provides the correct implementation
**And** application code doesn't know which webview is used

---

### Requirement: PLATFORM-003 - Linux Support Status

Linux desktop SHALL be pending flutter_inappwebview Linux support.

#### Scenario: Handle Linux platform

**Given** the app is running on Linux
**When** webview functionality is requested
**Then** the app shows appropriate messaging about limited support
**And** UI, settings, and persistence continue to work

---

### Requirement: PLATFORM-004 - Official Packages Only

The system SHALL only use official, stable packages:
- `flutter_inappwebview` for Android, iOS, macOS
- No unmaintained third-party packages

#### Scenario: Package security

**Given** the app dependencies
**Then** all webview packages are from official Flutter team or well-maintained sources
**And** no security/maintenance risks from abandoned packages

---

### Requirement: PLATFORM-005 - Future Linux Convergence

When Flutter's webview_flutter adds Linux support, migration SHALL require:
1. Update webview_flutter version
2. Test on Linux
3. Ship (no code changes needed)

#### Scenario: Future Linux migration

**Given** webview_flutter adds Linux support
**When** the version is updated in pubspec.yaml
**Then** the platform abstraction automatically uses the Linux implementation

---

## Platform Capabilities Matrix

| Feature | iOS | Android | macOS | Linux |
|---------|-----|---------|-------|-------|
| Webview | flutter_inappwebview | flutter_inappwebview | flutter_inappwebview | Pending |
| Cookies | Full | Full | Full | Limited |
| Proxy | Full | Full | Limited | System only |
| Find-in-page | Yes | Yes | Yes | No |
| Theme injection | Yes | Yes | Yes | No |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Application Layer                     │
│  (main.dart, screens/, widgets/)                            │
└──────────────────┬──────────────────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────────────────┐
│                   Platform Abstraction Layer                 │
│  • UnifiedWebViewController (interface)                      │
│  • UnifiedCookieManager                                      │
│  • UnifiedFindMatchesResult                                  │
│  • WebViewFactory                                            │
└──────────────────┬──────────────────────────────────────────┘
                   │
        ┌──────────┴──────────┐
        ▼                     ▼
┌──────────────────┐  ┌──────────────────┐
│  iOS / Android   │  │     Linux        │
│    macOS         │  │   (Pending)      │
│ (InAppWebView)   │  │                  │
└──────────────────┘  └──────────────────┘
```

---

## Bug Fixes in Platform Layer

1. `currentIndex` sentinel (was 10000, now properly null)
2. Cookie timing bug (now uses correct URL from onLoadStop)
3. FindToolbar constructor syntax (removed invalid parentheses)
4. Null-safety improvements throughout

---

## Known Issues (Linux with webview_cef)

If webview_cef is used on Linux:

### CEF Cache Path Warning
```
[WARNING:resource_util.cc(83)] Please customize CefSettings.root_cache_path
```
**Impact**: Cosmetic only, doesn't affect functionality

### Platform Thread Warning
```
[ERROR:flutter/shell/common/shell.cc(1178)] The 'webview_cef' channel sent a message from native to Flutter on a non-platform thread
```
**Impact**: Bug in webview_cef plugin, not our code. App works correctly.

---

## Files

### Platform Abstraction
- `lib/platform/platform_info.dart` - Platform detection utilities
- `lib/platform/unified_webview.dart` - Unified cookie and find-matches abstractions
- `lib/platform/webview_factory.dart` - Factory for platform-specific webviews

### Tests
- `test/platform_test.dart` - Tests for unified cookie serialization
- `test/web_view_model_test.dart` - Tests for WebViewModel logic
