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
- **Don't commit derivatives.** If a file is the output of a script, parser, compiler, dumper, or any build step that reads from elsewhere — it doesn't belong in the repo. Commit the inputs (sources you author, pinned upstream refs) and the *runner* (build.rs, scripts, Cargo features); regenerate the output at build time into `$OUT_DIR`/`build/`/`target/`. Same applies to vendored third-party source: if a script can fetch + assemble it from upstream at a pinned ref, don't check the upstream tree in. Concrete check before staging: "could I delete this file and reproduce it by running one command from a clean clone?" — if yes, it's a derivative; ignore it. See `rust/webspace_adblock/build.rs` for an example.

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

## Recurring bugs (`docs/bugs/`)

A **recurring bug** is one whose symptom was fixed before and resurfaced through a
new code path (the fix was partial). When you hit one, do NOT just patch the new path
silently — record it so the next person sees the whole lineage and the still-open gaps.

- One file per bug, numbered: `docs/bugs/NNN-<slug>.md` (e.g. `001-white-screen.md`).
  Number bugs sequentially; the number is the bug's stable ID (`BUG-NNN`), used in the
  file header. Reuse the existing file when the same bug recurs — never start a new one.
- Each file has: the **symptom**, the **root mechanism / invariant** (why all instances
  share a cause), a numbered **chronological list of fix attempts**, and a **known open
  gaps** section.
- Every fix attempt entry MUST carry: a number, the **date** (`git show -s --date=short`),
  the PR/commit, **what it did**, **why** (the reasoning), and **why it was partial**
  (which path it covered and which it missed). Append a new entry per attempt; never
  rewrite history.
- This file is the bug's biography; the **spec** (`openspec/specs/.../spec.md`) still
  carries the normative requirement + regression scenario for each fix. Cross-link them.
- When a bug is genuinely closed for the whole class (not just one path), set the header
  `Status:` to `closed` and say what finally subsumed the per-path fixes.

GitHub issues/PRs track "what broke"; `docs/bugs/` tracks "every attempt and why each
was incomplete"; OpenSpec tracks "the behavior we now require". Keep all three in sync.

## Formal verification (`formal/`)

Defense-in-depth pipeline; each layer absorbs a class of issue before the next:
`spec → formal → engine → tests → app code → integration tests`. The **formal** layer
([formal/](formal/), TLA+ checked by TLC) catches what tests can't: design contradictions,
missing-transition classes, and cross-spec interference — bugs in the gaps *between* specs.

- `formal/kernel.tla` is the **cross-spec kernel**: only the specs that mutate *shared*
  runtime/persisted state get a module (owned vars, actions, invariant, rely/guarantee
  contract). Independent (leaf) specs share no state and compose for free — keep them OUT.
- Cite requirement IDs (`PAUSE-018`, `ARCH-001`, …) on the actions/properties that encode
  them so spec ↔ model stays grep-able.
- **Adding a spec that touches shared state → run the mix gate:** add its actions to `Next`
  and its property to the `.cfg`, then `./formal/check.sh`. A counterexample means it does
  not mix; the trace names the breaking interleaving. Fix the design, not the model.
- Standalone models (no shared kernel state) live beside the kernel: `archive.tla`
  (ARCH-001 byte-identity, a 2-safety hyperproperty via self-composition), `renderer.tla`
  (BUG-002 dead-renderer recovery), `proxy.tla` (mismatched-proxy mutual exclusion),
  `kiosk.tla` (KIOSK-001/002/003 locked-shell sealing).
- Each model carries **negative** demonstrators (a mutation that MUST be caught) and
  **positive** reachability witnesses (a legal behavior that MUST be reachable) — run by
  `./formal/check.sh`. `trace/` validates real `LogService` traces against the kernel's
  observable projection (the model↔code bridge).
- `formal/proofs/` holds **unbounded TLAPS proofs** (machine-checked by `tlapm`): every
  kernel safety invariant *and* the surface-repaint liveness `RepaintLiveness` for all N,
  not just TLC's N = 3. Run via `proofs/check_proofs.sh` (in the `validate` CI job).
- A bug's recurrence is also gated in **code**: structural Node tests under `test/js/`
  (`surface_repaint_funnel`, `renderer_gone_recovery`) fail CI if a new path skips the fix.
- Don't commit `tla2tools.jar`, `states/`, `.tlacache/`, or generated `mc_*.tla` (derivatives).
- Full method + the new-spec workflow: [formal/README.md](formal/README.md).

## OpenSpec features

Specs live under `openspec/specs/<slug>/spec.md` (Given/When/Then). **Read the relevant spec before modifying a feature.** Slugs:

