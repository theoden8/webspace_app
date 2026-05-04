# CLAUDE.md

WebSpace: Flutter app managing multiple websites with per-site cookie isolation via flutter_inappwebview. Platforms: iOS, Android, macOS, Linux (WPE WebKit fork).

## Style (output, code, commits)

- No preamble, no closing fluff, no em-dashes, no emoji.
- Code first; explain only the non-obvious.
- Default to **no code comments**. Only add when the *why* is non-obvious (hidden constraint, workaround for a specific bug, surprising behavior). Never restate what the code does. Never reference the current task or PR.
- Commit messages: short subject (<70 chars, imperative), 1-2 line body for the *why* if needed. No marketing prose, no bullet lists of every changed file, no "this commit also...".
- Don't speculate. Read the code or docs before asserting an API/version/flag.

## Git

- Never push to master. Branch first.
- `git pull --rebase` always.
- Before pushing a branch, check it still exists on remote; if merged+deleted, branch fresh from master.

## Sandbox bootstrap

Fresh sandboxes lack `fvm` and may lack `nvm`/Node. Skip a block if `command -v fvm` (or `node`) already prints a path — don't reinstall.

```bash
# fvm — required (.fvmrc pins Flutter 3.38.6)
curl -fsSL https://fvm.app/install.sh | bash
export PATH="$HOME/fvm/bin:$PATH"
fvm install

# nvm + Node — only if a script under scripts/ or tool/ needs Node
curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
nvm install --lts
```

## Commands

Prefix all Flutter/Dart with `fvm`.

```bash
fvm flutter pub get
fvm flutter test                                         # all Dart tests
fvm flutter test test/cookie_isolation_test.dart         # single file
npm run test:js                                          # JS shim tests (jsdom)
./scripts/test_all.sh                                    # Dart + JS
fvm flutter analyze
fvm flutter build apk    --flavor fdroid --release       # F-Droid (CI, unsigned)
fvm flutter build apk    --flavor fmain  --release --split-per-abi   # Play (signed)
fvm flutter build ipa    --release                       # iOS unsigned
fvm flutter build macos  --release
fvm flutter build linux  --release
fvm dart run flutter_launcher_icons
```

Android flavors: `fdroid` (CI), `fmain` (Play), `fdebug`.

## Architecture

**Models**
- `WebViewModel` ([lib/web_view_model.dart](lib/web_view_model.dart)) — site with URL, cookies, per-site settings (language, incognito, proxy, etc.). Unique `siteId` keys cookie isolation.
- `Webspace` ([lib/webspace_model.dart](lib/webspace_model.dart)) — named collection of site indices. `__all_webspace__` shows all.

**Main** — [lib/main.dart](lib/main.dart): `WebSpaceApp` (root MaterialApp) and `WebSpacePage` holding `_webViewModels`, `_webspaces`, `_loadedIndices`, isolation orchestration.

**Services** ([lib/services/](lib/services/)) — `cookie_secure_storage`, `html_cache_service` (AES, clears on upgrade), `icon_service`, `dns_block_service`, `webview` (CookieManager wrapper, WebViewTheme).

**Cookie isolation — two engines, runtime-selected.** `_WebSpacePageState` caches `bool _useContainers = await ContainerNative.isSupported()` at startup and gates the path.

- **Container engine** ([container_isolation_engine.dart](lib/services/container_isolation_engine.dart)) — Android System WebView 110+, iOS 17+, macOS 14+, Linux WPE WebKit 2.40+. Each `siteId` → native container `ws-<siteId>` (`androidx.webkit.Profile` / `WKWebsiteDataStore(forIdentifier:)` / `WebKitNetworkSession` cached under `<XDG_DATA_HOME>/flutter_inappwebview/containers/`) owning its cookies, localStorage, IDB, ServiceWorkers, HTTP cache. Same-base-domain sites load concurrently — no conflict-unload, no capture-nuke-restore. Bridge: [`ContainerNative`](lib/services/container_native.dart). Lifecycle ops route through fork's `inapp.ContainerController`; only the Android `MULTI_PROFILE` feature gate lives in [`WebSpaceContainerPlugin.kt`](android/app/src/main/kotlin/org/codeberg/theoden8/webspace/WebSpaceContainerPlugin.kt). Bind happens in `InAppWebView.prepare()` / `preWKWebViewConfiguration` / Linux `webkit_web_view_set_property("network-session", ...)`, driven by stock `inapp.InAppWebViewSettings.containerId` set by `WebViewFactory.createWebView`. Spec: [openspec/specs/per-site-containers/spec.md](openspec/specs/per-site-containers/spec.md).
- **Legacy engine** ([cookie_isolation.dart](lib/services/cookie_isolation.dart)) — Windows, web, anywhere `ContainerController.isClassSupported` is false. Sites with matching base domains can't load simultaneously; switching unloads the conflict and runs capture-nuke-restore on the shared cookie jar. Spec: [openspec/specs/per-site-cookie-isolation/spec.md](openspec/specs/per-site-cookie-isolation/spec.md).

