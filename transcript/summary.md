# Webspace App — Project Exploration Notes

## What this repo is
- **Type**: Flutter app (mobile + desktop targets).
- **Core purpose**: Run and manage **multiple persistent webviews** ("sites") organized into **webspaces**, accessible via a drawer.
- **Primary code location**: `lib/` (~15+ Dart files with webspaces, proxy, and platform abstraction).
- **Version**: 0.0.1+1
- **License**: MIT (Copyright 2023 Kirill Rodriguez)
- **Assets License**: CC BY-NC-SA 4.0 (Copyright Polina Levchenko)
- **Origin**: Initially created using GPT-4 (see `transcript/0-gpt4-coding.md`)

## Tech stack / dependencies (high-signal)
- **Flutter SDK** (Dart SDK constraint in `pubspec.yaml`: `>=3.0.0-417.1.beta <4.0.0`)
- **Webview**: `flutter_inappwebview` (embedded webviews + cookie manager + proxy + find-in-page APIs)
- **Persistence**: `shared_preferences` (stores webspaces, site models, current index, theme)
- **UUID**: `uuid` (unique identifiers for webspaces)
- **Networking**: `http` (used for favicon and title extraction)
- **Images**: `cached_network_image` (favicon display caching)
- **HTML Parsing**: `html` (page title extraction)

## Platform targets / build config
- **iOS**: Supported (flutter_inappwebview)
- **Android**: Supported (flutter_inappwebview)
  - Gradle config in `android/app/build.gradle`
  - `INTERNET` permission enabled in `android/app/src/main/AndroidManifest.xml`
- **macOS**: Supported (flutter_inappwebview)
- **Linux desktop**: Pending flutter_inappwebview Linux support

## App architecture (how it's built)
### Top-level flow
- `main()` runs `WebSpaceApp` (`lib/main.dart`).
- `WebSpaceApp` owns the **app-wide theme mode** and renders `MaterialApp(home: WebSpacePage(...))`.
- `WebSpacePage` is the primary UI:
  - **Webspaces Screen**: Shows list of webspaces when no site/webspace selected
  - **Drawer**: Shows sites filtered by selected webspace + "Add Site" button
  - **Body**: Shows the currently selected site via an `IndexedStack` of webviews (persistent widgets)
  - **AppBar** offers:
    - theme toggle (light/dark)
    - menu actions: Refresh, Find, Clear Cookies, Settings (per-site)

### Core data models

#### `Webspace` (`lib/webspace_model.dart`)
Organizes sites into logical groups:
- **Fields**:
  - `id` (UUID - unique identifier)
  - `name` (display name)
  - `siteIndices` (list of indices of WebViewModels in this webspace)
- JSON serialization for persistence
- Automatic index management when sites are deleted

#### `WebViewModel` (`lib/web_view_model.dart`)
Each "site" is represented by a `WebViewModel`:
- **Fields**:
  - `initUrl` (original URL)
  - `currentUrl` (last navigated URL)
  - `cookies` (list of `Cookie` from `flutter_inappwebview`)
  - `javascriptEnabled` (bool)
  - `userAgent` (string; empty means "use default")
  - `thirdPartyCookiesEnabled` (bool)
  - `proxySettings` (UserProxySettings - HTTP/HTTPS/SOCKS5 proxy configuration)
  - references to `InAppWebView` and controller
- **Key behavior**:
  - `getWebView(...)` constructs an `InAppWebView` once and keeps it for reuse.
  - **All webviews stay mounted in an `IndexedStack`** → memory grows linearly with number of sites
  - `shouldOverrideUrlLoading` implements **domain isolation**:
    - if navigation stays within the same "site domain" (based on last 2 DNS labels), allow
    - otherwise, open the target URL in a separate screen (`InAppWebViewScreen`) and cancel
  - `onLoadStop`:
    - grabs cookies from a `CookieManager`
    - updates `currentUrl`
    - persists state
    - optionally tries to delete "third-party cookies" via injected JavaScript