| Slug | One-liner (when not obvious) |
|------|------|
| captcha-support | |
| clearurls | tracking-param removal, per-site toggle |
| configurable-suggested-sites | empty default for fdroid |
| content-blocker | ABP filter lists via adblock-rust (network, cosmetic, procedural, $redirect/$csp/$removeparam) |
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
| kiosk-mode | per-site toggle; shortcut launch opens chrome-less (no drawer/tab strip/menus/settings), plain app launch restores access; no passphrase |
| language | Accept-Language + DOCUMENT_START navigator.language/Intl |
| localization | UI strings via gen_l10n ARB; no-unkeyed-text guard; coverage parity tests |
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
| user-agent-identity | engine-consistent navigator identity for the per-site UA (vendor/productSub/oscpu/buildID/platform/userAgentData); complements desktop-mode |
| user-scripts | per-site JS injection w/ timing control |
| web-push-notifications | per-site `notificationsEnabled` toggle: JS Notification polyfill → flutter_local_notifications, auto-loads + skips per-instance pause for notif sites, iOS `beginBackgroundTask` grace + `BGAppRefreshTask` reload, Android mirrors via `WorkManager` periodic refresh (no foreground service) |
| archive | passphrase-gated archived webspaces in a fixed slot pool; active state stays byte-identical when no archive is open |
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

## Adding user-facing strings (localization)

Spec: [openspec/specs/localization/spec.md](openspec/specs/localization/spec.md). UI strings go through `gen_l10n` ARB, never hardcoded literals.