**Other patterns** — Lazy webview loading (`_loadedIndices`); `isDemoMode` flag (no persistence, seeded data).

**flutter_inappwebview fork** — adds containers + per-site iOS/macOS proxy. Monorepo: <https://github.com/theoden8/flutter_inappwebview>. `dependency_overrides` in [pubspec.yaml](pubspec.yaml) pin every platform plugin to one git ref. Pub caches under `~/.pub-cache/git/`. Currently a mutable branch — tag it before each release. Surface area: `grep -rn '\[WebSpace fork patch\]' ~/.pub-cache/git/flutter_inappwebview-*/`.

**Persistence** — SharedPreferences for sites/webspaces/theme; cookies in flutter_secure_storage by `siteId`.

## Tests

Dart in `test/`, integration in `integration_test/` (screenshots).

## OpenSpec features

Specs live under `openspec/specs/<slug>/spec.md` (Given/When/Then). **Read the relevant spec before modifying a feature.** Slugs:

| Slug | One-liner (when not obvious) |
|------|------|
| captcha-support | |
| clearurls | tracking-param removal, per-site toggle |
| configurable-suggested-sites | empty default for fdroid |
| content-blocker | ABP filter lists (domain, CSS cosmetic, text-hide) |
| cookie-secure-storage | encrypted cookie persistence |
| desktop-mode | per-site UA → JS shim (userAgentData, maxTouchPoints, viewport rewrite) |
| developer-tools | JS console, cookie inspector, HTML export, app logs |
| dns-blocklist | Hagezi list, severity levels, per-site toggle |
| downloads | http/https/data/blob, streamed progress + save dialog |
| external-scheme-handling | intent:// auto-resolves to http(s) fallback (silent route); prompt only when no web equivalent |
| file-import-sites | local HTML via HtmlCacheService |
| fullscreen-mode | hide app bar/tab strip/system UI; per-site auto |
| home-shortcut | Android pinned shortcuts |
| icon-fetching | progressive favicon w/ fallbacks |
| ios-universal-link-bypass | cancel+reissue gesture http(s) navs to dodge AASA |
| ip-leakage | proxy coverage contract; fail-closed on SOCKS5; WebRTC + DNS |
| js-shim-tests | jsdom + node:test, with Dart drift check |
| language | Accept-Language + DOCUMENT_START navigator.language/Intl |
| integration-tests | flutter `integration_test/` harness conventions + headless Linux CI setup |
| lazy-webview-loading | on-demand creation, IndexedStack placeholders |
| localcdn | cache CDN resources locally (Android) |
| navigation | back gesture, drawer swipe, refresh, race guards |
| nested-url-blocking | nested InAppBrowser, gesture auto-redirect block |
| per-site-cookie-isolation | legacy engine (fallback) |
| per-site-containers | native containers (preferred when supported) |
| per-site-location | geo + IANA tz override + WebRTC lockdown |
| platform-support | platform abstraction layer |
| proxy | per-site HTTP/HTTPS/SOCKS5; Android serialises mismatched-proxy sites |
| proxy-password-secure-storage | secrets in flutter_secure_storage; never in JSON |
| screenshots | integration-test driven |
| settings-backup | JSON import/export |
| site-editing | URL + custom name |
| tracking-protection | umbrella per-site ETP: forces ClearURLs/DNS/content blocker/LocalCDN + injects anti-fingerprinting shim (Canvas/WebGL/audio/fonts/screen/hardware/timing/clientrects) seeded by siteId |
| user-scripts | per-site JS injection w/ timing control |
| web-push-notifications | per-site `notificationsEnabled` toggle: JS Notification polyfill → flutter_local_notifications, auto-loads + skips per-instance pause for notif sites, iOS `beginBackgroundTask` grace window + `BGAppRefreshTask` opportunistic reload |
| webspaces | named site collections |
| webview-hints | color-scheme, matchMedia, theme prelude cache |
| webview-pause-lifecycle | per-instance vs process-global pause; "paused != frozen" |

