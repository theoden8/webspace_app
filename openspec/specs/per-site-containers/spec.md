# Per-Site Containers

## Status
**Implemented on Android (System WebView 110+), iOS / macOS (iOS 17+ /
macOS 14+) and Linux (WPE WebKit 2.40+ via the WebSpace fork's
`flutter_inappwebview_linux`). Older OS / WebView versions fall
through to [`CookieIsolationEngine`](../per-site-cookie-isolation/spec.md).**

## Platform Support Matrix

The three native primitives this engine binds to all landed within
seven months of each other in 2023, so the floor for the Profile
path is roughly "anything that can run the September-2023 OS cohort
or later". Older devices keep working via the legacy
[`CookieIsolationEngine`](../per-site-cookie-isolation/spec.md)
fallback — `_useContainers` resolves to `false` at startup and the
existing capture-nuke-restore code path runs unchanged.

### Profile mode (engine-level isolation)

| Platform | Minimum OS | Native primitive | Earliest devices | Released |
|----------|------------|------------------|------------------|----------|
| Android  | Lollipop (API 21) **AND** System WebView 110+ | [`androidx.webkit.Profile`](https://developer.android.com/reference/androidx/webkit/Profile) via [`WebViewCompat.setProfile`](https://developer.android.com/reference/androidx/webkit/WebViewCompat#setProfile) | Anything that can update System WebView via Play Store; in practice Android 7.0+ (Nougat) keeps WebView fresh on most devices | Feb 2023 (WebView 110) |
| iOS      | 17.0 | [`WKWebsiteDataStore(forIdentifier:)`](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/init(foridentifier:)) | iPhone XS / XR (2018) and newer; iPad Pro 11" 1st-gen / 12.9" 3rd-gen / iPad Air 3 / iPad mini 5 / iPad 7 and newer — anything with the A12 Bionic or newer | Sept 2023 |
| macOS    | 14.0 Sonoma | Same as iOS (`WKWebsiteDataStore(forIdentifier:)`) | iMac 2019+, iMac Pro 2017+, MacBook Air 2018+, MacBook Pro 2018+, Mac mini 2018+, Mac Pro 2019+, Mac Studio 2022+ | Sept 2023 |
| Linux    | WPE WebKit 2.40 | Per-container `WebKitNetworkSession` cached in `container_session_cache` (fork's `flutter_inappwebview_linux`); cookies routed via `webkit_web_view_get_network_session(webview)`; proxy fan-out across default + cached container sessions | Ubuntu 23.10+, Fedora 38+, Debian trixie | Mar 2023 (WPE 2.40) |

The runtime check that decides Profile vs. legacy engine is in
[`ContainerNative.isSupported`](../../../lib/services/container_native.dart):

- **Android.** Native side checks `WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)`.
  This catches the device + WebView combination correctly (e.g. an
  Android 6 device with an outdated System WebView returns false
  even though `androidx.webkit` is present in the build).
- **iOS / macOS.** Native side checks
  `if #available(iOS 17.0, macOS 14.0, *)`.
- **Linux.** Build-time check via
  `inapp.ContainerController.isClassSupported(platform: TargetPlatform.linux)`.
  The fork's CMakeLists already gates compilation on
  `webkit_network_session_new` (WPE 2.40+); below that the plugin
  doesn't link.

### Legacy fallback (CookieIsolationEngine)

Anything older than the rows above falls through to
capture-nuke-restore. Practical app-runs-at-all floor is whatever
`flutter_inappwebview` itself requires — Android API 21 / iOS 12 /
macOS 10.14 — so a 2014-era Android tablet or a 2014 MacBook Pro
still launches the app, but won't get engine-level isolation. The
mutex from [ISO-001](../per-site-cookie-isolation/spec.md#requirement-iso-001---mutual-exclusion)
applies on those devices: at most one webview per second-level
domain may be active.

## Purpose

Engine-level cookie + storage isolation between sites in WebSpace.
Replaces the cookie-only capture-nuke-restore engine on platforms with
native per-site data-store primitives:

- **Android**, System WebView 110+: `androidx.webkit.Profile`. Each
  site maps to a named profile `ws-<siteId>`.
- **iOS 17+ / macOS 14+**: `WKWebsiteDataStore(forIdentifier: UUID)`.
  The siteId string is hashed via SHA-256 to produce a deterministic
  UUID (`WebSpaceProfile.uuid(for:)` — added by the WebSpace fork's
  iOS / macOS plugins) and that UUID identifies the per-site data
  store.
- **Linux**, WPE WebKit 2.40+: per-container `WebKitNetworkSession`
  with on-disk roots under
  `<XDG_DATA_HOME>/flutter_inappwebview/containers/ws-<siteId>/data`
  and `<XDG_CACHE_HOME>/flutter_inappwebview/containers/ws-<siteId>/cache`.
  The fork's `cookie_manager.cc` resolves cookie ops to the
  per-WebView session via `webkit_web_view_get_network_session(webview)`
  when a `webViewController:` is supplied; global ops fan out across
  the default and every cached container session, and the same
  fan-out drives `ProxyManager.setProxyOverride`.

Each `WebViewModel.siteId` owns its own cookie jar, `localStorage`,
`IndexedDB`, `ServiceWorkerController`, and HTTP cache. **Profile mode
supersedes (not supplements) the legacy ISO-001 mutex** from
[per-site-cookie-isolation](../per-site-cookie-isolation/spec.md): when
`_useContainers == true` the conflict-find / unload code path is skipped
entirely, so sites that share a base domain (e.g. two `github.com`
accounts) can be loaded concurrently without unloading each other —
this applies to every webspace, including the special "All" webspace.

## Problem Statement

The legacy [`CookieIsolationEngine`](../../../lib/services/cookie_isolation.dart)
(see [openspec/specs/per-site-cookie-isolation/spec.md](../per-site-cookie-isolation/spec.md))
works around `flutter_inappwebview`'s singleton native cookie jar by
capturing each site's cookies to encrypted storage on switch, nuking
the jar, and restoring the incoming site's cookies. This is correct
for cookies but leaves three gaps:

1. **Race-prone.** The capture-nuke-restore window must complete
   before any background script reads a cookie. A site whose JS runs
   `document.cookie` between nuke and restore sees a logged-out state.
2. **Cookie-only.** `localStorage`, `IndexedDB`, ServiceWorker
   registrations, HTTP cache, and `GeolocationPermissions` are stored
   process-wide. Two sites that share a base domain (e.g.
   `github.com/personal` and `github.com/work`) share these stores
   even when their cookies are separated.
3. **Mutual-exclusion UX cost.** Per
   [openspec/specs/per-site-cookie-isolation/spec.md ISO-001](../per-site-cookie-isolation/spec.md),
   only one webview per second-level domain can be active at a time —
   activating a same-base-domain sibling unloads the current site.
   With per-site profiles the jars are partitioned at the engine
   level, so this restriction is unnecessary.

`androidx.webkit.Profile` (System WebView 110+) is the native
primitive for partitioning all of the above in one call.

## Solution

Each site gets a named profile. Lifecycle:

| Event | Action |
|---|---|
| App startup, after restoring sites | Cache `ContainerNative.isSupported()` once. Sweep profiles whose owning site no longer exists (`ContainerIsolationEngine.garbageCollectOrphans`). |
| Site activated | `ContainerIsolationEngine.ensureContainer(siteId)` (idempotent). |
| WebView created (`onWebViewCreated`) | `ContainerNative.bindContainerToWebView(siteId)` — native side walks the activity view tree and calls `WebViewCompat.setProfile` on every flutter_inappwebview WebView for that siteId. |
| Site deleted | `ContainerIsolationEngine.onSiteDeleted(siteId)` after `disposeWebView`. |
| Profile API not supported (iOS, macOS, legacy Android) | `_useContainers` is false; engine selection at the call site falls through to `CookieIsolationEngine`. No cross-engine state leaks. |

The engine selection lives in
[`_WebSpacePageState`](../../../lib/main.dart) — a single
`bool _useContainers` cached at startup gates the whole capture-nuke-
restore code path. There is no per-call branching beyond that.

## Requirements

### Requirement: CONT-001 — Engine Selection

The system SHALL select between `ContainerIsolationEngine` and
`CookieIsolationEngine` based on a single `ContainerNative.isSupported()`
check resolved at app startup.

#### Scenario: Profile API supported on Android

**Given** the app is launching on Android with System WebView 110+
  (`WebViewFeature.MULTI_PROFILE` true)
**When** `_restoreAppState` runs
**Then** `_useContainers` resolves to `true`
**And** every subsequent `_setCurrentIndex(index)` skips
  `SiteActivationEngine.findDomainConflict` and the capture-nuke-
  restore cycle — superseding the legacy
  [ISO-001](../per-site-cookie-isolation/spec.md) mutex
**And** `_setCurrentIndex(index)` calls
  `ContainerIsolationEngine.ensureContainer(target.siteId)` instead

#### Scenario: Profile API supported on iOS / macOS

**Given** the app is launching on iOS 17+ or macOS 14+
**When** `_restoreAppState` runs
**Then** the native plugin reports `isSupported() == true`
**And** `_useContainers` resolves to `true`
**And** the same conflict-skip / engine-selection behavior as Android
  applies — sites with shared base domains can coexist

#### Scenario: Profile API supported on Linux

**Given** the app is launching on Linux against the WebSpace fork's
  `flutter_inappwebview_linux` (WPE WebKit 2.40+)
**When** `_restoreAppState` runs
**Then** `inapp.ContainerController.isClassSupported(platform: TargetPlatform.linux)`
  returns true
**And** `_useContainers` resolves to `true`
**And** the WebView is constructed against its per-site
  `WebKitNetworkSession` via `InAppWebViewSettings.containerId`
**And** sites with shared base domains can coexist

#### Scenario: Profile API not supported

**Given** the app is launching on Android System WebView <110, or
  iOS <17, or macOS <14, or Windows / web (or Linux without the fork
  override resolved)
**When** `_restoreAppState` runs
**Then** `_useContainers` resolves to `false`
**And** `_setCurrentIndex` runs the existing capture-nuke-restore flow
  unchanged
**And** `ContainerIsolationEngine.bindForSite` is a no-op (returns 0
  without touching ProfileStore)

### Requirement: CONT-002 — Profile Lifecycle

Each `siteId` SHALL map 1:1 to a native profile named `ws-<siteId>`.
The profile is created on demand and deleted when the site is deleted.

#### Scenario: Profile created on first activation

**Given** site A has never been activated in profile mode
**When** the user activates site A
**Then** `ProfileStore.getOrCreateContainer("ws-<siteA.siteId>")` is
  called (idempotent — pre-existing profiles are reused)
**And** the named profile exists in
  `ProfileStore.allProfileNames` after the call

#### Scenario: Profile bound to WebView at construction

**Given** flutter_inappwebview is constructing the native WebView for
  site A
**When** `onWebViewCreated` fires
**Then** the native plugin calls
  `WebViewCompat.setProfile(webView, "ws-<siteA.siteId>")`
**And** any subsequent storage operation on that WebView (cookie
  read/write, `localStorage`, `IndexedDB`, ServiceWorker, HTTP cache)
  is partitioned to that profile's directory

#### Scenario: Profile deleted on site deletion

**Given** site A exists with profile `ws-<siteA.siteId>`
**When** the user deletes site A
**Then** `ContainerIsolationEngine.onSiteDeleted` is called
**And** `ProfileStore.deleteContainer("ws-<siteA.siteId>")` removes the
  profile and all of its on-disk data
**And** the legacy `CookieIsolationEngine.preDeleteCookieCleanup` is
  NOT called (would be a no-op since cookies live in the profile, but
  skipping it makes the deletion path cleaner)

### Requirement: CONT-003 — Same-Base-Domain Sites Coexist

In profile mode, two sites that share a base domain SHALL be able to
load and run concurrently with fully isolated cookies, `localStorage`,
`IndexedDB`, ServiceWorkers, and HTTP cache.

#### Scenario: Two GitHub accounts loaded simultaneously

**Given** site A (`github.com/personal`) and site B (`github.com/work`)
  both exist
**And** profile mode is active
**When** the user activates site A and then site B without unloading A
**Then** site A is NOT unloaded (no `_unloadSiteForDomainSwitch` call)
**And** both sites are in `_loadedIndices`
**And** site A's session cookies are not visible to site B and vice
  versa
**And** site B logging out does not log site A out

#### Scenario: Switching back to a still-loaded sibling preserves session

**Given** sites A and B (above) are both loaded with active sessions
**When** the user switches from A to B and back to A
**Then** site A's session is intact — no re-login, no reload, no
  capture-nuke-restore cycle ran

### Requirement: CONT-004 — Orphan Garbage Collection

The system SHALL sweep profiles whose owning site no longer exists.

#### Scenario: Startup sweep

**Given** `ProfileStore` contains profiles for siteIds A, B, C
**And** the persisted site list contains only A and C (B was deleted
  in a previous session before profile mode was enabled, or via a
  crash mid-deletion)
**When** the app launches and `_restoreAppState` runs
**Then** `ContainerIsolationEngine.garbageCollectOrphans({A, C})` is
  invoked
**And** profile `ws-B` is deleted
**And** profile `ws-A` and `ws-C` are preserved

#### Scenario: GC is a no-op when nothing is orphaned

**Given** every profile in `ProfileStore` corresponds to a live site
**When** GC runs
**Then** no profile is deleted
**And** the call returns 0

### Requirement: CONT-005 — Native-Side Bind Before Construction

The Profile API binding SHALL run before any session-bound operation
on the WebView, on both Android and iOS / macOS. The constraints
differ in shape but are equivalent in effect:

- **Android.** `WebViewCompat.setProfile` throws
  `IllegalStateException` if the WebView has already done `loadUrl`,
  `evaluateJavascript`, `addJavascriptInterface`,
  `addDocumentStartJavaScript`, or
  `CookieManager.setAcceptThirdPartyCookies(webView, ...)`. Stock
  `InAppWebView.prepare()` runs all of those synchronously inside
  `FlutterWebViewFactory.create()`, before `onWebViewCreated` fires
  Dart-side. So the bind has to happen at the top of `prepare()`.
- **iOS / macOS.** `WKWebViewConfiguration.websiteDataStore` is
  copied at `WKWebView(frame: configuration:)` and frozen — there is
  no `setWebsiteDataStore(_:)` on a live WKWebView. So the bind has
  to happen during `preWKWebViewConfiguration(settings:)`, before the
  configuration reaches the WKWebView constructor.

In both cases, a post-hoc bind from `onWebViewCreated` is too late.
The fix lives in the WebSpace fork of `flutter_inappwebview`
(monorepo at <https://github.com/theoden8/flutter_inappwebview>,
pinned by `dependency_overrides` in
[`pubspec.yaml`](../../../pubspec.yaml)). Per-platform changes:

- `flutter_inappwebview_android`: adds `containerId: String?`
  to `InAppWebViewSettings`, binds it via
  `ProfileStore.getOrCreateContainer` + `WebViewCompat.setProfile` at
  the very top of `prepare()`.
- `flutter_inappwebview_ios`: adds the same `containerId` field
  on the Swift side, sets
  `configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier:
  WebSpaceProfile.uuid(for: profileName))` in
  `preWKWebViewConfiguration` before
  `WKWebView(frame: configuration:)` runs. The UUID is derived
  deterministically from the profile name via SHA-256 (Apple's API
  requires a UUID; our siteIds are opaque strings).
- `flutter_inappwebview_macos`: same shape as the iOS change,
  applied to the macOS plugin.

From Dart, [`WebViewFactory.createWebView`](../../../lib/services/webview.dart)
sets the stock [`inapp.InAppWebViewSettings.containerId`] field to
`ws-<siteId>` whenever container mode is supported. The fork
serializes that field through its standard `toMap()` and the native
side picks it up directly — there is no WebSpace-side subclass of
`InAppWebViewSettings` anymore.

#### Scenario: Bind happens during `prepare()`

**Given** profile mode is supported, a `siteId` is set, and the
  WebSpace fork is resolved via `dependency_overrides` in
  `pubspec.yaml`
**When** the `InAppWebView` is constructed
**Then** `InAppWebView.prepare()` reads
  `settings.containerId` and calls
  `ProfileStore.getOrCreateContainer` followed by
  `WebViewCompat.setProfile(this, profileName)` BEFORE
  `addJavascriptInterface`, `addDocumentStartJavaScript`,
  `setAcceptThirdPartyCookies`, or any other session-bound op
**And** the subsequent `webView.loadUrl(initialUrlRequest)` runs
  under the bound profile
**And** every cookie / `localStorage` / IDB / ServiceWorker / cache
  write throughout the WebView's lifetime is partitioned to that
  profile

#### Scenario: Stock plugin (or `containerId == null`) is unaffected

**Given** the `containerId` field is null (iOS, macOS, legacy
  Android with `cachedSupported == false`, or any code path that
  does not opt in)
**When** `prepare()` runs
**Then** the fork's bind block early-returns and `prepare()`
  proceeds unchanged
**And** behavior matches stock upstream `flutter_inappwebview_android`

#### Scenario: Same-base-domain sites coexist with isolated state

**Given** sites A (`github.com/personal`) and B (`github.com/work`)
  are both loaded and have completed `prepare()`
**When** A writes a session cookie via JS
**Then** B's cookie jar (read via JS or `getCookies(B.url)`) does
  NOT contain A's cookie — partitioning is enforced by the native
  Profile, not by Dart-level capture-nuke-restore

### Requirement: CONT-006 — Cookie Ops via ContainerCookieManager

Every per-site cookie operation (read, delete, block) SHALL route
through [`ContainerCookieManager`](../../../lib/services/container_cookie_manager.dart)
in profile mode, which calls
`inapp.CookieManager.instance().{getCookies,deleteCookie}` with
`webViewController: controller.nativeController`. The WebSpace
fork honors that parameter on every platform: Android's
`MyCookieManager.java` walks to the bound
`androidx.webkit.Profile.getCookieManager()`; iOS/macOS's
`MyCookieManager.swift` walks to the WebView's
`WKWebsiteDataStore.httpCookieStore`. `ContainerCookieManager` is the
peer of [`CookieManager`](../../../lib/services/webview.dart) — the
two are siblings in `_WebSpacePageState`, never composed; exactly
one is non-null per the engine selection.

This subsumes [ISO-011](../per-site-cookie-isolation/spec.md#requirement-iso-011---per-site-cookie-blocking)
in profile mode. HttpOnly cookies, which the prior JS-eval
(`document.cookie = ...`) approach could not touch, are now
deletable because the operation happens in the native cookie store.

#### Scenario: Cookie blocking targets the per-site profile

**Given** profile mode is active and Site A has `_ga` blocked via
  `BlockedCookie(name: "_ga", domain: ".google.com")`
**When** the page sets `_ga` and `onCookiesChanged` fires
**Then** `ContainerCookieManager.deleteCookie(controller: ...,
  siteId: "<A.siteId>", url: A.currentUrl, name: "_ga", domain:
  ".google.com")` runs
**And** the patched plugin routes the delete to A's profile cookie
  store via `webViewController:`
**And** Site B's profile is unaffected — its own `_ga` (if any) is
  still there

#### Scenario: HttpOnly cookies are deletable

**Given** Site A blocks an HttpOnly cookie (typical: a server-set
  session token)
**When** `ContainerCookieManager.deleteCookie` runs
**Then** the cookie is removed from the profile's cookie store —
  the delete reaches the native cookie manager, not
  `document.cookie` (which can't see HttpOnly entries)

#### Scenario: DevTools cookie inspector shows the per-site jar

**Given** profile mode is active and Site A is the current site
**When** the user opens DevTools → Cookies tab
**Then** `_refreshCookies` calls
  `ContainerCookieManager.getCookies(controller: ..., siteId: ...,
  url: ...)` (per [DEVTOOLS-002](../developer-tools/spec.md#requirement-devtools-002---cookie-inspector))
**And** the listed cookies match Site A's per-profile jar — what
  the page itself sees, including HttpOnly entries — not the
  global default jar (which in profile mode is unused)

#### Scenario: Legacy mode is unchanged

**Given** legacy mode (`_useContainers == false`)
**When** any cookie op runs (blocking, DevTools delete, etc.)
**Then** `_profileCookieManager` is null and the call branches to
  the existing `CookieManager` path, byte-identical to
  pre-Profile-API behaviour

### Requirement: CONT-007 — No GMS in Shipped Artifacts

The Profile API plugin SHALL NOT introduce any
`com.google.android.gms.*`, `com.google.firebase.*`, or
`com.google.android.play.*` classes into the shipped APK.
Enforcement: [scripts/check_no_gms.sh](../../../scripts/check_no_gms.sh)
runs against the built F-Droid APK and fails the build on any hit.

#### Scenario: F-Droid build is clean

**Given** `fvm flutter build apk --flavor fdroid --release` has
  completed
**When** `scripts/check_no_gms.sh build/app/outputs/flutter-apk/app-fdroid-release.apk`
  runs
**Then** it lists no defined packages under any forbidden prefix
**And** exits 0
**And** [test/gms_freedom_test.dart](../../../test/gms_freedom_test.dart)
  passes when run with `--tags ci`

## Implementation Details

### Logic Engines

- [`ContainerIsolationEngine`](../../../lib/services/container_isolation_engine.dart)
  — pure-Dart engine. Methods: `ensureContainer(siteId)`,
  `bindForSite(siteId)`, `onSiteDeleted(siteId)`,
  `garbageCollectOrphans(activeSiteIds)`. No Flutter imports, no
  `setState`, no `context`. Constructor takes a [`ContainerNative`]
  instance so tests can inject a mock.
- [`CookieIsolationEngine`](../../../lib/services/cookie_isolation.dart)
  — unchanged. Used as the fallback engine when
  `ContainerNative.isSupported()` is false.
- Engine selection lives in
  [`_WebSpacePageState`](../../../lib/main.dart) as a single cached
  `bool _useContainers`, resolved during `_restoreAppState`.

### Native Bridge

[`ContainerNative`](../../../lib/services/container_native.dart) is an
abstract Dart interface with two implementations:

- `_MethodChannelContainerNative` (Android) — talks to
  [`WebSpaceContainerPlugin.kt`](../../../android/app/src/main/kotlin/org/codeberg/theoden8/webspace/WebSpaceContainerPlugin.kt)
  via `MethodChannel('org.codeberg.theoden8.webspace/profile')`.
  `isSupported()` is cached after the first call.
- `_StubContainerNative` (iOS, macOS, fallback) — every method is a
  no-op; `isSupported()` returns `false`.

The Android plugin uses the same view-tree-walk pattern as
[`WebInterceptPlugin.attachToAllWebViews`](../../../android/app/src/main/kotlin/org/codeberg/theoden8/webspace/WebInterceptPlugin.kt)
to find the WebViews flutter_inappwebview created internally —
`activity.window.decorView.rootView` is recursively scanned for
`InAppWebView` instances. This avoids forking the plugin: we attach
profile binding *after* the WebView exists, by inspection of the
live view hierarchy.

### Per-WebView Bind Site

[`WebViewFactory.createWebView`](../../../lib/services/webview.dart)
constructs the stock [`inapp.InAppWebViewSettings`] with the desired
container name in the `containerId` field. The WebSpace fork
(resolved via `dependency_overrides` in
[`pubspec.yaml`](../../../pubspec.yaml)) reads that field during
construction and binds the WebView:

```dart
final containerId = (ContainerNative.instance.cachedSupported &&
        config.siteId != null)
    ? 'ws-${config.siteId}'
    : null;

final settings = inapp.InAppWebViewSettings(containerId: containerId)
  ..javaScriptEnabled = config.javascriptEnabled
  ..userAgent = config.userAgent
  ..thirdPartyCookiesEnabled = config.thirdPartyCookiesEnabled
  // … other fields …
  ..isInspectable = kDebugMode;

return inapp.InAppWebView(
  initialSettings: settings,
  initialUrlRequest: ...,
  onWebViewCreated: (controller) async {
    // Profile is already bound natively by the time this fires.
    // No Dart-side bind step needed.
    ...
  },
);
```

`cachedSupported` is the synchronous getter on
[`ContainerNative`](../../../lib/services/container_native.dart),
populated during `_restoreAppState` (the same pass that resolves
`_useContainers`). The first webview a process ever constructs
(before `_restoreAppState` runs to completion) sees
`cachedSupported == false` and takes the non-profile path — but by
then no site has been activated yet, so this case never fires in
practice.

The legacy [`ContainerNative.bindContainerToWebView`](../../../lib/services/container_native.dart)
post-hoc bind method remains in the engine for diagnostics and the
mock used by tests, but the production webview-construction path no
longer calls it; the native plugin does the bind during `prepare()`.

`Future.microtask` is still used for
`WebInterceptNative.attachToWebViews`, which is race-insensitive
(the ContentBlockerHandler can be set post-load).

### Per-Site Settings Still Apply

A profile gives storage isolation, not behavior changes. Per-site
settings — language, geolocation/timezone spoof, WebRTC policy, user
scripts, content blocking, ClearURLs, DNS blocklist, cookie blocking,
blockAutoRedirects — remain `WebViewConfig`-driven
and propagate to nested webviews via `launchUrl` →
`InAppWebViewScreen` exactly as today (per the CLAUDE.md
"Per-site settings MUST apply to nested webviews" rule).

Adding profiles changes *where cookies and storage live*, not *which
JS gets injected*.

## Files

### Modified
- `android/app/build.gradle` — adds `androidx.webkit:webkit:1.12.1`
- `android/app/src/main/kotlin/.../MainActivity.kt` —
  instantiates `WebSpaceContainerPlugin`
- `lib/main.dart` — caches `_useContainers`, gates engine selection in
  `_setCurrentIndex` and `_deleteSite`, runs orphan GC in
  `_restoreAppState`
- `lib/services/webview.dart` — calls
  `ContainerNative.instance.getOrCreateContainer + bindContainerToWebView`
  in `onWebViewCreated`

### Created
- `android/app/src/main/kotlin/.../WebSpaceContainerPlugin.kt` —
  native plugin
- `lib/services/container_native.dart` — Dart interface + Android
  MethodChannel impl + iOS / macOS stub
- `lib/services/container_isolation_engine.dart` — pure-Dart engine
- `test/container_isolation_engine_test.dart` — engine unit tests with
  `MockContainerNative`
- `scripts/check_no_gms.sh` — GMS scanner script
- `test/gms_freedom_test.dart` — CI-tagged test that shells out to
  the scanner
- `openspec/specs/per-site-containers/spec.md` — this specification

## iOS / macOS Path Forward (Not This Spec)

The Dart interface in
[`lib/services/container_native.dart`](../../../lib/services/container_native.dart)
is cross-platform from day one. The iOS/macOS implementation is
gated behind a flutter_inappwebview enhancement: the plugin's
`InAppWebViewSettings` does not yet expose `websiteDataStoreId`, and
`WKWebViewConfiguration.websiteDataStore` is set at WKWebView
construction time. There is no Android-style post-construction
reflection hook on iOS — `setWebsiteDataStore(_:)` doesn't exist on
a live WKWebView.

Three tracked options when the iOS work is scheduled:

1. **Upstream PR / vendored fork.** Add
   `String? websiteDataStoreId` to `InAppWebViewSettings`. Swift
   side wraps
   `configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: UUID(...))`
   under `if #available(iOS 17, macOS 14)`. Floor: iOS 17 / macOS 14.
   Estimated patch size: ~50 LOC.
2. **Method-swizzle `WKWebView.init(frame:configuration:)`** in our
   own Swift layer, rewriting `configuration.websiteDataStore` before
   the real init runs. Possible but fragile across iOS versions and
   raises App Store review questions.
3. **Replace the plugin's WKWebView post-construction.** Fights the
   platform-view machinery; pays a full reload on every site
   activation (no scroll/JS-heap/BFCache continuity within a
   webspace). Strict regression vs. today's capture-nuke-restore.

(1) is the recommended path. Tracking issue:
[flutter/flutter#151055](https://github.com/flutter/flutter/issues/151055).

When iOS plumbing lands:

1. Replace `_StubContainerNative` in `container_native.dart` with a
   MethodChannel impl on iOS/macOS, and switch
   `ContainerNative.instance` selection to include
   `Platform.isIOS || Platform.isMacOS`.
2. Add `WebSpaceContainerPlugin.swift` registered via the shared
   runner.
3. Adjust the bind call site: iOS needs the data store assigned to
   `WKWebViewConfiguration` *before* construction, so the
   Dart-side path threads `websiteDataStoreId` into
   `InAppWebViewSettings` rather than calling
   `bindContainerToWebView` after the fact. The engine's
   `bindForSite` API absorbs this — only the platform impl differs.
4. iOS-specific test: verify `websiteDataStoreId` is threaded into
   the settings dict for activation paths.

## Testing

### Unit Tests

```bash
fvm flutter test test/container_isolation_engine_test.dart
```

Engine tests cover:

- Unsupported-platform short-circuit (no native ProfileStore is
  touched when `isSupported() == false`)
- Create-then-bind sequencing of `bindForSite`
- Idempotency of repeated `bindForSite` calls
- `onSiteDeleted` only drops the named site
- Orphan GC against the live siteId set
- Empty-active-set GC (every profile dropped)

### Integration Tests

The legacy [test/cookie_isolation_integration_test.dart](../../../test/cookie_isolation_integration_test.dart)
continues to cover the fallback path; it exercises
`CookieIsolationEngine` directly and is unaffected by the new
engine selection.

### CI Integrity Check

```bash
fvm flutter build apk --flavor fdroid --release
bash scripts/check_no_gms.sh build/app/outputs/flutter-apk/app-fdroid-release.apk
fvm flutter test --tags ci test/gms_freedom_test.dart
```

CI calls `scripts/check_no_gms.sh` directly so a missing APK is a
hard failure rather than a skipped test. The Dart wrapper is for
local-dev convenience.

## Manual Testing

Profile-mode hardware (Android with Chrome WebView 110+):

1. Create two sites on the same domain, e.g. `github.com/personal`
   and `github.com/work`.
2. Activate site A, log in.
3. Activate site B *without unloading A* — confirm A stays in the
   IndexedStack (no `_unloadSiteForDomainSwitch` log line) and a
   different login screen appears.
4. Log into site B with a different account.
5. Switch back to A — its session is intact, no reload, no
   capture-nuke-restore log lines.
6. Inspect app data dir
   (`/data/data/org.codeberg.theoden8.webspace/app_webview_<profile>/`):
   confirm one directory per profile, each with its own `Cookies`,
   `Local Storage/`, `IndexedDB/`, `Service Worker/`, `Cache/`.
7. Delete site A — confirm its profile dir is gone and B's is
   intact.

Legacy hardware (Android System WebView <110):

1. Confirm at startup `LogService` reports `Profile API not
   supported — using CookieIsolationEngine fallback`.
2. Repeat the existing
   [openspec/specs/per-site-cookie-isolation/spec.md](../per-site-cookie-isolation/spec.md)
   manual tests — behavior must be identical to before this change.

iOS / macOS:

- Behavior is unchanged. `_useContainers` is `false`, the legacy
  engine handles isolation. Run the
  per-site-cookie-isolation manual tests.
