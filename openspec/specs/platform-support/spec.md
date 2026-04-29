# Platform Support Specification

## Purpose

Platform abstraction layer and support status for WebSpace app across different operating systems.

## Status

- **Status**: Completed
- **Architecture**: Clean platform abstraction ready for future platforms

---

## Requirements

### Requirement: PLATFORM-001 - Primary Platform Support

The following platforms SHALL be fully supported in production builds:
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

### Requirement: PLATFORM-003 - Linux Support Status (Development Only)

Linux desktop SHALL be supported as a **development-only** target, wired
via a vendored fork of `flutter_inappwebview_linux 0.1.0-beta.1` that
exposes the WPE WebKit `WebKitNetworkSession` API for per-site profiles
and per-site proxy. The minimum runtime is WPE WebKit ≥ 2.50 (so the
plugin's `webkit_web_view_get_theme_color` etc. resolve); the binary
build path is locked to `debian:sid-slim` because Ubuntu's archives
ship neither WPE WebKit 2.50+ nor any libwpewebkit at all on Noble.

The Linux build is **not** advertised as a release artifact in the
F-Droid metadata or in the app stores. It exists for development /
testing on Linux desktops and as the vehicle for upstreaming the
per-site session work back to flutter_inappwebview_linux.

#### Scenario: Handle Linux platform

**Given** the app is running on Linux with WPE WebKit ≥ 2.50 installed
**When** the app is launched
**Then** webviews render via WPE WebKit
**And** per-site profiles work (each `WebViewModel.siteId` binds to its
  own persistent `WebKitNetworkSession` under
  `$XDG_DATA_HOME/webspace/profiles/ws-<siteId>/`)
**And** per-site proxy works (the same session has its proxy applied
  via `webkit_network_session_set_proxy_settings()`)
**And** the global outbound proxy works (the Dart-side `outbound_http`
  layer is platform-agnostic)

#### Scenario: Linux build is not yet release-ready

**Given** a downstream packager or end user
**When** they look at the platform support matrix
**Then** Linux is marked "Development only" and excluded from release
  artifact promises
**And** known gaps (per-site cookie inspector dev-tool routing through
  the default jar, screenshot pipeline) are documented as not-yet-wired

---

### Requirement: PLATFORM-004 - Official Packages Only

The system SHALL only use official, stable packages:
- `flutter_inappwebview` for Android, iOS, macOS
- `flutter_inappwebview_linux` 0.1.0-beta.1 for Linux (the first
  upstream release shipping the Linux platform plugin), patched in
  `third_party/flutter_inappwebview_linux.patch` to add per-site
  `WebKitNetworkSession` profiles + per-site proxy support
- No unmaintained third-party packages

#### Scenario: Package security

**Given** the app dependencies
**Then** all webview packages are from official Flutter team or well-maintained sources
**And** no security/maintenance risks from abandoned packages

---

### Requirement: PLATFORM-005 - Linux Plugin Patch Convergence

The Linux plugin patch SHALL be reduced to zero as upstream
`flutter_inappwebview_linux` merges the equivalent native support.
Two halves track separately:

1. `webspaceProfile` settings field + `WebKitNetworkSession` binding —
   filed for upstream review.
2. `webspaceProxy` settings field + per-session proxy application —
   blocked on (1).

When upstream merges (1), drop the profile half of the patch and
remove the `flutter_inappwebview_linux` entry from
`scripts/apply_plugin_patches.dart`. When upstream also merges (2),
drop the patch file entirely and the `dependency_override` from
`pubspec.yaml`.

#### Scenario: Future upstream merge

**Given** upstream `flutter_inappwebview_linux` ships native
  `webspaceProfile` + `webspaceProxy` settings
**When** the version is updated in `scripts/apply_plugin_patches.dart`
**Then** the patch hunks no longer apply (rejected by `patch -p1`)
**And** removing `third_party/flutter_inappwebview_linux.patch` and
  the `dependency_override` lets the upstream package satisfy the
  build as-is

---

## Platform Capabilities Matrix

| Feature | iOS | Android | macOS | Linux (dev) |
|---------|-----|---------|-------|-------------|
| Webview | flutter_inappwebview | flutter_inappwebview | flutter_inappwebview | flutter_inappwebview_linux 0.1.0-beta.1 (patched) |
| Cookies | Full | Full | Full | Full (per-site session) |
| Per-site profiles | WKWebsiteDataStore(forIdentifier:) | androidx.webkit.Profile | WKWebsiteDataStore(forIdentifier:) | webkit_network_session_new(dataDir, cacheDir), cached process-wide |
| Per-site proxy | WKWebsiteDataStore.proxyConfigurations | inapp.ProxyController (global) | WKWebsiteDataStore.proxyConfigurations | webkit_network_session_set_proxy_settings |
| Global outbound proxy | Dart outbound_http | Dart outbound_http | Dart outbound_http | Dart outbound_http |
| Find-in-page | Yes | Yes | Yes | Yes (via plugin) |
| Theme injection | Yes | Yes | Yes | Yes (via plugin) |
| Cookie inspector dev-tool | Per-profile via patched MyCookieManager | Per-profile via patched MyCookieManager | Per-profile via patched MyCookieManager | Default jar only (TODO) |
| Screenshot pipeline | Fastlane | Fastlane | — | Not wired (TODO) |

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
        ┌──────────┼──────────────────────┐
        ▼          ▼                      ▼
┌──────────────────┐  ┌──────────────────────┐
│  iOS / Android   │  │  Linux (dev)         │
│    macOS         │  │  flutter_inappwebview│
│ (InAppWebView)   │  │  _linux 0.1.0-beta.1 │
│                  │  │  + WebSpace fork     │
│                  │  │  patch (third_party/ │
│                  │  │  PATCHES.md)         │
└──────────────────┘  └──────────────────────┘
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