### Persistence model (SharedPreferences)
Stored keys in `lib/main.dart`:
- `webspaces`: `List<String>` of JSON strings (Webspace.toJson())
- `selectedWebspaceId`: String? (ID of currently selected webspace)
- `webViewModels`: `List<String>` of JSON strings (WebViewModel.toJson())
- `currentIndex`: int? (currently selected site index)
- `themeMode`: int (ThemeMode.index)

On startup (`_restoreAppState`), webspaces + theme + index + models are loaded and cookies/proxy settings are restored.

## Screens / UI components
- `lib/screens/webspaces_list.dart`: Main screen showing all webspaces with selection state
- `lib/screens/webspace_detail.dart`: Edit webspace (name + site assignments)
- `lib/screens/add_site.dart`: Simple URL entry (auto-prefixes `https://` when missing)
- `lib/screens/settings.dart`: Per-site settings UI:
  - Proxy type + address (HTTP/HTTPS/SOCKS5, platform-aware)
  - JavaScript enabled toggle
  - User-Agent text field + random UA generator
  - Third-party cookies toggle
- `lib/screens/inappbrowser.dart`: "External link" screen for domain-isolated navigation
- `lib/widgets/find_toolbar.dart`: In-page search UI using InAppWebView "find" APIs
- `lib/settings/proxy.dart`: Proxy settings data model

## Transcript
- `transcript/0-gpt4-coding.md` contains the GPT-4 session used to build the app quickly.
- Notable theme: earlier attempts used `webview_flutter` and different cookie APIs; final code is on `flutter_inappwebview` with cookie serialization.

## Notable quirks / likely bugs (important for future improvements)
### State restoration / index sentinel
- When saving `_currentIndex == null`, code writes `currentIndex = 10000`.
- On restore, it does **not** convert `10000` back to `null`.
  - The UI often handles out-of-range by showing “No WebView selected”, but the app still carries an invalid index value.

### Cookie capture timing
- In `WebViewModel.onLoadStop`, cookies are fetched using `currentUrl` **before** `currentUrl` is updated to the new URL.
  - This may save cookies for the previous page instead of the newly loaded page.

### Cookie JSON compatibility
- `cookieFromJson` uses a suspicious key: `json["sameSite?.toValue()"]`.
  - This looks incorrect and may break SameSite restore.

### “Third-party cookies removal” is best-effort only
- The JS approach manipulates `document.cookie`, which:
  - cannot remove `HttpOnly` cookies
  - can’t reliably determine/set domains the way network cookies work
  - may not do what users expect for true 3P cookie policies

### Domain isolation heuristic is simplistic
- `shouldOverrideUrlLoading` compares the last 2 labels of the host.
  - Works for many domains, but fails for public-suffix cases like `*.co.uk`.

### Favicon fetching can be expensive
- Drawer list tiles use `FutureBuilder(getFaviconUrl(...))` which performs an `http.get` to `/favicon.ico`.
  - This may be triggered frequently (rebuilds, scrolling, reordering).
  - `CachedNetworkImage` caches the image, but the **existence probe** still costs network.

### Find toolbar null-safety risks
- `FindToolbar.webViewController` is typed nullable (`InAppWebViewController?`) but is force-unwrapped in multiple places (e.g., `widget.webViewController!.findAllAsync(...)`).
- **Constructor signature is malformed**: `required this.onClose()` includes parentheses, which is invalid Dart syntax for a function parameter. Should be `required this.onClose`.

### Settings UX limitations
- You can’t “clear” a custom user-agent back to default by saving an empty string (save only writes UA if the field is non-empty).
- Proxy settings exist in UI and model, but proxy is currently effectively **non-functional** (`ProxyType` only has `DEFAULT` and isn’t applied to the webview/network stack).

