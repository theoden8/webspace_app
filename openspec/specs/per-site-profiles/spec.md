# Per-Site Profiles

## Status
**Implemented on Android (System WebView 110+) and iOS / macOS (iOS 17+ /
macOS 14+). Older OS / WebView versions fall through to
[`CookieIsolationEngine`](../per-site-cookie-isolation/spec.md).**

## Purpose

Engine-level cookie + storage isolation between sites in WebSpace.
Replaces the cookie-only capture-nuke-restore engine on platforms with
native per-site data-store primitives:

- **Android**, System WebView 110+: `androidx.webkit.Profile`. Each
  site maps to a named profile `ws-<siteId>`.
- **iOS 17+ / macOS 14+**: `WKWebsiteDataStore(forIdentifier: UUID)`.
  The siteId string is hashed via SHA-256 to produce a deterministic
  UUID (`WebSpaceProfile.uuid(for:)` — added by the iOS / macOS
  plugin patches; see
  [`third_party/PATCHES.md`](../../../third_party/PATCHES.md))
  and that UUID identifies the per-site data store.

Each `WebViewModel.siteId` owns its own cookie jar, `localStorage`,
`IndexedDB`, `ServiceWorkerController`, and HTTP cache. **Profile mode
supersedes (not supplements) the legacy ISO-001 mutex** from
[per-site-cookie-isolation](../per-site-cookie-isolation/spec.md): when
`_useProfiles == true` the conflict-find / unload code path is skipped
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
| App startup, after restoring sites | Cache `ProfileNative.isSupported()` once. Sweep profiles whose owning site no longer exists (`ProfileIsolationEngine.garbageCollectOrphans`). |
| Site activated | `ProfileIsolationEngine.ensureProfile(siteId)` (idempotent). |
| WebView created (`onWebViewCreated`) | `ProfileNative.bindProfileToWebView(siteId)` — native side walks the activity view tree and calls `WebViewCompat.setProfile` on every flutter_inappwebview WebView for that siteId. |
| Site deleted | `ProfileIsolationEngine.onSiteDeleted(siteId)` after `disposeWebView`. |
| Profile API not supported (iOS, macOS, legacy Android) | `_useProfiles` is false; engine selection at the call site falls through to `CookieIsolationEngine`. No cross-engine state leaks. |

The engine selection lives in
[`_WebSpacePageState`](../../../lib/main.dart) — a single
`bool _useProfiles` cached at startup gates the whole capture-nuke-
restore code path. There is no per-call branching beyond that.

## Requirements

### Requirement: PROF-001 — Engine Selection

The system SHALL select between `ProfileIsolationEngine` and
`CookieIsolationEngine` based on a single `ProfileNative.isSupported()`
check resolved at app startup.

#### Scenario: Profile API supported on Android

**Given** the app is launching on Android with System WebView 110+
  (`WebViewFeature.MULTI_PROFILE` true)
**When** `_restoreAppState` runs
**Then** `_useProfiles` resolves to `true`
**And** every subsequent `_setCurrentIndex(index)` skips
  `SiteActivationEngine.findDomainConflict` and the capture-nuke-
  restore cycle — superseding the legacy
  [ISO-001](../per-site-cookie-isolation/spec.md) mutex
**And** `_setCurrentIndex(index)` calls
  `ProfileIsolationEngine.ensureProfile(target.siteId)` instead

#### Scenario: Profile API supported on iOS / macOS

**Given** the app is launching on iOS 17+ or macOS 14+
**When** `_restoreAppState` runs
**Then** the native plugin reports `isSupported() == true`
**And** `_useProfiles` resolves to `true`
**And** the same conflict-skip / engine-selection behavior as Android
  applies — sites with shared base domains can coexist

#### Scenario: Profile API not supported

**Given** the app is launching on Android System WebView <110, or
  iOS <17, or macOS <14, or Linux / Windows
**When** `_restoreAppState` runs
**Then** `_useProfiles` resolves to `false`
**And** `_setCurrentIndex` runs the existing capture-nuke-restore flow
  unchanged
**And** `ProfileIsolationEngine.bindForSite` is a no-op (returns 0
  without touching ProfileStore)

### Requirement: PROF-002 — Profile Lifecycle

Each `siteId` SHALL map 1:1 to a native profile named `ws-<siteId>`.
The profile is created on demand and deleted when the site is deleted.

#### Scenario: Profile created on first activation

**Given** site A has never been activated in profile mode
**When** the user activates site A
**Then** `ProfileStore.getOrCreateProfile("ws-<siteA.siteId>")` is
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
**Then** `ProfileIsolationEngine.onSiteDeleted` is called
**And** `ProfileStore.deleteProfile("ws-<siteA.siteId>")` removes the
  profile and all of its on-disk data
