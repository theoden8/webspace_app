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

### Requirement: PLATFORM-007 - Launch screen follows the system appearance

The native launch screen on iOS and Android SHALL take its background from the
system appearance, light in light mode and dark in dark mode, and SHALL NOT
name a fixed colour. On iOS that is `LaunchScreen.storyboard`, whose view
background is `systemBackgroundColor`. On Android it is the `LaunchTheme`
window background, which has a `values-night` variant and draws
`?android:colorBackground`; Android 12+ samples the same background for its
system splash.

`main()` runs the service inits (content blocker engine, DNS lists) before
`runApp`, and the launch screen stays up until Flutter's first frame, so a
fixed white one is a white screen for that whole time on every dark-mode cold
start.

The launch screen cannot follow the in-app theme override: the OS draws it
before any app code runs.

#### Scenario: Cold start in dark mode

**Given** the system appearance is dark
**When** the app is cold-started
**Then** the launch screen is dark until Flutter's first frame replaces it

---

### Requirement: PLATFORM-008 - Linux desktop files

The Linux build SHALL name its desktop entry, its metainfo and its icon after
`APPLICATION_ID` in `linux/CMakeLists.txt`, and the desktop entry's `Icon=`
and the metainfo's `<id>`, `<launchable>` and developer id SHALL come from it
too: a desktop matches a window to its entry, and a software centre an entry
to its listing, by that ID. The entry and the metainfo are templates CMake
fills in, so the ID has one owner.

They belong to the Linux build, not to one package: the CMake install puts
them and the icon under the bundle's `share/`, at the paths a desktop reads
under a data directory, and every package, the flatpak among them, copies that
directory into its own.

#### Scenario: Package the native bundle

**Given** a bundle built by `flutter build linux`
**When** its `share/` is copied into a data directory
**Then** `applications/`, `metainfo/` and `icons/hicolor/512x512/apps/` hold
the desktop entry, the metainfo and the icon, each named by the application ID
**And** the entry's icon and the metainfo's ID name that same ID

---

### Requirement: PLATFORM-009 - The flatpak's application ID

The flatpak SHALL run as `page.codeberg.theoden8.webspace_app`, the ID
Flathub's naming rules give a project hosted at
`codeberg.org/theoden8/webspace_app`, because `org.codeberg.*` is reserved for
Codeberg's own projects. Its manifest passes its own ID to `flutter build linux`
as `WEBSPACE_APPLICATION_ID`, so the GTK application, the window's Wayland app
ID and the desktop files (PLATFORM-008) all take it.

Every other Linux build SHALL keep `org.codeberg.theoden8.webspace`, the ID
earlier releases ran under. path_provider keeps the sites and settings under
that ID, and flutter_secure_storage_linux names its keyring entry after it, so
an install keeps both across an upgrade.

#### Scenario: Build the flatpak

**Given** the flatpak manifest with `id: page.codeberg.theoden8.webspace_app`
**When** the flatpak is built
**Then** the app registers as `page.codeberg.theoden8.webspace_app`
**And** its desktop entry, metainfo and icon are named by that ID

#### Scenario: Build the native bundle

**Given** a build with no `WEBSPACE_APPLICATION_ID` set
**When** `flutter build linux` runs
**Then** the app and its desktop files take `org.codeberg.theoden8.webspace`

---

### Requirement: PLATFORM-010 - The app's files live in its own cache and data directories

Every store the app keeps on disk SHALL live in the platform directory its
kind names (`StoreKind`, declared where the store is made):

- **cache**, what the app downloads or derives and can fetch again: the filter
  lists and their engine cache, the DNS blocklist, LocalCDN, the ClearURLs
  rules, the site-search list, the timezone polygons, site icons. The
  platform's cache directory: `$XDG_CACHE_HOME/<app id>` on Linux, `cacheDir`
  on Android, `Library/Caches` on iOS and macOS, none of them backed up.
- **data**, what it cannot fetch again: imported HTML, saved back stacks, the
  protection report's detail. The application support directory:
  `$XDG_DATA_HOME/<app id>` on Linux, beside the preferences, `filesDir` on
  Android, `Library/Application Support` on iOS and macOS.

Never the documents directory. On Linux that is the user's Documents folder,
or `$HOME` where `user-dirs.dirs` names none, which is what a Flatpak sees,
and a Flatpak without home access keeps nothing written there: the downloads
were gone at every launch while their records in the preferences said
otherwise, so the content blocker ran with no rules. On iOS it is backed up to
iCloud, which re-downloadable data must not be.

An entry an earlier release kept in the documents directory SHALL move to its
new place the first time it is asked for in a process: a rename on one file
system, and across two a copy staged beside its target and renamed into place.
An entry already in its new place is left as it is.

A cache the OS or the user clears loses downloads the app still has a record
of. A download's record SHALL follow its file: a filter list or the ClearURLs
rules whose file is gone read as not downloaded, and the app-wide DNS level
whose list is gone blocks nothing. A launch the user made SHALL then fetch
each of them again (an enabled filter list from its own URL, the app-wide DNS
level, the ClearURLs rules) through the app-wide proxy, as their download
buttons would, after the first frame; a background wake's process fetches
nothing. A site's own DNS level runs at the app-wide one until it is chosen
again.

#### Scenario: A Flatpak keeps its downloads

**Given** the Flatpak, with no filesystem permission
**When** a filter list is downloaded and the app is started again
**Then** the list's file is under `~/.var/app/<app id>/cache/<app id>/content_blocker_cache/`
**And** the engine is built from it at launch

#### Scenario: An upgrade moves what the documents directory held

**Given** an install whose imports and lists an earlier release wrote under the documents directory
**When** the app asks for a store the first time after the upgrade
**Then** the store's directory is moved into the directory its kind names, whole
**And** nothing of it is left in the documents directory

#### Scenario: A cleared cache is fetched again

**Given** an enabled filter list, the app-wide DNS level and the ClearURLs rules were downloaded
**And** the OS or the user cleared the cache since
**When** the user starts the app
**Then** each reads as not downloaded until its download lands
**And** each is fetched again once, through the app-wide proxy
**And** a disabled filter list is not fetched

Tests: `test/file_store_test.dart`, `test/purged_download_refetch_test.dart`.

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