## Recent additions
- **Webspaces feature**: Organize sites into logical workspaces (see `transcript/webspaces-feature.md`)
- **Proxy support**: HTTP/HTTPS/SOCKS5 proxy configuration with platform awareness (see `transcript/PROXY_FEATURE.md`)
- **Comprehensive tests**: Unit tests for models, platform abstraction, proxy, and webspaces
- **Platform abstraction layer**: `lib/platform/` for cross-platform webview management
- **GitHub Actions CI**: Build and test workflow with lockfile enforcement

## High-leverage improvement areas (so we can act quickly later)
### Correctness / reliability
- **Fix `currentIndex` sentinel handling** (round-trip `null` cleanly instead of using 10000).
- **Fix cookie capture timing bug**: use the `url` parameter passed into `onLoadStop` instead of stale `currentUrl`.
- **Fix cookie SameSite serialization**: key `"sameSite?.toValue()"` is invalid; should be `"sameSite"`.
- **Fix find toolbar constructor syntax**: remove parentheses from `required this.onClose()`.
- **Harden find toolbar null-safety**: either make `webViewController` non-null or add null checks before force-unwrapping.

### Performance
- **Cache favicon URL resolution** (store per-site once; avoid repeated `http.get` probes on every drawer rebuild).
- **Reduce rebuild triggers in drawer list tiles** (avoid repeating async work on reorder/scroll).
- **Consider lazy webview creation**: `IndexedStack` keeps all webviews mounted; with many sites, memory usage grows unbounded. Consider disposing off-screen webviews or lazy-loading them.