**And** the legacy `CookieIsolationEngine.preDeleteCookieCleanup` is
  NOT called (would be a no-op since cookies live in the profile, but
  skipping it makes the deletion path cleaner)

### Requirement: PROF-003 — Same-Base-Domain Sites Coexist

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

### Requirement: PROF-004 — Orphan Garbage Collection

The system SHALL sweep profiles whose owning site no longer exists.

#### Scenario: Startup sweep

**Given** `ProfileStore` contains profiles for siteIds A, B, C
**And** the persisted site list contains only A and C (B was deleted
  in a previous session before profile mode was enabled, or via a
  crash mid-deletion)
**When** the app launches and `_restoreAppState` runs
**Then** `ProfileIsolationEngine.garbageCollectOrphans({A, C})` is
  invoked
**And** profile `ws-B` is deleted
**And** profile `ws-A` and `ws-C` are preserved

#### Scenario: GC is a no-op when nothing is orphaned

**Given** every profile in `ProfileStore` corresponds to a live site
**When** GC runs
**Then** no profile is deleted
**And** the call returns 0

### Requirement: PROF-005 — Native-Side Bind Before Construction

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
The patches that close this gap live as `.patch` files under
[`third_party/`](../../../third_party/PATCHES.md) and are applied
to the upstream pub-cache copy of each plugin at build time by
[`scripts/apply_plugin_patches.dart`](../../../scripts/apply_plugin_patches.dart):

- `third_party/flutter_inappwebview_android.patch`:
  adds `webspaceProfile: String?` to `InAppWebViewSettings`, binds it
  via `ProfileStore.getOrCreateProfile` + `WebViewCompat.setProfile`
  at the very top of `prepare()`.
- `third_party/flutter_inappwebview_ios.patch`:
  adds the same `webspaceProfile` field on the Swift side, sets
  `configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier:
  WebSpaceProfile.uuid(for: profileName))` in
  `preWKWebViewConfiguration` before
  `WKWebView(frame: configuration:)` runs. The UUID is derived
  deterministically from the profile name via SHA-256 (Apple's API
  requires a UUID; our siteIds are opaque strings).
- `third_party/flutter_inappwebview_macos.patch`: same shape as the
  iOS patch, applied to the macOS plugin.

From Dart, the
[`WebSpaceInAppWebViewSettings`](../../../lib/services/webview.dart)
subclass overrides `toMap()` to inject the `webspaceProfile` key
into the settings map sent to native — the patched plugins on each
platform pick it up by KVC reflection (iOS) or explicit case match
(Android).

#### Scenario: Bind happens during `prepare()`

**Given** profile mode is supported, a `siteId` is set, and the
  patched plugin is installed (resolved via `dependency_overrides` in
  `pubspec.yaml`)
**When** the `InAppWebView` is constructed
**Then** `InAppWebView.prepare()` reads
  `customSettings.webspaceProfile` and calls
  `ProfileStore.getOrCreateProfile` followed by
  `WebViewCompat.setProfile(this, profileName)` BEFORE
  `addJavascriptInterface`, `addDocumentStartJavaScript`,
  `setAcceptThirdPartyCookies`, or any other session-bound op
**And** the subsequent `webView.loadUrl(initialUrlRequest)` runs
  under the bound profile
**And** every cookie / `localStorage` / IDB / ServiceWorker / cache
  write throughout the WebView's lifetime is partitioned to that
  profile

#### Scenario: Stock plugin (or `webspaceProfile == null`) is unaffected

**Given** the `webspaceProfile` field is null (iOS, macOS, legacy
  Android with `cachedSupported == false`, or any code path that
  does not opt in)
**When** `prepare()` runs
**Then** the patched bind block early-returns and `prepare()`
  proceeds unchanged
**And** behavior matches stock upstream `flutter_inappwebview_android`

#### Scenario: Same-base-domain sites coexist with isolated state

**Given** sites A (`github.com/personal`) and B (`github.com/work`)
  are both loaded and have completed `prepare()`
**When** A writes a session cookie via JS
**Then** B's cookie jar (read via JS or `getCookies(B.url)`) does
  NOT contain A's cookie — partitioning is enforced by the native
  Profile, not by Dart-level capture-nuke-restore

### Requirement: PROF-006 — No GMS in Shipped Artifacts

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