## JS shim tests (jsdom + node:test)

Two layers, shared fixtures in `test/js_fixtures/` (see [README](test/js_fixtures/README.md)):

- **Dart** — `test/*_test.dart` asserts builder string output (cheap, only catches absent substrings).
- **Node** — `test/js/*.test.js` runs the dumped shim in jsdom, asserts post-injection JS state.

Workflow: edit shim in `lib/services/` → `fvm dart run tool/dump_shim_js.dart` → `fvm flutter test test/js_fixtures_drift_test.dart` (drift) → `npm run test:js` (behavior). Both run in CI (`build-and-test.yml`).

New shim: register in `buildAllFixtures()` in [tool/dump_shim_js.dart](tool/dump_shim_js.dart). Builders importing Flutter widgets (lib/main.dart, lib/screens/*) can't be reached — extract the JS string to a pure-Dart helper first.

jsdom has no canvas/WebGL/audio fingerprinting. Tests assert override **shape**, not engine behavior. Real-engine proofing (CreepJS, fingerprintjs) wants a Playwright tier — not built.

## Fastlane changelogs

Files under `fastlane/metadata/android/en-US/changelogs/<N>.txt` and sibling descriptions: **changelog + full description ≤ 500 bytes; short_description ≤ 80 bytes (no trailing dot)**. Run [scripts/validate_fastlane_metadata.sh](scripts/validate_fastlane_metadata.sh) before committing — oversize silently breaks F-Droid sync.

## Adding a new global app setting

User-facing global pref persisted to SharedPreferences MUST round-trip through the export/import registry, else it drops out of backups.

- Add key + default to `kExportedAppPrefs` in [lib/settings/app_prefs.dart](lib/settings/app_prefs.dart) (single source of truth).
- The integrity test in [test/settings_backup_test.dart](test/settings_backup_test.dart) iterates the registry — no test edit needed for `bool|int|double|String|List<String>`.
- Don't add per-pref params to `SettingsBackupService.createBackup`; main.dart already does `readExportedAppPrefs` / `writeExportedAppPrefs`.
- Don't register: migration flags, download timestamps, cache indices, machine state from downloaded data (DNS blocklist, content blocker, localcdn).
- Per-site settings ride `WebViewModel.toJson` automatically — keep them on the model.
- Touched export/import? Re-run `flutter test test/settings_backup_test.dart`.

## Adding a new credential / secret

Follow [openspec/specs/proxy-password-secure-storage/spec.md](openspec/specs/proxy-password-secure-storage/spec.md). Template: `ProxyPasswordSecureStorage`.

- **Storage**: `flutter_secure_storage`, keyed by `siteId` (per-site) or fixed reserved key (global).
- **Never serialise to JSON**: `toJson` omits the field. No `includeSecrets` opt-in. Same rule as `isSecure=true` cookies. Backup files get emailed/synced — they must not carry secrets.
- **Hydrate on load** alongside per-site/global hydration in `_loadWebViewModels` and `GlobalOutboundProxy.initialize`.
- **Migrate legacy plaintext** with the idempotent pre-pass in `ProxyPasswordSecureStorage.migrateLegacyPassword`.
- **Wire orphan cleanup** at the same three GC sites in [lib/main.dart](lib/main.dart): startup, post-import, post-delete.
- **Tell the user post-import** (snackbar in `_importSettings`) if the related non-secret field was set — otherwise restored proxy silently fails auth.
- **Regression test**: assert the secret string never appears in `SettingsBackupService.exportToJson(...)` output. Template: "proxy passwords never appear in exports (PWD-005)".
- Update the spec, then `npx openspec validate --no-interactive --all`.

## Per-site web push notifications

`notificationsEnabled` (per-site) folds three behaviors so a single user toggle keeps notifications reliable:

- **Polyfill**: JS `Notification` constructor + `requestPermission()` are polyfilled at `DOCUMENT_START` (`forMainFrameOnly: false`); calls bridge to `NotificationService` via `addJavaScriptHandler('webNotification', ...)`.
- **No per-instance pause**: `WebViewModel.pauseWebView()` early-returns for notification sites — iOS's `pauseTimers()` alert hack would freeze the JS thread between site switches and queue setTimeouts into one burst on resume.
- **Auto-load + retention priority**: notification sites are added to `_loadedIndices` on startup and tier `notification` in `SiteRetentionPriority` so OS memory pressure evicts other sites first.
- **iOS background contract** (NOTIF-005-I): `BackgroundTaskService` calls `UIApplication.beginBackgroundTask` on app-pause for a ~30s grace window and registers a `BGAppRefreshTask` (`org.codeberg.theoden8.webspace.notification-refresh`) that reloads notif sites opportunistically. Native bridge: [`ios/Runner/BackgroundTaskPlugin.swift`](ios/Runner/BackgroundTaskPlugin.swift). One-time iOS-limits info dialog is shown the first time the toggle flips on.

When adding a notification-related code path, prefer extending `NotificationService` / `BackgroundTaskService` over reaching into `_WebSpacePageState`.

## Per-site toggles backed by downloaded data

DNS blocklist, content blocker, LocalCDN need a downloaded blob. Gate the per-site `SwitchListTile` on the service's readiness:

- `onChanged: SomeService.instance.isReady ? (v) => ... : null` (null grays out the switch).
- Subtitle hints the user to populate first when not ready.
- See [lib/screens/settings.dart](lib/screens/settings.dart): `DnsBlockService.hasBlocklist`, `ContentBlockerService.hasRules`, `LocalCdnService.hasCache`.

## Per-site settings MUST apply to nested webviews

Cross-domain navs open a new `InAppWebViewScreen` via `launchUrl` in [lib/main.dart](lib/main.dart) with its own `WebViewConfig` — that config MUST carry every per-site field (cookie isolation, language, geo/tz, WebRTC, user scripts, content blocker, ClearURLs, DNS blocklist, desktop mode, …), or a hostile outbound link silently bypasses the user's privacy posture.

When you add a per-site field:

1. `WebViewModel.toJson`/`fromJson`.
2. `WebViewConfig` in `WebViewModel.getWebView` ([lib/web_view_model.dart](lib/web_view_model.dart)).
3. `launchUrl` signature in [lib/main.dart](lib/main.dart).
4. `InAppWebViewScreen` ctor in [lib/screens/inappbrowser.dart](lib/screens/inappbrowser.dart) + its `WebViewConfig`.
5. `launchUrlFunc` typedef + both call sites in [lib/web_view_model.dart](lib/web_view_model.dart).

If the field controls JS in `initialUserScripts`, set `forMainFrameOnly: false` (iOS default is main-frame-only) so the shim reaches cross-origin iframes.

## Logic engine vs rendering engine

Orchestration (which sites unload on switch, how indices shift after delete, what cookies move during activation) → pure-Dart engine in `lib/services/*_engine.dart`. Template: [cookie_isolation.dart](lib/services/cookie_isolation.dart). Native webview / platform channels / `setState` stays at the call site.

- Mutating `_webViewModels`/`_loadedIndices`/`_webspaces` with >1 line of index arithmetic? Engine.
- `await native_call` then mutate shared state with scenario-dependent logic? Engine.
- Engines never `import 'package:flutter/material.dart'`, never call `setState`, never touch `context`. Add interfaces on existing services (e.g. `CookieManager`) instead of reaching into concrete types.
- Race protection: pass `(versionAtEntry, int Function() currentVersion)` so the engine can bail without knowing about widget state.
- Tests import the engine directly with in-memory fakes that **model the interface** (e.g. `MockCookieManager` modeling RFC 6265 domain-match), not trivial stubs. See [test/cookie_isolation_integration_test.dart](test/cookie_isolation_integration_test.dart).

## DRY: tests delegate, don't reimplement

Test harness re-implementing `switchToSite`/`deleteSite` = un-extracted engine. Wrap the real engine; never re-write the flow in a test. See [test/cookie_isolation_integration_test.dart:174-238](test/cookie_isolation_integration_test.dart).

## Code flows new → stable

New features extend the engine (or add one alongside). Never inline a feature-specific branch into a stable call site; never copy stable engine logic into a new-feature path. A `_WebSpacePageState` method reads as engine calls + persistence/UI side-effects.

## UI race conditions

Async UI handlers (button callbacks, `onPopInvokedWithResult`, gestures) get re-entered before the first call resolves.

- **Rapid input**: a handler that `await`s before acting can be entered twice concurrently.
- **Guard**: boolean flag (`_isHandling`), cleared in `finally`.
- **State across awaits**: re-check `mounted`, indices, shared state — another handler may have mutated.
- **Drawer/dialog flash**: opening UI in an unguarded async callback lets a second tap close it immediately.
