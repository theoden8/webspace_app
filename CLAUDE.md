# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Git Rules

- **NEVER push directly to master.** Always create a feature/fix branch and push there.
- Always use `git pull --rebase` when pulling.
- **Before pushing to a branch, check if it still exists on the remote.** If it was already merged and deleted, create a new branch from master instead.

## Project Overview

WebSpace is a Flutter app for managing multiple websites in a single interface with per-site cookie isolation. It uses flutter_inappwebview for webview functionality. Platforms: iOS, Android, macOS, Linux (WPE WebKit via the WebSpace fork).

## Sandbox bootstrap

Fresh sandboxes (Claude Code on the web, ephemeral CI runners) ship without `fvm`/Flutter and may not have `nvm`/Node either. Bootstrap before running any of the commands below — none of them work without the toolchain.

```bash
# fvm — required (project pins Flutter via .fvmrc)
curl -fsSL https://fvm.app/install.sh | bash
export PATH="$HOME/fvm/bin:$PATH"   # also append to ~/.bashrc
fvm install                         # honors .fvmrc (Flutter 3.38.6)

# nvm + Node — only if a script under scripts/ or tool/ needs Node and `node` isn't already on PATH
curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
nvm install --lts
```

If `command -v fvm` already prints a path, skip the fvm block. Same for `command -v node`. Don't reinstall on every turn — the cache survives.

## Build & Development Commands