- [`ProfileIsolationEngine`](../../../lib/services/profile_isolation_engine.dart)
  — pure-Dart engine. Methods: `ensureProfile(siteId)`,
  `bindForSite(siteId)`, `onSiteDeleted(siteId)`,
  `garbageCollectOrphans(activeSiteIds)`. No Flutter imports, no
  `setState`, no `context`. Constructor takes a [`ProfileNative`]
  instance so tests can inject a mock.
- [`CookieIsolationEngine`](../../../lib/services/cookie_isolation.dart)
  — unchanged. Used as the fallback engine when
  `ProfileNative.isSupported()` is false.
- Engine selection lives in
  [`_WebSpacePageState`](../../../lib/main.dart) as a single cached
  `bool _useProfiles`, resolved during `_restoreAppState`.

### Native Bridge

[`ProfileNative`](../../../lib/services/profile_native.dart) is an
abstract Dart interface with two implementations:

- `_MethodChannelProfileNative` (Android) — talks to
  [`WebSpaceProfilePlugin.kt`](../../../android/app/src/main/kotlin/org/codeberg/theoden8/webspace/WebSpaceProfilePlugin.kt)
  via `MethodChannel('org.codeberg.theoden8.webspace/profile')`.
  `isSupported()` is cached after the first call.
- `_StubProfileNative` (iOS, macOS, fallback) — every method is a
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
constructs a `WebSpaceInAppWebViewSettings` (subclass of
`InAppWebViewSettings`) with the desired profile name in
`webspaceProfile`. The subclass overrides `toMap()` to inject that
key into the settings dict sent to native. The build-time-patched
plugins (see
[`third_party/PATCHES.md`](../../../third_party/PATCHES.md))
read it during construction and bind the WebView:

```dart
final webspaceProfile = (Platform.isAndroid &&
        ProfileNative.instance.cachedSupported &&
        config.siteId != null)
    ? 'ws-${config.siteId}'
    : null;

final settings = WebSpaceInAppWebViewSettings(webspaceProfile: webspaceProfile)
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
[`ProfileNative`](../../../lib/services/profile_native.dart),
populated during `_restoreAppState` (the same pass that resolves
`_useProfiles`). The first webview a process ever constructs
(before `_restoreAppState` runs to completion) sees
`cachedSupported == false` and takes the non-profile path — but by
then no site has been activated yet, so this case never fires in
practice.

The legacy [`ProfileNative.bindProfileToWebView`](../../../lib/services/profile_native.dart)
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
  instantiates `WebSpaceProfilePlugin`
- `lib/main.dart` — caches `_useProfiles`, gates engine selection in
  `_setCurrentIndex` and `_deleteSite`, runs orphan GC in
  `_restoreAppState`
- `lib/services/webview.dart` — calls
  `ProfileNative.instance.getOrCreateProfile + bindProfileToWebView`
  in `onWebViewCreated`

### Created
- `android/app/src/main/kotlin/.../WebSpaceProfilePlugin.kt` —
  native plugin
- `lib/services/profile_native.dart` — Dart interface + Android
  MethodChannel impl + iOS / macOS stub
- `lib/services/profile_isolation_engine.dart` — pure-Dart engine
- `test/profile_isolation_engine_test.dart` — engine unit tests with
  `MockProfileNative`
- `scripts/check_no_gms.sh` — GMS scanner script
- `test/gms_freedom_test.dart` — CI-tagged test that shells out to
  the scanner
- `openspec/specs/per-site-profiles/spec.md` — this specification

## iOS / macOS Path Forward (Not This Spec)

The Dart interface in
[`lib/services/profile_native.dart`](../../../lib/services/profile_native.dart)
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

1. Replace `_StubProfileNative` in `profile_native.dart` with a
   MethodChannel impl on iOS/macOS, and switch
   `ProfileNative.instance` selection to include
   `Platform.isIOS || Platform.isMacOS`.
2. Add `WebSpaceProfilePlugin.swift` registered via the shared
   runner.
3. Adjust the bind call site: iOS needs the data store assigned to
   `WKWebViewConfiguration` *before* construction, so the
   Dart-side path threads `websiteDataStoreId` into
   `InAppWebViewSettings` rather than calling
   `bindProfileToWebView` after the fact. The engine's
   `bindForSite` API absorbs this — only the platform impl differs.
4. iOS-specific test: verify `websiteDataStoreId` is threaded into
   the settings dict for activation paths.

## Testing

### Unit Tests

```bash
fvm flutter test test/profile_isolation_engine_test.dart
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

- Behavior is unchanged. `_useProfiles` is `false`, the legacy
  engine handles isolation. Run the
  per-site-cookie-isolation manual tests.