### UX
- **Better "No site selected" empty state** (call-to-action, onboarding for new users).
- **Allow resetting user agent to default** (and persist that decision; currently can't clear a custom UA by saving empty string).
- **Consider a tab switcher UI** in addition to drawer (quick switching without opening/closing drawer).
- **Add webview back-button handling**: intercept back button to navigate backward within the active webview before exiting app.

### Security / privacy clarity
- Make cookie behavior explicit (what’s stored, where, and how “clear cookies” works).
- Improve domain isolation using a public-suffix aware approach (if desired).

### Platform modernization
- **Raise Android `targetSdkVersion`** (currently 28; should target 33+ for modern Play Store requirements).
- **Update dependency versions**: some packages may have newer versions with bug fixes (especially `flutter_inappwebview`).
- **Consider adding iOS support** (only Android + Linux currently present).

## Linux Desktop Webview: Research & Alternatives

### The Problem
**`flutter_inappwebview` does NOT support Linux desktop platforms** (as of January 2026). The current codebase will fail to run webviews on Linux despite having a `linux/` directory structure. The Android + mobile-focused implementation cannot be used on desktop.

### Flutter-Native Alternatives (drop-in or near-drop-in replacements)

#### 1. **`flutter_linux_webview`** (by ACCESS Co., Ltd.)
- **Status**: Available on pub.dev, actively maintained
- **Backend**: Chromium Embedded Framework (CEF)
- **Architecture support**: x86_64 and arm64
- **Key features**:
  - Implements `webview_flutter` 3.0.4 interface
  - Automatically downloads appropriate CEF binary on first build
  - JavaScript execution, cookie management, page navigation
  - Multiple webview widget support
- **Pros**:
  - Most compatible with existing `webview_flutter` code patterns
  - No manual CEF bundle management required
  - Embedded Linux device support
- **Cons**:
  - **Stability issues reported**: webview creation can hang/crash on some platforms (Flutter 3.16.3+)
  - GL context threading issues (accessing same context from multiple threads)
  - Less battle-tested than mobile webview implementations
- **Migration effort**: LOW (similar API surface to webview_flutter)
- **GitHub**: https://github.com/access-company/flutter_linux_webview

#### 2. **`webview_cef`** (by hlwhl)
- **Status**: Under active development, APIs not yet stable
- **Backend**: Chromium Embedded Framework (CEF)
- **Platforms**: Windows 7+, macOS 10.12+, Linux (x64 + arm64)
- **Key features**:
  - Multi-instance support
  - IME (Input Method Editor) support for third-party IMEs
  - Mouse events, JavaScript bridge
  - Cookie manipulation
  - DevTools support
- **Pros**:
  - Cross-platform (one codebase for Windows/macOS/Linux desktop)
  - Feature-rich (more control than typical mobile webview plugins)
  - Active development
- **Cons**:
  - **APIs are unstable** (breaking changes expected)
  - Requires platform-specific setup (especially macOS: manual CEF bundle download)
  - More complex than mobile webview plugins
- **Migration effort**: MEDIUM (different API, requires refactoring `WebViewModel` logic)
- **GitHub**: https://github.com/hlwhl/webview_cef
- **pub.dev**: https://pub.dev/packages/webview_cef

#### 3. **`webview_win_floating`**
- **Status**: Available, implements `webview_flutter` interface
- **Backend**: 
  - Linux: WebKit2GTK-4.1
  - Windows: WebView2
- **Key features**:
  - High FPS performance
  - Fullscreen support
  - Compatible with `webview_flutter` interface
- **Pros**:
  - Native WebKitGTK on Linux (smaller footprint than CEF)
  - Good performance for video playback / scrolling
  - Familiar API (webview_flutter interface)
- **Cons**:
  - **Webview overlays Flutter canvas** (Flutter widgets cannot appear above webview)
  - Focus switching limitations (Tab key behavior)
  - Clipping issues in scrollable widgets
  - **Less suitable for multi-webview UX** like Webspace's drawer navigation
- **Migration effort**: LOW-MEDIUM (API compatible, but overlay constraints break current UX)
- **pub.dev**: https://pub.dev/packages/webview_win_floating

### Alternative Frameworks (non-Flutter solutions)

#### 4. **Tauri** (Rust + Web)
- **Status**: Mature, production-ready
- **Stack**: Rust backend + JavaScript/TypeScript frontend
- **WebView**: Uses OS-native webview (WebKitGTK on Linux)
- **Platforms**: Linux, macOS, Windows, Android, iOS
- **Pros**:
  - Very lightweight (smaller binaries than Electron)
  - Strong security model
  - Excellent performance
  - Large, active community
- **Cons**:
  - **Complete rewrite required** (abandon Flutter, move to Rust + web frontend)
  - Learning curve for Rust
  - No Dart/Flutter code reuse
- **Migration effort**: VERY HIGH (full rewrite)
- **Website**: https://tauri.app/

#### 5. **Electron** (Chromium + Node.js)
- **Status**: Very mature, industry standard
- **Stack**: Chromium + Node.js + JavaScript/HTML/CSS
- **Platforms**: Linux, macOS, Windows
- **Pros**:
  - Battle-tested (VSCode, Slack, Discord, etc.)
  - Huge ecosystem
  - Extensive documentation
- **Cons**:
  - **Large bundle sizes** (100MB+ base)
  - **High memory usage** (each app bundles full Chromium)
  - **Complete rewrite required**
- **Migration effort**: VERY HIGH (full rewrite)
- **Website**: https://www.electronjs.org/

### Recommendation for Webspace App

**Short-term (MVP Linux support):**
1. **Try `flutter_linux_webview` first** (if stability issues aren't blockers on your target distro)
   - Least invasive change
   - Keep existing Flutter codebase
   - Monitor for GL context crashes; may require single-webview-at-a-time workaround
   
2. **Fallback to `webview_cef`** (if `flutter_linux_webview` is unstable)
   - More work but more control
   - Better long-term cross-desktop story
   - Prepare for API churn

**Long-term (production-grade):**
- If Linux desktop becomes a primary target and Flutter plugin ecosystem remains immature:
  - Consider **Tauri** for a clean rewrite with better webview support
  - Keep Flutter for Android, use Tauri for desktop (maintain two codebases)

**Not recommended:**
- `webview_win_floating`: overlay model breaks Webspace's multi-site drawer UX
- Electron: overkill for this use case; defeats Flutter's purpose

### Implementation Notes for Flutter Linux Webview Migration

When migrating to a Linux-compatible webview plugin:

1. **Conditional plugin loading**: Use platform checks to load `flutter_inappwebview` on Android and a Linux-specific plugin on Linux.
2. **Abstract webview interface**: Create a `PlatformWebView` abstraction layer in `WebViewModel` to hide platform differences.
3. **Test GL context issues**: If using `flutter_linux_webview`, test with multiple simultaneous webviews in `IndexedStack`.
4. **Cookie manager compatibility**: Verify cookie serialization/deserialization works with CEF's cookie APIs (different from mobile).
5. **Developer tools**: CEF-based solutions offer better DevTools integration than mobile webviews.

### Quick-Start Guide: Adding `flutter_linux_webview`

**Step 1: Update `pubspec.yaml`**
```yaml
dependencies:
  flutter:
    sdk: flutter
  flutter_inappwebview: ^5.7.2+3  # Keep for Android
  webview_flutter: ^3.0.4         # Interface
  
  # Add for Linux support:
  flutter_linux_webview:
    git:
      url: https://github.com/access-company/flutter_linux_webview.git
```

**Step 2: Create Platform Abstraction**
Create `lib/platform_webview.dart`:
```dart
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;

bool get isLinuxDesktop => !kIsWeb && Platform.isLinux;
bool get isAndroid => !kIsWeb && Platform.isAndroid;

// Use this to conditionally import and initialize the right webview plugin
```

**Step 3: Modify `WebViewModel`**
- Add platform checks before creating `InAppWebView` widgets
- For Linux: use `webview_flutter` with `flutter_linux_webview` backend
- For Android: continue using `flutter_inappwebview`

**Step 4: Test Strategy**
- Test with 1 webview first (verify basic functionality)
- Gradually add more webviews to IndexedStack
- Monitor for crashes/hangs (GL context issues)
- If unstable: consider lazy-loading webviews (dispose off-screen ones)

**Step 5: Linux System Dependencies**
On Linux, CEF will be auto-downloaded, but ensure these are installed:
```bash
sudo apt-get install libgtk-3-dev libnss3 libnspr4 libatk1.0-0 \
  libatk-bridge2.0-0 libcups2 libdrm2 libxkbcommon0 libxcomposite1 \
  libxdamage1 libxfixes3 libxrandr2 libgbm1 libpango-1.0-0 libcairo2 \
  libasound2
```

## Quick mental map of files

### Core
- `lib/main.dart`: App shell, webspaces management, drawer UI, persistence, theming
- `lib/webspace_model.dart`: Webspace data model with UUID-based identification
- `lib/web_view_model.dart`: Per-site model, webview creation, navigation policy, cookie/proxy handling

### Screens
- `lib/screens/webspaces_list.dart`: Main webspaces screen with selection
- `lib/screens/webspace_detail.dart`: Edit webspace details and site assignments
- `lib/screens/add_site.dart`: Add URL screen
- `lib/screens/settings.dart`: Per-site settings screen (proxy, UA, cookies)
- `lib/screens/inappbrowser.dart`: External link webview screen

### Platform Abstraction
- `lib/platform/platform_info.dart`: Platform detection and capability checks
- `lib/platform/unified_webview.dart`: Unified cookie and proxy management
- `lib/platform/webview_factory.dart`: Platform-specific webview creation

### Widgets & Settings
- `lib/widgets/find_toolbar.dart`: In-page search UI
- `lib/settings/proxy.dart`: Proxy settings data model (ProxyType, UserProxySettings)

### Tests
- `test/webspace_model_test.dart`: Webspace model tests
- `test/proxy_test.dart`: Proxy unit tests
- `test/platform_test.dart`: Platform abstraction tests
- `test/web_view_model_test.dart`: WebViewModel tests (currently stubbed)