This project uses [FVM](https://fvm.app/) for Flutter version management. Always prefix Flutter/Dart commands with `fvm`:

```bash
# Install dependencies
fvm flutter pub get

# Run tests
fvm flutter test                           # All Dart tests
fvm flutter test test/cookie_isolation_test.dart  # Single test file
npm run test:js                            # Node-side JS shim tests
./scripts/test_all.sh                      # Both layers (Dart + Node)

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
- **Per-site cookie isolation (two engines, runtime-selected)**: Two engines coexist; `_WebSpacePageState` caches `bool _useContainers = await ContainerNative.isSupported()` at startup and gates the entire isolation code path on it.
  - **Container path** (Android System WebView 110+, iOS 17+, macOS 14+, Linux WPE WebKit 2.40+): each `siteId` maps to a native container (`androidx.webkit.Profile` on Android, `WKWebsiteDataStore(forIdentifier:)` on Apple, `WebKitNetworkSession` cached per id under `<XDG_DATA_HOME>/flutter_inappwebview/containers/ws-<siteId>/` on Linux) named `ws-<siteId>` that owns its own cookies, `localStorage`, IDB, ServiceWorkers, and HTTP cache. Same-base-domain sites can be loaded concurrently; no conflict-unload, no capture-nuke-restore. Engine: [`ContainerIsolationEngine`](lib/services/container_isolation_engine.dart). Native bridge: [`ContainerNative`](lib/services/container_native.dart). All lifecycle ops (delete, list) route through the fork's [`inapp.ContainerController`]; only the `MULTI_PROFILE` runtime feature gate on Android lives in our [`WebSpaceContainerPlugin.kt`](android/app/src/main/kotlin/org/codeberg/theoden8/webspace/WebSpaceContainerPlugin.kt). The bind happens during `InAppWebView.prepare()` / `preWKWebViewConfiguration` / Linux's `webkit_web_view_set_property("network-session", ...)`, driven by the stock [`inapp.InAppWebViewSettings.containerId`] field set by `WebViewFactory.createWebView` (see `dependency_overrides` in [pubspec.yaml](pubspec.yaml)). Spec: [openspec/specs/per-site-containers/spec.md](openspec/specs/per-site-containers/spec.md).
  - **Legacy path** (Windows, web, or any platform where the fork's `ContainerController.isClassSupported` returns false): sites with matching base domains cannot be loaded simultaneously; switching unloads the conflicting site and runs capture-nuke-restore on the shared cookie jar. Engine: [`CookieIsolationEngine`](lib/services/cookie_isolation.dart). Spec: [openspec/specs/per-site-cookie-isolation/spec.md](openspec/specs/per-site-cookie-isolation/spec.md).
- **Lazy webview loading**: Webviews only created when visited (`_loadedIndices` tracks loaded sites)
- **Demo mode**: `isDemoMode` flag prevents persistence, uses seeded demo data

### flutter_inappwebview fork

Per-site profile isolation and per-site iOS/macOS proxy require APIs not present in upstream `flutter_inappwebview`. We pull a fork that adds them as a first-class "containers" API. The fork's monorepo lives at <https://github.com/theoden8/flutter_inappwebview>; `dependency_overrides` in [pubspec.yaml](pubspec.yaml) pin every platform plugin (and `_platform_interface`) to the same git ref. `flutter pub get` resolves the fork like any other git dependency — no bootstrap step, no patches to apply. Pub caches the checkout under `~/.pub-cache/git/`.

The fork ref is currently a mutable branch; tag it before each release and pin `ref:` to the tag so CI builds don't drift. Surface area touched in the fork is searchable in the cached checkout via `grep -rn '\[WebSpace fork patch\]' ~/.pub-cache/git/flutter_inappwebview-*/`.

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
| downloads | Webview-initiated downloads (http/https/data/blob) with streamed progress + save dialog |
| home-shortcut | Android home screen shortcut for sites via pinned shortcuts API |
| icon-fetching | Progressive favicon loading with fallbacks |
| ios-universal-link-bypass | iOS-only: cancel + reissue gesture-rooted main-frame http(s) navigations to silently bypass apple-app-site-association auto-routing into native apps |
| ip-leakage | Proxy coverage contract: every Dart-side outbound seam, fail-closed-on-SOCKS5, WebRTC + DNS posture |
| js-shim-tests | Behavioural Node-side tests for injected JS shims (jsdom + node:test), with Dart drift check on dumped fixtures |
| language | Per-site language: Accept-Language header + DOCUMENT_START navigator.language / Intl override |
| lazy-webview-loading | On-demand webview creation, IndexedStack placeholders |
| localcdn | LocalCDN - cache CDN resources locally to prevent CDN tracking (Android) |
| navigation | Back gesture, home button, drawer swipe, pull-to-refresh, platform quirks, race condition guards |
| nested-url-blocking | Cross-domain navigation control: nested InAppBrowser, gesture-based auto-redirect blocking |
| per-site-cookie-isolation | Cookie isolation via domain conflict detection, siteId storage (legacy / fallback engine) |
| per-site-containers | Native per-site containers via `androidx.webkit.Profile` (Android, System WebView 110+) and `WKWebsiteDataStore(forIdentifier:)` (iOS 17+ / macOS 14+); supersedes per-site-cookie-isolation when supported |
| passkey-support | WebAuthn/passkey authentication via JS polyfill + Android Credential Manager (iOS pending) |
| per-site-location | Per-site geolocation spoofing, IANA timezone override, WebRTC leak lockdown |
| platform-support | Platform abstraction layer for iOS, Android, macOS |
| proxy | Per-site HTTP/HTTPS/SOCKS5 proxy (Android only) |
| proxy-password-secure-storage | Per-site & global proxy passwords held in flutter_secure_storage, never serialised to JSON; stripped from settings backups (parity with `isSecure=true` cookies) |
| screenshots | Automated screenshot generation via integration tests |
| settings-backup | JSON import/export of all settings |
| site-editing | Edit site URLs and custom names |
| user-scripts | Per-site custom JavaScript injection with injection timing control |
| webspaces | Site organization into named collections |
| webview-hints | Webview theme hints (color-scheme, matchMedia, cache theme prelude) |
| webview-pause-lifecycle | Per-instance vs process-global webview pause; "paused != frozen" caveat |
| fullscreen-mode | Full screen mode: hide app bar/tab strip/system UI, per-site auto-fullscreen setting |
| desktop-mode | Desktop layout inferred from per-site UA (no toggle); JS shim for navigator.userAgentData / maxTouchPoints / pointer-media / `<meta name=viewport>` rewrite |

Read the relevant spec before modifying a feature. Specs include file paths, data models, and manual test procedures.

## JS shim tests (jsdom + node:test)

JavaScript shims injected into webviews (desktop-mode, geolocation/timezone/WebRTC, etc.) have **two** test layers:

- **Dart-side**: existing tests in `test/*_test.dart` assert the builder's *string output* (e.g. `expect(js, contains('Win32'))`). Cheap, but only catches absent substrings.
- **Node-side**: `test/js/*.test.js` runs the dumped shim in jsdom and asserts the *post-injection JS state* (e.g. `navigator.platform === 'Linux x86_64'`, `new RTCPeerConnection({}).iceTransportPolicy === 'relay'`). Catches mistakes the string check misses (typos in property names, wrong defineProperty target, broken matchMedia wrapper).

The two layers share fixtures under `test/js_fixtures/` — see [test/js_fixtures/README.md](test/js_fixtures/README.md). Workflow:

1. Edit a shim builder in `lib/services/`.
2. `fvm dart run tool/dump_shim_js.dart` regenerates fixtures.
3. `fvm flutter test test/js_fixtures_drift_test.dart` proves committed fixtures match the builder.
4. `npm run test:js` proves the shim actually mutates the JS surface.

Both layers run in CI (`build-and-test.yml` — the Node tests run early in the `Build Linux` job before the Flutter build; the drift check runs as part of the regular `flutter test` step).

To add a new shim to the Node-side suite: register it in `buildAllFixtures()` in [tool/dump_shim_js.dart](tool/dump_shim_js.dart), regenerate, then write a `*.test.js` against the new fixture. Builders that depend on Flutter widget imports (anything in `lib/main.dart` or `lib/screens/*`) can't be reached from the dumper as-is — extract the JS string into a pure-Dart helper first.

jsdom does not implement canvas/WebGL/audio fingerprinting. Tests assert override **shape** (constructor replaced, getter defined), not real-engine behaviour. For end-to-end privacy proofing against a real fingerprint detector (CreepJS, fingerprintjs), a Playwright-based Tier 2 is the natural follow-up — not yet built.

## Fastlane changelogs

Files under `fastlane/metadata/android/en-US/changelogs/<N>.txt` (and the sibling `short_description.txt` / `full_description.txt`) are subject to Play Store / F-Droid length caps: **changelog and full description max 500 bytes, short description max 80 bytes (no trailing dot)**. Always run [scripts/validate_fastlane_metadata.sh](scripts/validate_fastlane_metadata.sh) before committing any change to those files — an oversize changelog will silently break F-Droid metadata sync. The script exits non-zero on any violation.

## Adding a new global app setting

Any user-facing global toggle/preference persisted to `SharedPreferences` MUST be routed through the export/import registry, otherwise it silently drops out of user backups.

- Add the pref key + default value to `kExportedAppPrefs` in [lib/settings/app_prefs.dart](lib/settings/app_prefs.dart). That is the single source of truth for which global prefs round-trip through backup files.
- The integrity test in [test/settings_backup_test.dart](test/settings_backup_test.dart) ("every registered key round-trips through export and import") iterates `kExportedAppPrefs` and will exercise the new key automatically — no test edit required for scalar types already covered (`bool`, `int`, `double`, `String`, `List<String>`).
- Do NOT add per-pref parameters to `SettingsBackupService.createBackup` / `exportAndSave`. `main.dart` already calls `readExportedAppPrefs(prefs)` for export and `writeExportedAppPrefs(prefs, backup.globalPrefs)` for import.
- Do NOT add keys to the registry for: migration flags, download timestamps, cache indices, or machine state tied to downloaded data (DNS blocklist, content blocker lists, localcdn). Those are not user intent.
- Per-site settings (anything serialized on `WebViewModel.toJson`) are carried via the `sites` array automatically — keep them on the model, not in the global registry.

When you touch the export/import code path for any reason, re-run `flutter test test/settings_backup_test.dart` before committing.

## Adding a new credential / secret field

Anything that holds a credential, token, or other sensitive secret (proxy passwords, OAuth tokens, vault unlock material, …) MUST follow the contract documented in [openspec/specs/proxy-password-secure-storage/spec.md](openspec/specs/proxy-password-secure-storage/spec.md). Short version:

- **Storage**: live in `flutter_secure_storage` (Keychain / EncryptedSharedPrefs / libsecret), keyed by `siteId` for per-site fields and a fixed reserved key for global. Use `ProxyPasswordSecureStorage` as the template.
- **Never serialise to JSON**: `toJson` on the containing object simply omits the field — no `includeSecrets`-style opt-in. Same rule as `isSecure=true` cookies, which are also stripped from exports. The export format is a user-controlled JSON file the user might email or sync to cloud storage; it must not carry secrets.
- **Hydrate on load** alongside the existing per-site / global hydration in `_loadWebViewModels` and `GlobalOutboundProxy.initialize`.
- **Migrate legacy plaintext** with the idempotent pre-pass pattern in `ProxyPasswordSecureStorage.migrateLegacyPassword` — read prefs, move secret to secure storage, rewrite prefs without it.
- **Wire orphan cleanup** at the same three call sites that already sweep cookies + proxy passwords: startup GC, post-import GC, post-delete GC in [lib/main.dart](lib/main.dart).
- **Tell the user post-import** if the source backup had the related non-secret field set (e.g. `username` for proxy auth) — the snackbar hint in `_importSettings` is the model. Otherwise the user is silently surprised when the restored proxy starts failing auth.
- **Add a regression test** asserting the secret string never appears in `SettingsBackupService.exportToJson(...)` output. The "proxy passwords never appear in exports (PWD-005)" test in [test/settings_backup_test.dart](test/settings_backup_test.dart) is the template.
- **Update the spec** (this one if it's another proxy-related secret, otherwise a sibling spec) and re-run `npx openspec validate --no-interactive --all` before committing.

## Per-site toggles that depend on downloaded data

Some features (DNS blocklist, content blocker, LocalCDN) require a downloaded blob before the per-site toggle does anything. Gate the per-site `SwitchListTile` on the service's readiness so users can't flip it on while the backing data is empty:

- Pattern: `onChanged: SomeService.instance.isReady ? (v) => ... : null` — a null `onChanged` grays out the switch.
- Update the subtitle to hint the user to populate the data first when the service is not ready.
- Examples in [lib/screens/settings.dart](lib/screens/settings.dart): DNS blocklist gates on `DnsBlockService.instance.hasBlocklist`; content blocker gates on `ContentBlockerService.instance.hasRules`; LocalCDN gates on `LocalCdnService.instance.hasCache`.

## Per-site settings MUST apply to nested webviews

Per-site settings (cookie isolation flags, language, geolocation/timezone spoof, WebRTC policy, user scripts, content blocking, ClearURLs, DNS blocklist, desktop mode, etc.) apply to the parent webview *and* every nested webview spawned from it. Cross-domain navigations open a new `InAppWebViewScreen` via `launchUrl` in [lib/main.dart](lib/main.dart), which constructs its own `WebViewConfig` — that config MUST carry the parent site's per-site fields, otherwise the nested webview runs as a plain browser and any privacy property the user configured silently breaks in the one place a hostile site is most likely to test it (e.g. opening `browserleaks.com/webrtc` after following an outbound link).

When you add a new per-site field:

1. Add it to `WebViewModel.toJson`/`fromJson`.
2. Pass it into `WebViewConfig` at the main call site in `WebViewModel.getWebView` ([lib/web_view_model.dart](lib/web_view_model.dart)).
3. Add it to `launchUrl`'s signature in [lib/main.dart](lib/main.dart).
4. Add it to the `InAppWebViewScreen` constructor in [lib/screens/inappbrowser.dart](lib/screens/inappbrowser.dart) and pass it into that screen's `WebViewConfig` as well.
5. Update the `launchUrlFunc` typedef and both call sites in [lib/web_view_model.dart](lib/web_view_model.dart) that invoke it.

If a field controls JavaScript injected via `initialUserScripts`, also set `forMainFrameOnly: false` on the `inapp.UserScript` so the shim reaches cross-origin iframes (on iOS the default is main-frame-only). Otherwise a site can embed the detection logic in an iframe and bypass the shim.

## Logic engine vs. rendering engine

Orchestration logic — "which sites to unload on a webspace switch", "how do indices shift after a deletion", "what cookies move where during site activation" — belongs in a pure-Dart **logic engine** under `lib/services/*_engine.dart`, not inlined in `_WebSpacePageState`. The template is [lib/services/cookie_isolation.dart](lib/services/cookie_isolation.dart): the engine takes mutable state as parameters, depends only on abstract I/O interfaces (`CookieManager`, `CookieSecureStorage`), and is invoked from `main.dart` as a thin call site. The **rendering engine** (native webview, platform channels, UI setState) stays at the call site. "Logic" is literal — it's the same code path in production and tests; the split is strictly about separating orchestration from rendering so the former can run without a display.

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
