# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Git Rules

- **NEVER push directly to master.** Always create a feature/fix branch and push there.
- Always use `git pull --rebase` when pulling.
- **Before pushing to a branch, check if it still exists on the remote.** If it was already merged and deleted, create a new branch from master instead.

## Project Overview

WebSpace is a Flutter app for managing multiple websites in a single interface with per-site cookie isolation. It uses flutter_inappwebview for webview functionality. Platforms: iOS, Android, macOS (Linux pending flutter_inappwebview support).

## Build & Development Commands

This project uses [FVM](https://fvm.app/) for Flutter version management. Always prefix Flutter/Dart commands with `fvm`:

```bash
# Install dependencies
fvm flutter pub get

# Run tests
fvm flutter test                           # All tests
fvm flutter test test/cookie_isolation_test.dart  # Single test file

# Static analysis
fvm flutter analyze

# Build commands
fvm flutter build apk --flavor fdroid --release              # F-Droid release APK
fvm flutter build apk --flavor fmain --release --split-per-abi  # Signed release APKs
fvm flutter build ipa --release                              # iOS (unsigned)
fvm flutter build macos --release                            # macOS
fvm flutter build linux --release                            # Linux

# Generate launcher icons
fvm dart run flutter_launcher_icons
```

### Android Flavors
- `fdroid` - F-Droid release (unsigned, used in CI)
- `fmain` - Play Store release (requires signing key)
- `fdebug` - Debug flavor

## Architecture

### Core Data Models
- **WebViewModel** ([web_view_model.dart](lib/web_view_model.dart)) - Represents a site with URL, cookies, per-site settings (language, incognito, proxy). Each site has a unique `siteId` for cookie isolation.
- **Webspace** ([webspace_model.dart](lib/webspace_model.dart)) - A named collection of site indices. Special "All" webspace (id: `__all_webspace__`) shows all sites.

### Main Application
[main.dart](lib/main.dart) contains:
- `WebSpaceApp` - Root MaterialApp with theme management
- `WebSpacePage` - Main stateful widget managing all app state including:
  - Site list (`_webViewModels`)
  - Webspace list (`_webspaces`)
  - Lazy webview loading (`_loadedIndices`)
  - Per-site cookie isolation via domain conflict detection

### Services (lib/services/)
- **cookie_secure_storage.dart** - Encrypted cookie storage using flutter_secure_storage
- **html_cache_service.dart** - AES-encrypted HTML caching (clears on app upgrade)
- **icon_service.dart** - Favicon fetching and caching
- **dns_block_service.dart** - Hagezi DNS blocklist download, caching, and O(1) domain lookup
- **webview.dart** - CookieManager wrapper around flutter_inappwebview, WebViewTheme enum

### Key Patterns
- **Per-site cookie isolation**: Sites with matching base domains cannot be loaded simultaneously. When switching to a site, conflicting sites are unloaded and cookies saved.
- **Lazy webview loading**: Webviews only created when visited (`_loadedIndices` tracks loaded sites)
- **Demo mode**: `isDemoMode` flag prevents persistence, uses seeded demo data

### State Persistence
All state persisted via SharedPreferences (sites, webspaces, theme). Cookies stored separately in secure storage keyed by `siteId`.

## Testing

Test files in `test/` cover:
- Cookie isolation logic
- Settings backup/restore
- Webspace ordering
- Proxy configuration
- Theme handling

Integration tests in `integration_test/` for screenshot generation.

## Feature Specifications (OpenSpec)

Detailed feature specs are in `openspec/specs/`. Each spec uses Given/When/Then format with requirements, implementation details, and test instructions:

| Spec | Description |
|------|-------------|
| captcha-support | CAPTCHA detection and handling |
| clearurls | ClearURLs tracking parameter removal with per-site toggle |
| configurable-suggested-sites | Configurable suggested sites list with empty default for fdroid flavor |
| content-blocker | ABP filter list content blocking (domain, CSS cosmetic, text-based hiding) |
| file-import-sites | Import local HTML files as sites, rendered via HtmlCacheService |
| cookie-secure-storage | Encrypted cookie persistence with flutter_secure_storage |
| developer-tools | In-app dev tools: JS console, cookie inspector, HTML export, app logs |
| dns-blocklist | Hagezi DNS blocklist domain blocking with severity levels and per-site toggle |
| home-shortcut | Android home screen shortcut for sites via pinned shortcuts API |
| icon-fetching | Progressive favicon loading with fallbacks |
| lazy-webview-loading | On-demand webview creation, IndexedStack placeholders |
| localcdn | LocalCDN - cache CDN resources locally to prevent CDN tracking (Android) |
| navigation | Back gesture, home button, drawer swipe, pull-to-refresh, platform quirks, race condition guards |
| nested-url-blocking | Cross-domain navigation control: nested InAppBrowser, gesture-based auto-redirect blocking |
| per-site-cookie-isolation | Cookie isolation via domain conflict detection, siteId storage |
| platform-support | Platform abstraction layer for iOS, Android, macOS |
| proxy | Per-site HTTP/HTTPS/SOCKS5 proxy (Android only) |
| screenshots | Automated screenshot generation via integration tests |
| settings-backup | JSON import/export of all settings |
| site-editing | Edit site URLs and custom names |
| user-scripts | Per-site custom JavaScript injection with injection timing control |
| webspaces | Site organization into named collections |
| webview-hints | Webview theme and display hints |

Read the relevant spec before modifying a feature. Specs include file paths, data models, and manual test procedures.

## UI Race Conditions

Async event handlers in the UI (e.g. button callbacks, `onPopInvokedWithResult`, gesture handlers) can be invoked multiple times before the first invocation completes. Always review UI code changes for race conditions:

- **Rapid input**: Users can tap/press buttons faster than async operations resolve. If a handler does `await` before acting, a second invocation can enter the same handler concurrently.
- **Guard pattern**: Use a boolean flag (e.g. `_isHandling`) to drop concurrent invocations. Always clear the flag in a `finally` block.
- **State between await gaps**: After any `await`, re-check assumptions — widget may have unmounted (`if (!mounted) return;`), indices may have changed, or another handler may have mutated shared state.
- **Drawer/dialog flash**: Opening UI in an async callback without a guard can cause a second press to immediately close it, producing a visible flash.
