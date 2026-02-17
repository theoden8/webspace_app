# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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
| per-site-cookie-isolation | Cookie isolation via domain conflict detection, siteId storage |
| lazy-webview-loading | On-demand webview creation, IndexedStack placeholders |
| cookie-secure-storage | Encrypted cookie persistence with flutter_secure_storage |
| nested-url-blocking | Cross-domain navigation opens in nested InAppBrowser |
| webspaces | Site organization into named collections |
| proxy | Per-site HTTP/HTTPS/SOCKS5 proxy (Android only) |
| settings-backup | JSON import/export of all settings |
| icon-fetching | Progressive favicon loading with fallbacks |
| clearurls | ClearURLs tracking parameter removal with per-site toggle |
| dns-blocklist | Hagezi DNS blocklist domain blocking with severity levels and per-site toggle |

Read the relevant spec before modifying a feature. Specs include file paths, data models, and manual test procedures.
