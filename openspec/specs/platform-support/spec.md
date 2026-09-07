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

Linux desktop SHALL run on the WebSpace fork of `flutter_inappwebview_linux`
(WPE WebKit, ≥ 2.40), pinned via `dependency_overrides` in
[`pubspec.yaml`](../../../pubspec.yaml). Webview, per-site containers,
cookies, and proxy all work — the fork's Linux side resolves cookie ops
to the per-WebView `WebKitNetworkSession` via
`webkit_web_view_get_network_session(webview)` and fans the proxy
override out across the default session and every cached container
session.

#### Scenario: Handle Linux platform

**Given** the app is running on Linux with the fork resolved
**When** the user opens a site
**Then** the webview loads inside its per-site
`WebKitNetworkSession` container
**And** cookies, localStorage, IndexedDB, ServiceWorkers and the HTTP
cache are isolated per site
**And** any configured proxy is applied to every loaded container's
session via `webkit_network_session_set_proxy_settings`
**And** UI, settings, and persistence work as on the other supported
platforms

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

### Requirement: PLATFORM-006 - macOS ships as a signed build

macOS SHALL be distributed, not only developed on: a notarized Developer ID
build attached to a GitHub release, and a sandboxed Mac App Store build under
the same bundle identifier as the iOS app.

A distributed macOS build SHALL keep the App Sandbox enabled, SHALL declare
`LSApplicationCategoryType` and the EXPORT-001 encryption declaration in
`macos/Runner/Info.plist`, and SHALL be signed with the team identity. The
committed entitlements name `$(AppIdentifierPrefix)`-prefixed app-group and
keychain-access-group entries, which an ad-hoc signature cannot back:
taskgated SIGKILLs such a bundle at launch as "Code Signature Invalid", so an
unsigned build is a developer artifact and never a release.

Each capability entitlement SHALL agree with its `ENABLE_*` build setting in
the configuration that uses it. Xcode merges the generated entitlements with
the file, so a capability present in one and absent from the other half-ships.

A signature applied after the build SHALL be taken from the bundle's own
entitlements rather than from the committed file, which carries neither what
the build settings generate nor what the provisioning profile adds, and SHALL
drop `com.apple.security.get-task-allow` — Xcode grants it whenever it signs
for development, and a distributed build carrying it is rejected.

#### Scenario: Build without a signing identity

**Given** a machine or CI runner with no certificate for the team
**When** the release bundle is built
**Then** it is re-signed with the team-scoped groups removed so it launches
**And** it is published as a developer build, with the keychain-backed
features (cookie storage, proxy credentials, the share extension's app
group) documented as non-functional

#### Scenario: Distributed build

**Given** a Developer ID or Apple Distribution identity
**When** `scripts/sign_macos.sh` signs the bundle
**Then** the entitlements carry the real team prefix
**And** the Developer ID build is notarized and stapled, or the App Store
build carries the app's and the extension's provisioning profiles

---

## Platform Capabilities Matrix

| Feature | iOS | Android | macOS | Linux |
|---------|-----|---------|-------|-------|
| Webview | flutter_inappwebview | flutter_inappwebview | flutter_inappwebview | flutter_inappwebview (WPE WebKit, fork) |
| Cookies | Full (per-site container) | Full (per-site container, SDK ≥110) | Full (per-site container) | Full (per-site container, WPE ≥ 2.40) |
| Proxy | Full (per-site) | Full (global override) | Full (per-site) | Full (fan-out across default + every container session) |
| Find-in-page | Yes | Yes | Yes | Yes |
| Theme injection | Yes | Yes | Yes | Yes |

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