- Add the key + a non-empty `description` (and `placeholders` for interpolation) to [lib/l10n/app_en.arb](lib/l10n/app_en.arb). Reference it via `AppLocalizations.of(context).<key>`.
- Generated code lives in `lib/l10n/gen/` and is **gitignored** — regenerated by `generate: true` on `pub get`/build, or `fvm flutter gen-l10n`. Don't commit it.
- Pure-data display (e.g. `host:port`) goes into a local variable first; never a string literal inside `Text(`/`tooltip:` etc., or the LOC-002 guard fails.
- Migration is phased: when you finish routing a file's strings, move it from `pending` to `migrated` in [test/js/l10n_no_hardcoded_text.test.js](test/js/l10n_no_hardcoded_text.test.js). A new UI file under `lib/{main.dart,screens,widgets}` must be classified in that test or it fails.
- Every key MUST carry a non-empty `description` (enforced by [test/js/l10n_coverage.test.js](test/js/l10n_coverage.test.js)) — that description is the context a translator/general model uses, so write it for someone who can't see the screen.
- To add a locale: hand `app_en.arb` (values + descriptions) to any general-purpose model, ask it to translate the values keeping `{placeholder}` tokens verbatim, save as `app_<locale>.arb`. No committed script or API key. Coverage (key + placeholder parity, no empties) is enforced by [test/js/l10n_coverage.test.js](test/js/l10n_coverage.test.js).
- Language identity (file actually written in its claimed language, not left in English or swapped) is enforced by [test/js/l10n_language_test.js](test/js/l10n_language_test.js) (runs under `npm run test:js`, no VRAM). Two checks, both backed by [test/js/helpers/l10n_language.js](test/js/helpers/l10n_language.js):
  - **Whole-file**: CLD3 via `cld3-asm` (pure WASM, no native build/model download) detects each file's language. Three benign code aliases (`he`→`iw`, `nb`→`no`, `bs`↔`hr`); a new locale needs an `ACCEPT` entry only if CLD3 reports a code other than its region-stripped stem.
  - **Per-string**: flags individual values left untranslated (in English) when neighbours were translated — CLD3 is unreliable on single short strings, so this uses heuristics (non-Latin: a Latin-only multi-word value where the locale's script is expected; Latin: a value whose words are almost all English-source vocabulary plus an unambiguous English stopword). No allowlist — translate the offender. Run `node tool/check_l10n_language.js --per-string [locale]` for the report.
- Nested-webview rule applies to copy too: localized strings in `launchUrl`/`InAppWebViewScreen` flow through `BuildContext`, so resolve them at the call site.
- Widget tests that `pumpWidget(MaterialApp(...))` a migrated screen/widget MUST set `localizationsDelegates: AppLocalizations.localizationsDelegates` + `supportedLocales: AppLocalizations.supportedLocales`, or `AppLocalizations.of(context)` null-crashes.

## Touching the webspace archive

Spec: [openspec/specs/archive/spec.md](openspec/specs/archive/spec.md). Two rules that must hold for any change to archive code:

- **Active-state byte-identity (ARCH-001).** Everything persisted under the device-key path of `flutter_secure_storage` or in plaintext `SharedPreferences` MUST be byte-identical regardless of whether the device has zero or N archives where all are closed. No counter, flag, salt, MRU entry, or feature-touched marker may vary with archive presence or count. Settings export/import operates only on the app-tier collections and never serializes archive-tier state. Regression test: `test/archive_neutrality_test.dart` (asserts this invariant; update when you add app-tier state).
- **Per-site feature audit (ARCH-006).** When adding any new per-site feature, re-run the audit in the spec. Per-site features that touch disk, background scheduling, OS-level UI, or per-`siteId` entries outside the archive's MK keyspace MUST be disabled or routed through the archive MK for archive-tier sites — extend the override matrix in `WebViewModel` rather than handling it at call sites.

Argon2id derivation costs ~1s on target hardware. Keep it off the UI thread on startup paths and inside a "decrypting..." progress affordance on user-initiated unlocks.

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
- **iOS background contract** (NOTIF-005-I): `BackgroundTaskService` calls `UIApplication.beginBackgroundTask` on app-pause for a ~30s grace window and registers a `BGAppRefreshTask` (`org.codeberg.theoden8.webspace.notification-refresh`) that reloads notif sites opportunistically. Native bridge: [`ios/Runner/BackgroundTaskPlugin.swift`](ios/Runner/BackgroundTaskPlugin.swift).
- **Android background contract** (NOTIF-005-A): same `BackgroundTaskService` — Android side uses `WorkManager` `PeriodicWorkRequest` (15-min minimum, unique-work `webspace-notification-refresh`) instead of a foreground service. `FOREGROUND_SERVICE_SPECIAL_USE` is intractable for Play review, so the app accepts that notifications stop if the OS kills the process. Worker fires `onBackgroundRefresh` only when the Flutter engine is reachable; otherwise it returns success. Native bridge: [`android/app/src/main/kotlin/.../BackgroundTaskAndroidPlugin.kt`](android/app/src/main/kotlin/org/codeberg/theoden8/webspace/BackgroundTaskAndroidPlugin.kt) + [`NotificationRefreshWorker.kt`](android/app/src/main/kotlin/org/codeberg/theoden8/webspace/NotificationRefreshWorker.kt). One-time background-limits info dialog shows on first toggle on either platform.

When adding a notification-related code path, prefer extending `NotificationService` / `BackgroundTaskService` over reaching into `_WebSpacePageState`.

## Per-site toggles backed by downloaded data

DNS blocklist, content blocker, LocalCDN need a downloaded blob.

- **DNS blocklist / content blocker**: the switch stays interactive when the service has no data. Enabling it flips the setting (it takes effect once the data is downloaded) and fires `_warnBlockerNotConfigured` — a SnackBar naming the feature and pointing at App Settings. Tracking Protection's toggle fires the same warning for each unconfigured feature it forces on. While a blocker is effectively on without data, `_notConfiguredWarnIcon` renders next to the tile title and the "Not configured" subtitle turns amber (also on the Tracking Protection tile when a forced dep is unconfigured).
- **LocalCDN**: still hard-gated (`onChanged: ... hasCache ? (v) => ... : null` grays the switch) — it can't serve anything without a cache and its `value` is forced off.
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

## Adding native code that mutates shared state (BUG-007)

A recurring class: native state touched by a callback / IO thread AND another path,
with only *partial* synchronization (which looks safe and isn't). It has recurred across
Rust/JNI (adblock UAF), Swift (BGTask double-complete), and Kotlin (intercept cache). Full
lineage + the invariant: [docs/bugs/007-native-shared-state-races.md](docs/bugs/007-native-shared-state-races.md).

When you add native state (a Kotlin plugin field, a Swift property, a Rust handle) that any
callback, `expirationHandler`, WorkManager/coroutine, or chromium sub-resource IO thread can
observe:

- **Total synchronization or none-shared.** Either single-owner / immutable-snapshot /
  message-passed, or *every* read, write, and eviction under one monitor / serial queue /
  RW-lock. A lock on the writer but not the reader is BUG-007 — don't.
- **One-shot resources are idempotent + identity-guarded.** A freed pointer or a completed
  task: guard the second call to a no-op (`guard pendingRefreshTask === task`). Never
  free/complete by re-reading shared state.
- **Read-heavy hot path → RW-lock** (readers concurrent, writer exclusive); don't hold a lock
  across a blocking call (read under lock, compute outside, write under lock).
- **Encode a class-level guard** (practice, not optional): a JVM concurrency/stress test or a
  structural CI gate so the *next* instance fails, not just this one. Templates:
  `AdblockEngineNativeTest.kt`, `test/js/native_bgtask_completion_funnel.test.js`.
- **Record recurrence in BUG-007**, not a new file — append a dated fix attempt with *why it
  was partial* (which path it covered, which it missed). Cross-link the spec that owns the
  state.

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
