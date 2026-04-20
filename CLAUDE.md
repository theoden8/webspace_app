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
| fullscreen-mode | Full screen mode: hide app bar/tab strip/system UI, per-site auto-fullscreen setting |

Read the relevant spec before modifying a feature. Specs include file paths, data models, and manual test procedures.

## Adding a new global app setting

Any user-facing global toggle/preference persisted to `SharedPreferences` MUST be routed through the export/import registry, otherwise it silently drops out of user backups.

- Add the pref key + default value to `kExportedAppPrefs` in [lib/settings/app_prefs.dart](lib/settings/app_prefs.dart). That is the single source of truth for which global prefs round-trip through backup files.
- The integrity test in [test/settings_backup_test.dart](test/settings_backup_test.dart) ("every registered key round-trips through export and import") iterates `kExportedAppPrefs` and will exercise the new key automatically — no test edit required for scalar types already covered (`bool`, `int`, `double`, `String`, `List<String>`).
- Do NOT add per-pref parameters to `SettingsBackupService.createBackup` / `exportAndSave`. `main.dart` already calls `readExportedAppPrefs(prefs)` for export and `writeExportedAppPrefs(prefs, backup.globalPrefs)` for import.
- Do NOT add keys to the registry for: migration flags, download timestamps, cache indices, or machine state tied to downloaded data (DNS blocklist, content blocker lists, localcdn). Those are not user intent.
- Per-site settings (anything serialized on `WebViewModel.toJson`) are carried via the `sites` array automatically — keep them on the model, not in the global registry.

When you touch the export/import code path for any reason, re-run `flutter test test/settings_backup_test.dart` before committing.

## Per-site toggles that depend on downloaded data

Some features (DNS blocklist, content blocker, LocalCDN) require a downloaded blob before the per-site toggle does anything. Gate the per-site `SwitchListTile` on the service's readiness so users can't flip it on while the backing data is empty:

- Pattern: `onChanged: SomeService.instance.isReady ? (v) => ... : null` — a null `onChanged` grays out the switch.
- Update the subtitle to hint the user to populate the data first when the service is not ready.
- Examples in [lib/screens/settings.dart](lib/screens/settings.dart): DNS blocklist gates on `DnsBlockService.instance.hasBlocklist`; content blocker gates on `ContentBlockerService.instance.hasRules`; LocalCDN gates on `LocalCdnService.instance.hasCache`.

## Simulator engine vs. rendering engine

Orchestration logic — "which sites to unload on a webspace switch", "how do indices shift after a deletion", "what cookies move where during site activation" — belongs in a pure-Dart **simulator engine** under `lib/services/*_engine.dart`, not inlined in `_WebSpacePageState`. The template is [lib/services/cookie_isolation.dart](lib/services/cookie_isolation.dart): the engine takes mutable state as parameters, depends only on abstract I/O interfaces (`CookieManager`, `CookieSecureStorage`), and is invoked from `main.dart` as a thin call site. The **rendering engine** (native webview, platform channels, UI setState) stays at the call site.

Rules of thumb:

- If a function mutates `_webViewModels`/`_loadedIndices`/`_webspaces` with more than one line of index arithmetic, it belongs in an engine.
- If a function awaits a native call (`cookieManager.*`, `HtmlCacheService.*`) and then mutates shared state with logic that could differ per scenario, the logic part belongs in an engine.
- Engines never import `package:flutter/material.dart`, never call `setState`, never touch `context`. If they need an I/O boundary that's not yet abstracted, add the interface on the existing service (e.g. `CookieManager`) rather than reaching into the concrete type.
- Version guards (race protection) are passed in as `(versionAtEntry, int Function() currentVersion)` so the engine can bail between awaits without knowing about widget state.
- Tests import the engine directly and supply in-memory fakes that **model the interface** (e.g. `MockCookieManager` modeling RFC 6265 domain-match), not trivial stubs. See [test/cookie_isolation_integration_test.dart](test/cookie_isolation_integration_test.dart) for the pattern.

## DRY: tests delegate, don't reimplement

If a test harness re-implements production orchestration (its own `switchToSite`/`deleteSite`), that's a design smell pointing at an un-extracted engine. The harness should be a thin dispatcher that delegates to the real engine — the tests then exercise production code, not a parallel implementation that can drift. Example: [test/cookie_isolation_integration_test.dart:174-238](test/cookie_isolation_integration_test.dart) wraps `CookieIsolationEngine` without re-implementing the capture-nuke-restore dance. If you find yourself re-writing a flow in a test, stop and extract an engine first.

## Code flows new → stable

When adding a feature, extend the relevant engine (or introduce a new one alongside) rather than inlining a feature-specific branch into stable call sites. Corollary: never copy stable engine logic down into a new-feature codepath — that's how parallel implementations appear and silently diverge. If a new feature needs orchestration, it graduates into the engine layer before it ships; the stable engine doesn't fork to accommodate it. A `_WebSpacePageState` method should read as a sequence of engine calls + persistence/UI side-effects, with the "why" in the engine and the "where in the widget tree" at the call site.

## UI Race Conditions

Async event handlers in the UI (e.g. button callbacks, `onPopInvokedWithResult`, gesture handlers) can be invoked multiple times before the first invocation completes. Always review UI code changes for race conditions:

- **Rapid input**: Users can tap/press buttons faster than async operations resolve. If a handler does `await` before acting, a second invocation can enter the same handler concurrently.
- **Guard pattern**: Use a boolean flag (e.g. `_isHandling`) to drop concurrent invocations. Always clear the flag in a `finally` block.
- **State between await gaps**: After any `await`, re-check assumptions — widget may have unmounted (`if (!mounted) return;`), indices may have changed, or another handler may have mutated shared state.
- **Drawer/dialog flash**: Opening UI in an async callback without a guard can cause a second press to immediately close it, producing a visible flash.
