# Integration Tests Specification

## Purpose

Drive the full Flutter app through the `integration_test` framework
against a real display server, dbus session, and Secret Service
provider — the surface that the unit tests in `test/` and the JS shim
tests in `test/js/`/`test/browser/` cannot reach. Goal: catch UI /
orchestration regressions that depend on app initialization order,
async race conditions across SharedPreferences + secure storage, and
ScaffoldMessenger / Navigator interaction across async gaps.

The harness conventions (`isDemoMode`, `SharedPreferences.setMockInitialValues`,
plugin platform-interface stubs, Pop-then-callback re-navigation,
widget-tree dumps on failure) are framework-level and apply to any
`-d` target. The two CI targets wired in are both **desktop**: Linux
(`-d linux`, in the sid container under Xvfb/weston with
`pass-secret-service`) and macOS (`-d macos`, on the `macos-latest`
runner against the native window server + login keychain). Each runs a
headed desktop app the runner can launch directly; the headless
secret-service / display scaffolding is Linux-specific because macOS
supplies both natively.

The **mobile** targets — Android (`-d emulator-*`) and the iOS
Simulator (`-d <udid>`) — are a separate harness: each needs a booted
emulator/simulator before `flutter test` can attach, not just a window
server. The device-boot plumbing exists in this workflow for the
fastlane-driven Android/iOS screenshot pipeline (see
[`screenshots`](../screenshots/spec.md) — `build-android`'s
`reactivecircus/android-emulator-runner` and `build-apple`'s
`simctl boot`). The Android-emulator scenarios are wired in:
`white_screen_test.dart` (INTEG-010), `shortcut_behavior_test.dart`
(INTEG-013) and `page_zoom_test.dart` (ZOOM-006 — the wide-viewport quirk
behind BUG-008 exists in no other engine, and the same file also runs on
both desktop loops) run inside the `build-android` job on every push/PR, on the
same AVD profile and snapshot cache the screenshots lane uses (the
emulator prerequisite steps are ungated; only the screenshot generation
itself stays `workflow_dispatch`), followed in the same emulator step by
the adb-driven lifecycle tier (INTEG-011), which drives warm start,
bfcache back navigation, activity recreation, and the warm
home-shortcut taps from outside the app process. The white-screen and
shortcut suites are Android-only (window-level `PixelCopy`;
`Platform.isAndroid`-gated shortcut paths), so both desktop loops skip
them by basename exactly as they skip `screenshot_test.dart`; the
page-zoom suite is the exception that stays in the desktop loops, because
its whole point is that three engines must agree; the
lifecycle tier is a shell harness, not an `integration_test` target,
so the desktop loops never see it. A broader mobile tier (iOS
Simulator) remains future scope and would extend the same boot setup
rather than the desktop `-d` path.

## Status

- **Status**: Implemented
- **Harness**: Cross-platform (`integration_test/*.dart` runs on any
  `-d` target Flutter supports)
- **CI Integration**: GitHub Actions
  ([`build-and-test.yml`](../../../.github/workflows/build-and-test.yml)).
  Two desktop targets are wired in:
  - `build-linux` job → `Run Linux integration tests` step (`-d linux`).
  - `build-apple` job → `Run macOS integration tests` step (`-d macos`).

  Both are desktop. The mobile targets (Android emulator + iOS
  Simulator) are a separate, device-booted harness and are a future
  scope.

---

## Pipeline Architecture

Two CI pipelines run the same test files. The macOS pipeline
(`build-apple` job) is a single `Run macOS integration tests` step:
`security unlock-keychain` then the per-file `flutter test ... -d macos`
loop — no container, no display server, no secret-service backend,
because `macos-latest` provides all three natively. The Linux pipeline
(`build-linux` job) carries the bulk of the scaffolding and has three
layers:

1. **Container + apt deps** (`debian:sid-slim`) — sid is the only
   Debian release with `libwpewebkit-2.0-dev` ≥ 2.50, which the
   `flutter_inappwebview_linux` plugin's `webkit_navigation_action_is_for_main_frame`
   and `webkit_web_view_get_theme_color` calls require. Trixie ships
   2.48; Bookworm ships 2.40 (`libwpewebkit-1.1-dev`); Ubuntu Noble
   has no WPE packages at all.
2. **Secret Service backend** (`pass-secret-service`) — provides the
   `org.freedesktop.secrets` dbus name that `flutter_secure_storage`
   reaches via libsecret. Replaces `gnome-keyring-daemon`, which 50.0
   in sid auto-activates on the libsecret first-call and prompts via
   gcr-prompter that headless Xvfb cannot dismiss — `main()` hangs
   before `runApp` and every test fails with "App Settings tooltip
   not found / 1 Texts: [Test starting...]".
3. **Test harness** (`integration_test/*.dart`) — Flutter's
   `integration_test` framework runs each test file as a standalone
   Flutter app under Xvfb. Tests use `SharedPreferences.setMockInitialValues({...})`,
   `isDemoMode = true` to skip persistence, and platform-interface
   stubs for plugins whose native dialogs cannot render under Xvfb
   (`file_picker`).

The pipeline is invoked once per integration test file via
`fvm flutter test integration_test/<file>.dart -d linux` inside
`xvfb-run dbus-run-session`.

---

## Requirements

### Requirement: INTEG-001 — Headless Secret Service

The harness SHALL provide an unlocked `org.freedesktop.secrets` dbus
implementation so `flutter_secure_storage` round-trips without
prompting. `gnome-keyring-daemon` SHALL NOT be the provider; it
auto-activates a fresh daemon per the dbus service file
(`/usr/share/dbus-1/services/org.freedesktop.secrets.service`,
`Exec=/usr/bin/gnome-keyring-daemon --start --foreground --components=secrets`)
and that daemon prompts via gcr-prompter on every collection unlock,
which headless Xvfb cannot dismiss.

#### Scenario: pass-secret-service claims the bus name before the test starts

- **Given** the Linux integration test step has installed pipx,
  `pass-secret-service`, and applied the cryptography 46+ + pydbus
  list-buffer compat patches
- **And** a passphrase-less RSA gpg key is generated and `pass init`
  has registered the password store
- **When** `pass_secret_service` is started under `dbus-run-session`
  in the same session as the test
- **Then** the daemon owns `org.freedesktop.secrets` on the dbus session bus
- **And** subsequent libsecret calls reach pass-secret-service rather than
  triggering dbus auto-activation of gnome-keyring-daemon

#### Scenario: Default collection is unlocked before the test

- **Given** `pass_secret_service` is running on the session bus
- **When** the harness runs
  `python3 -c "secretstorage.get_default_collection(conn).unlock()"`
- **Then** the default collection's `Locked` property is `false`
- **And** subsequent `flutter_secure_storage.read` / `.write` calls
  succeed without `PlatformException(Libsecret error, Failed to unlock the keyring)`

#### Scenario: Encryption services initialize cleanly

- **Given** the default collection is unlocked
- **When** the app's `main()` runs
- **Then** the log contains `[HtmlImport/info] Generated new encryption key`
  and `[HtmlImport/debug] Encryption initialized`
- **And** the same for `[HtmlCache/...]` and `[WebViewState/...]`
- **And** zero log lines match `Failed to unlock the keyring` or
  `PlatformException(Libsecret`

---

### Requirement: INTEG-002 — Sid container for WPE WebKit ≥ 2.50

The CI container SHALL be `debian:sid-slim`. The plugin requires symbols
introduced in WPE WebKit 2.50; trixie / bookworm / Ubuntu noble do not
ship a sufficient version.

#### Scenario: WPE WebKit 2.0 dev headers available

- **Given** the build container is `debian:sid-slim`
- **And** the apt install includes `libwpewebkit-2.0-dev`,
  `libwpebackend-fdo-1.0-dev`, `libwpe-1.0-dev`
- **When** `pkg-config --modversion wpe-webkit-2.0` runs
- **Then** the reported version is ≥ 2.50.0

#### Scenario: GTK + libsecret + epoxy support stack present

- **Given** the same install step
- **Then** `libgtk-3-dev`, `liblzma-dev`, `libsecret-1-dev`, and
  `libepoxy-dev` are installed at versions Flutter desktop linux's
  CMake build resolves cleanly

---

### Requirement: INTEG-003 — Plugin dialogs mocked at the platform-interface level

Tests SHALL swap a plugin's `...PlatformInterface.instance` with a
`MockPlatformInterfaceMixin` stub in `setUpAll` whenever they exercise
UI flows whose native Linux implementation opens OS-level dialogs
(file pickers, share sheets, …). Mocking via `setMockMethodCallHandler`
is insufficient for plugins whose Linux implementation talks directly
to the desktop portal over dbus rather than through a Flutter
MethodChannel (`file_picker` is the canonical example: it uses
`FilePickerLinux` with `org.freedesktop.portal.FileChooser`).

#### Scenario: file_picker stub returns canned paths

- **Given** the test installs a `_StubFilePicker extends FilePickerPlatform with MockPlatformInterfaceMixin`
  in `setUpAll` via `FilePickerPlatform.instance = stub`
- **And** the test assigns `stub.saveReturn = '/tmp/<temp>/export.json'`
- **When** the app calls `FilePicker.saveFile(...)`
- **Then** the call returns `'/tmp/<temp>/export.json'` synchronously
- **And** the export's subsequent `File(filePath).writeAsString(jsonString)`
  runs against the stub-supplied path
- **And** the test reads the written file directly to assert on its
  contents

#### Scenario: file_picker stub returns canned import path

- **Given** `_StubFilePicker.pickReturn` is set to a path of an
  on-disk JSON file
- **When** the app calls `FilePicker.pickFiles(...)`
- **Then** the call returns a `FilePickerResult` whose first
  `PlatformFile` has `path` equal to `pickReturn`
- **And** the import's `pickAndImport` decodes that file's contents

---

### Requirement: INTEG-004 — Demo mode + SharedPreferences mock

Tests SHALL set `isDemoMode = true` and seed any required initial
SharedPreferences values via `SharedPreferences.setMockInitialValues({...})`
in `setUpAll`. This prevents tests from writing to the host's real
SharedPreferences and gives each test a deterministic starting state.

#### Scenario: Persistence is skipped

- **Given** `isDemoMode = true`
- **When** the app would otherwise save any setting via
  `_save<X>` methods in `_WebSpacePageState`
- **Then** the write is short-circuited by the `if (isDemoMode) return;`
  guard
- **And** the test does not pollute SharedPreferences across runs

#### Scenario: Initial state seeded for the test

- **Given** the test pre-seeds
  `SharedPreferences.setMockInitialValues({kGlobalOutboundProxyKey: jsonEncode({...})})`
- **When** `app.main()` runs
- **Then** `GlobalOutboundProxy.initialize` reads the seeded entry
- **And** the in-memory `GlobalOutboundProxy.current` reflects the seeded
  address / type / username

---

### Requirement: INTEG-005 — Pop-then-callback navigation pattern

Tests SHALL re-navigate to App Settings between consecutive taps on
tiles whose `onTap` pops the route before invoking the parent's
callback. This pattern applies to Export Settings and Import Settings
(see [`lib/screens/app_settings.dart`](../../../lib/screens/app_settings.dart),
lines `913-915` and `922-924`); naïvely tapping `find.text('Import Settings')`
right after `find.text('Export Settings')` fails because the screen has
been popped to the webspaces-list route by the first tap.

#### Scenario: Backup roundtrip re-navigates between Export and Import

- **Given** the test has tapped Export Settings
- **And** the AppSettings route has been popped, the export's file
  write + snackbar have run on the parent's `ScaffoldMessenger`
- **When** the test wants to tap Import Settings
- **Then** the test re-opens App Settings (`tester.tap(find.byTooltip('App Settings'))`)
  and re-scrolls to the backup row before tapping Import Settings
- **And** the post-import confirmation dialog and warning snackbar
  attach to the webspaces-list route's ScaffoldMessenger

---

### Requirement: INTEG-006 — Self-diagnosing widget-tree dumps on failure

Tests SHALL `print` a labelled enumeration of `find.byType(Text)` /
`find.byTooltip` results when an `expect` is about to fail because
of a missing widget. The CI log is the only artefact when an
integration test fails on a remote runner; the dump tells the
on-call reviewer whether the app failed to render at all (1 Text:
[Test starting...]), navigated to an unexpected screen, or just
needs a different finder.

#### Scenario: Smoke test dumps tree when App Settings tooltip is missing

- **Given** `find.byTooltip('App Settings').evaluate().isEmpty`
- **When** the test reaches the `expect(settingsButton, findsOneWidget)`
  line
- **Then** the test has already printed
  `App Settings tooltip not found.\n  Tooltips: [...]\n  IconButtons: <count>\n  <count> Texts: [...]`

---

### Requirement: INTEG-007 — Existing scenarios

The pipeline SHALL run at least the smoke test and the settings-backup
roundtrip test on every CI run. Each existing scenario file in
`integration_test/` (excluding `screenshot_test.dart`, which is the
separate fastlane-driven Android/iOS pipeline) is enumerated below;
deletion of any scenario MUST be paired with a deletion of its row.

| File | Scenario | What it asserts |
|------|----------|-----------------|
| `settings_smoke_test.dart` | App boots on Linux and reaches App Settings | The pipeline harness works end-to-end: builds, launches, navigates, scrolls, finds the Export/Import row pair |
| `settings_backup_roundtrip_test.dart` | export omits proxy password (PWD-005); import warns user | Exported JSON contains address + username but never the password string; post-import snackbar matches `Proxy passwords` (the PWD-005 user-facing surface) |

#### Scenario: Smoke test pins the harness

- **Given** `settings_smoke_test.dart` is the simplest possible test
  exercising boot → AppSettings → scroll
- **When** the smoke test fails in CI but no other test does
- **Then** the regression is in the harness (apt deps, secret
  service, Xvfb / dbus / fvm), not in app code
- **And** the on-call should debug the workflow before opening a code PR

#### Scenario: Backup roundtrip pins PWD-005

- **Given** a future change accidentally re-introduces the proxy
  password into `UserProxySettings.toJson` (or
  `SettingsBackupService.exportToJson` adds an `includeSecrets: true`
  path)
- **When** `settings_backup_roundtrip_test.dart` runs
- **Then** the `expect(exportedJson, isNot(contains(secretPwd)))`
  assertion fails with the contents of the leaked field

---

### Requirement: INTEG-008 — Adding a new scenario

A new integration test SHALL follow the harness conventions:

1. File at `integration_test/<scenario>_test.dart`
2. `IntegrationTestWidgetsFlutterBinding.ensureInitialized()` at
   `main()` entry
3. `setUpAll`: `isDemoMode = true`, `SharedPreferences.setMockInitialValues({...})`,
   any `flutter_secure_storage` pre-seeding via
   `ProxyPasswordSecureStorage` / `WebViewStateSecureStorage`
   (real round-trip — pass-secret-service handles the storage), any
   plugin platform-interface stubs needed
4. `tearDownAll`: clean up any disk artefacts created by the test
5. Re-navigate via `App Settings → ...` between Pop-then-callback taps
6. `print` a tree dump on the path to any expect that may flake

The scenario need not be added to the workflow file; the test runner
already picks up every `integration_test/*_test.dart`.

#### Scenario: Adding a new test does not require workflow edits

- **Given** a developer adds `integration_test/new_scenario_test.dart`
  following these conventions
- **When** the workflow runs
- **Then** the new file is executed by
  `fvm flutter test integration_test/new_scenario_test.dart -d linux`
  (one invocation per file in the integration_test pipeline step)
- **And** the developer does not edit `.github/workflows/build-and-test.yml`

---

### Requirement: INTEG-009 — macOS runner reuses the harness natively

The same `integration_test/*_test.dart` files SHALL run on the
`macos-latest` runner via `-d macos` in the `build-apple` job, reusing
the cross-platform harness with no macOS-specific test code. macOS
supplies natively what the Linux job builds by hand, so the platform
setup is thin: no Xvfb/weston (the runner has a window server), no
`xdg-user-dirs` (path_provider resolves the sandbox container), and no
`pass-secret-service` (`flutter_secure_storage` reaches the login
keychain). The step SHALL iterate one `flutter test` invocation per
file (excluding `screenshot_test.dart`) exactly as the Linux step
does, so adding a scenario per INTEG-008 needs no workflow edit on
either target.

#### Scenario: macOS step runs every non-screenshot scenario

- **Given** the `build-apple` job has built the macOS app
- **When** the `Run macOS integration tests` step runs
- **Then** it invokes `fvm flutter test <file> -d macos` once per
  `integration_test/*_test.dart`, skipping `screenshot_test.dart`
- **And** a non-zero exit from any file is remembered and re-raised
  after the loop so one failure does not mask the others

#### Scenario: Login keychain is unlocked before secure-storage tests

- **Given** the macOS runner's login keychain backs
  `flutter_secure_storage`
- **When** the step runs `security unlock-keychain` before the tests
- **Then** `flutter_secure_storage` round-trips (proxy passwords,
  HtmlImport/HtmlCache/WebViewState keys) without raising an
  interactive keychain prompt that headless CI cannot dismiss

#### Scenario: No macOS-specific harness code

- **Given** a test follows the INTEG-008 conventions
- **When** it runs under `-d macos`
- **Then** it passes without any `Platform.isMacOS` branch, because the
  plugin platform-interface stubs (`file_picker`) and method-channel
  mocks (`flutter_inappwebview_proxycontroller`) are platform-agnostic

#### Scenario: Ad-hoc signing needs an entitlements override and --ci

- **Given** the CI runner has no Apple signing identity, so the debug
  app is ad-hoc signed
- **And** the committed `macos/Runner/DebugProfile.entitlements`
  declares provisioning-dependent entitlements (the team-prefixed
  `application-groups` and `keychain-access-groups`) that an ad-hoc
  signature cannot satisfy
- **When** the `Run macOS integration tests` step overwrites that file
  with the stock Flutter debug set (`app-sandbox`, `cs.allow-jit`,
  `files.user-selected.read-write`, `network.server`, `network.client`)
  minus those two keys, and runs `flutter test -d macos --ci`
- **Then** `taskgated` accepts the ad-hoc signature (instead of
  SIGKILL'ing the app as "Code Signature Invalid"), and `--ci`
  (`usingCISystem`) re-signs with the sandbox disabled so the tool
  discovers the app's Dart VM Service instead of timing out 12 minutes
  on "log reader stopped unexpectedly"
- **And** because no `keychain-access-groups` entitlement survives
  (even a bare, de-prefixed one re-triggers the launch SIGKILL under
  ad-hoc), `flutter_secure_storage`'s data-protection keychain fails
  every op with `errSecMissingEntitlement` (-34018) and the legacy
  keychain can't be selected instead (`MacOsOptions.usesDataProtection`
  `Keychain` is a no-op — the Dart map key mismatches the native
  `useDataProtectionKeyChain` the darwin plugin reads); the tests that
  need a working keychain (`settings_backup_roundtrip_test`,
  `proxy_auth_test`) call `installInMemoryKeychainIfUnavailable()`
  (`integration_test/secure_storage_fake.dart`) — it probes the real
  plugin and installs an in-memory channel fake only when it throws, so
  macOS runs them with the fake while Linux keeps its real
  pass-secret-service round-trip — and every other test tolerates the
  logged, non-fatal -34018
- **And** `proxy_auth_test` runs on macOS too: the per-site proxy
  delivery is mutually exclusive per platform (webview.dart only sets
  `initialSettings.proxySettings` on iOS/macOS, where the fork applies it
  to the container `WKWebsiteDataStore` network session; Android/Linux
  leave it null and route through `inapp.ProxyController.setProxyOverride`),
  so the test branches: on iOS/macOS it reads the credential-embedded
  proxy off the mounted WebView's `initialSettings.proxySettings`; on
  Android/Linux it asserts the captured `setProxyOverride` channel call —
  both checking the same host:port + username + secure-storage password
- **And** the override never reaches a release build — the runner
  checks out fresh and release builds keep the committed entitlements
  plus a real signing identity

#### Scenario: Disk is reclaimed before the macOS integration loop

- **Given** the `build-apple` job has built the iOS IPA and the macOS
  release app, so the iOS archive tree (`build/ios`) and the macOS
  release build tree (`build/macos`, Release config) both sit on the
  runner's tight disk
- **And** the `Run macOS integration tests` step is about to rebuild the
  macOS app once per file in the *debug* configuration, which Xcode keys
  separately from the release objects and never reuses
- **When** a `Reclaim disk before macOS integration tests` step runs
  before the loop
- **Then** it removes `build/macos/Build/Intermediates.noindex` (the
  release object files) and everything under `build/ios` except
  `build/ios/ipa`, leaving the two post-loop deliverables intact — the
  IPA (`Upload IPA`) and the Release `.app` under
  `build/macos/Build/Products/Release` (`Create macOS ZIP archive`)
- **And** it does not touch `rust/webspace_adblock/target`, because the
  webspace_adblock pod's always-out-of-date script phase re-invokes
  `scripts/build_rust.sh apple` on every debug build and an intact
  `target/` keeps cargo an incremental no-op instead of a full
  five-slice recompile per file
- **And** without this reclamation the loop exhausts the disk mid-run
  (observed: the 4th file failing on rsync `Input/output error` copying
  `App.framework`, then a truncated `Flutter-Generated.xcconfig` and a
  corrupted Flutter SDK for every file after)

---

### Requirement: INTEG-010 — Android white-screen pixel scenarios

`integration_test/white_screen_test.dart` SHALL drive the
in-process-drivable BUG-001 entry paths
([docs/bugs/001-white-screen.md](../../../docs/bugs/001-white-screen.md))
on an Android emulator/device and assert on the **composited window
pixels** over the webview slot, sampled by
`SurfaceDiagPlugin.sampleWindowRegion` (window-level `PixelCopy`).
This is the only capture plane that shows what the user sees:
Flutter's `convertFlutterSurfaceToImage` misses hybrid-composition
platform views, and a JS probe reports the renderer plane, which is
healthy in every confirmed BUG-001 instance. Pages come from an
in-process loopback HTTP server so a network failure can never
masquerade as a white screen, and each content page is a solid color
Flutter never draws so a matching dominant color proves the sample
came from the webview.

The suite SHALL cover at least: fresh first activation (BUG-001 gap
#7), loaded-site switch (`_setCurrentIndex` reuse), the reload funnel
(`PAUSE-021`), memory pressure against the visible site
(`PAUSE-019`), fresh activation with other sites live
(`PAUSE-017`), the return from a pushed opaque route (`PAUSE-024`),
and the nested `InAppWebViewScreen` — both its own fresh surface and
the return to the main page behind it (`PAUSE-026`). Warm start,
activity recreation, and bfcache back navigation need real activity
lifecycle transitions an in-process test cannot produce; those belong
to the adb-driven lifecycle tier (INTEG-011).

At least one scenario per commit-side repaint (`PAUSE-021`,
`PAUSE-025`) SHALL be driven by a page that **withholds its first byte
longer than the nudge's tick budget** (~0.6s). A page that commits
instantly is repainted by the issue-time nudge whether or not the
settled-side re-nudge exists, so an all-instant suite cannot fail on
the ordering defect that every BUG-001 recurrence since Attempt 8 has
actually been — it asserts only that the app renders at all. The
delay SHALL come from the in-process server holding the response, not
from a slow network, so the scenario stays deterministic.

The nested-screen scenario SHALL reach the nested route through a
**script-initiated cross-domain navigation** from a seeded site with
`blockAutoRedirects` off, and the cross-domain target SHALL be the
same in-process server reached under a second loopback address
(`127.0.0.2` alongside `127.0.0.1`, hence a server bound to
`anyIPv4`). Two hosts on one server keep the navigation genuinely
cross-domain — `getBaseDomain` compares IP literals — while keeping a
network failure impossible, and a scripted navigation keeps the
scenario off any synthetic touch reaching the platform view.

#### Scenario: A late-committing document is repainted promptly

- **Given** a seeded site whose page withholds its first byte for
  longer than the repaint nudge's tick budget
- **When** the suite activates it, so the surface attaches and every
  issue-time nudge drains before the document commits
- **Then** the composited webview region shows the page's color within
  a bounded settle window, which only the settled-side re-nudge
  (`PAUSE-025`) can produce
- **And** the deadline is tight on purpose: a blank that clears much
  later, on some unrelated relayout, is still the bug

#### Scenario: White control page proves the detector is not vacuous

- **Given** a seeded site whose page is genuinely all-white
- **When** the suite activates it and samples the webview rect
- **Then** `SurfaceDiagNative.classify` reports `uniformBlank`
- **And** a sampler regression that stops seeing webview pixels
  therefore fails this scenario instead of silently passing the rest

#### Scenario: A blank window fails the run with the sample as diagnostic

- **Given** any covered entry path leaves the composited webview
  region uniform white/black after its settle window
- **When** the polling assertion times out
- **Then** the test fails and prints the last `WindowRegionSample`
  (status, dominant color, uniform fraction) plus the in-memory
  `LogService` tail, which is safe to surface because the test data
  is synthetic (loopback URLs, seeded names)

#### Scenario: Runs inside build-android on every push/PR

- **Given** the `build-android` job has built the APKs and its
  emulator prerequisites (KVM, Android SDK, API 34 google_apis x86_64
  `pixel_5` AVD snapshot cache) are ungated
- **When** the `Run emulator integration scenarios` step runs
  `fvm flutter test integration_test/white_screen_test.dart -d <device> --flavor fdebug`
  inside the booted emulator with a 25-minute wall-clock cap
- **Then** the suite executes on every push to master, every PR, and
  every manual dispatch, and a failure fails `build-android`
- **And** the screenshot generation step after it remains gated on
  `workflow_dispatch`, booting the emulator a second time on dispatch
  runs

#### Scenario: Desktop loops skip the Android-only suite

- **Given** the Linux and macOS integration loops iterate
  `integration_test/*_test.dart`
- **When** they reach `white_screen_test.dart`
- **Then** both skip it by basename (like `screenshot_test.dart`),
  because the `PixelCopy` channel exists only on Android and the
  `skip: !Platform.isAndroid` guard would still cost a desktop debug
  build per run

---

### Requirement: INTEG-011 — Adb-driven white-screen lifecycle tier

`scripts/run_android_lifecycle_tests.sh` SHALL drive the BUG-001
entry paths that require real activity lifecycle transitions — warm
start (`PAUSE-020`), back navigation into a back/forward-cached entry
(`PAUSE-018`), and activity recreation — from **outside** the app
process via adb, because an in-process integration test dies with the
activity it rides in. The symptom SHALL be read from the composited
frame (`adb exec-out screencap`, i.e. SurfaceFlinger output, the same
plane the in-app window sampler measures) and classified by
`scripts/classify_window_pixels.py` with the same thresholds as
`SurfaceDiagNative.classify` (>= 98% one quantized color at luma >=
243 or <= 12 is the blank).

Determinism contract: pages are served from the host (reachable as
`10.0.2.2` from the emulator) so a network failure cannot masquerade
as a white screen; each page is a solid color Flutter never draws so
a matching dominant color proves the webview composited; and the app
is launched with a `ws_diag_seed` intent extra (base64 JSON site
list) that `DiagSeed.applyFromLaunchIntent` applies before the first
prefs read, with per-run-unique explicit siteIds and demo mode on so
nothing persists across runs. A plain cold start lands on the
webspace picker with no site selected (the persisted `currentIndex`
is never read back), so every seeded launch also carries the
production pinned-shortcut `siteId` extra: activation goes through
`StartupRestoreEngine.resolveLaunch`'s direct match — the same path
a launcher shortcut tap takes, making the cold-start scenario itself
a pixel check on the shortcut launch path (Attempt 2's trigger). The
seed also disables `fullscreenOnShortcut`: the first immersive entry
pops Android's "viewing full screen" education bubble, whose
screen-wide 50% dim reaches the composited frame and corrupts every
sample (observed as exact per-channel halving of the page colors).

#### Scenario: Warm start repaints the re-attached surface

- **Given** the seeded dark site is visible
- **When** the harness sends HOME, waits ~5s (surface destroyed), and
  relaunches the singleTop activity via `am start`
- **Then** the composited frame returns to the dark page color within
  the polling deadline, else the run fails

#### Scenario: Back into a bfcached entry repaints

- **Given** the dark page carries a full-page link to the magenta page
- **When** the harness taps the webview center, confirms magenta
  composited, then sends the system BACK key (the production
  `_goBackAndRepaint` path)
- **Then** the composited frame returns to the dark page color within
  the polling deadline

#### Scenario: Activity recreation ends painted

- **Given** `always_finish_activities` is enabled and the app is
  backgrounded (activity destroyed, process kept)
- **When** the harness relaunches with the seed extra and the engine
  restarts
- **Then** the composited frame reaches the dark page color, and the
  harness restores `always_finish_activities` afterward (also on
  failure, via its exit trap)

#### Scenario: White control page proves the external detector is not vacuous

- **Given** a cold start seeded onto the genuinely all-white page
- **When** the harness polls the classifier
- **Then** the verdict is the white blank (`blank-white`), proving the
  screencap plane reads webview pixels and the dark-page assertions
  cannot pass vacuously

#### Scenario: Runs in build-android after the in-process suite

- **Given** the `Run emulator integration scenarios` emulator step ran
  the in-process wrapper scripts (`run_android_integration_tests.sh`,
  `run_android_shortcut_tests.sh`, `run_android_background_audio_tests.sh`),
  whose `flutter test` installs an APK with the *test* Dart entrypoint
- **When** `run_android_lifecycle_tests.sh` runs next in the same step,
  rebuilds the default-entrypoint fdebug debug APK, reinstalls it, and
  clears package data for a pristine cold start
- **Then** the tier executes on every push/PR under a 25-minute
  wall-clock cap, and on failure the step uploads
  `build/white_screen_adb/` (failing screencap PNG, logcat tail, last
  classification) as the `white-screen-adb-diagnostics` artifact

#### Scenario: Seeding is inert outside the harness

- **Given** a release (non-debuggable) build
- **When** any launch intent carries `ws_diag_seed`
- **Then** the Kotlin channel returns null (MainActivity is exported,
  so a hostile intent must not swap the user's site list) and the Dart
  call is additionally compiled out of release via `kDebugMode`, so
  production behavior is unchanged

#### Scenario: System error dialogs cannot corrupt samples

- **Given** the CI emulator host is loaded enough that a foreign app
  (in practice: the launcher, deterministically) ANRs, parking a
  scrimmed, non-cancelable dialog over the whole screen
- **When** the emulator session starts
- **Then** the CI step sets `hide_error_dialogs` before the
  in-process suite (the flag only gates future dialogs), the harness
  sets it again first-thing for standalone runs, force-stops the
  resolved HOME package to dismiss any dialog already parked (an ANR
  dialog ignores BACK; killing its process is the only reliable
  dismissal, and the launcher restarts on the next HOME press), and
  restores the setting in its exit trap

---

### Requirement: INTEG-012 — Background refresh drives an observable notification

The lifecycle harness SHALL verify the Android background-refresh
contract (`NOTIF-005-A`,
[web-push-notifications](../../changes/web-push-notifications/specs/web-push-notifications/spec.md)
— still an unarchived change, so its requirements live under `openspec/changes/`)
end to end from outside the process: a site seeded with
`notificationsEnabled` whose page posts a JS `Notification` on every
load, the app backgrounded, and one `NotificationRefreshWorker` run
triggered through the debug-build-only `NotificationRefreshDebugReceiver`
— the OS notification that appears (read via `dumpsys notification`) is
proof the full pipeline ran with no foreground activity: worker → engine
dispatch → `onBackgroundRefresh` site reload → `Notification` polyfill →
`flutter_local_notifications`.

Trigger contract: the periodic job SHALL NOT be driven with
`adb shell cmd jobscheduler run -f`. Forcing the job bypasses
JobScheduler's constraints but not WorkManager's own guard, which
refuses any periodic `WorkSpec` executed before its next run time
(`WorkerWrapper`: "executed before schedule") and reschedules instead,
reaching neither the worker nor Dart. Whether a forced run was honoured
therefore depended on whether the work's first period — due at enqueue
time while `periodCount == 0` — had already been spent by an unforced
run, which is a race the harness cannot observe and which read from
outside as a broken dispatch leg. The receiver enqueues an unconstrained
one-shot of the same worker, so the leg under test is the real one and
only the trigger is synthetic; it is declared in the `debug` source set
alone, so no shippable build carries it. The scheduling half of
NOTIF-005-A stays asserted separately, from the JobScheduler dump.

Observation contract: "a new notification" SHALL be read as a set
difference over notification **identities** (the `user|pkg|id|tag|uid`
key from `StatusBarNotification.getKey`), never as a record count. A
count cannot see a repost — the OS collapses on the `(tag, id)` pair,
so a second post with the same pair updates the existing record and the
count stays put (`NOTIF-009` is what makes successive untagged posts
distinct identities in the first place) — and the same record
transiently appears in more than one `dumpsys` section while it is
being enqueued, which made a count-based assertion pass or fail on
whether the poll landed inside that window. The page SHALL also fire a
`/beacon` request at the host server on every load, so a failure can
name which leg broke instead of only that no notification arrived.

Cross-platform posture: the seed transport is platform-agnostic
(`ws_diag_seed` intent extra on Android; `WS_DIAG_SEED` process
environment elsewhere, which `simctl launch` forwards via its
`SIMCTL_CHILD_` prefix), and the pixel classifier is already
device-neutral, so a future `simctl` driver reuses both. The iOS
background contract (`NOTIF-005-I`, `BGAppRefreshTask`) is NOT
CI-drivable: `BGTaskScheduler` tasks can only be simulated with a
debugger attached (the private
`_simulateLaunchForTaskWithIdentifier:` LLDB call), which headless
`simctl` cannot do — iOS keeps its structural coverage
(`test/js/native_bgtask_completion_funnel.test.js`) and an iOS pixel
tier for the non-background scenarios remains future scope.

#### Scenario: Scheduling contract is asserted, not assumed

- **Given** the seeded notification site is active
- **When** the harness lists JobScheduler jobs for the app package
- **Then** at least one `androidx.work` job exists, else the run
  fails naming NOTIF-005-A (the periodic work was never scheduled)

#### Scenario: Foreground pipeline is pinned before the background step

- **Given** the notification site's page just painted
- **When** the harness polls `dumpsys notification`
- **Then** the foreground load itself must have posted a notification
  (polyfill → local-notifications proven working), and the identity
  set it produced is the baseline the background assertion diffs
  against

#### Scenario: A background refresh posts a new notification while backgrounded

- **Given** the app is backgrounded (HOME) with the process alive
- **When** the harness broadcasts to the debug refresh receiver
- **Then** the receiver's own log line confirms the broadcast was
  delivered (else the run fails at once naming the installed APK,
  instead of spending the notification deadline), a notification
  identity absent from the baseline appears within the polling
  deadline, and on failure the harness saves the jobscheduler dump,
  the notification dump, and a logcat tail as artifacts

#### Scenario: A failure names the leg that broke

- **Given** the background assertion timed out
- **When** the harness compares the host server's `/beacon` hit count
  against the count taken when the app was backgrounded
- **Then** a risen count reports the break as downstream (the site
  reloaded, the polyfill → `NotificationService` →
  `flutter_local_notifications` leg dropped it) and an unchanged count
  reports it as upstream
- **And** upstream is split further by the worker's own log line: no
  `NotificationRefreshWorker fired` names the trigger, before
  `doWork` ever ran; the line present names the engine-dispatch →
  `onBackgroundRefresh` leg. The two are the same silence from
  outside, and reading one for the other is what made an earlier
  failure unreadable

#### Scenario: The refreshed site still paints on return

- **Given** the background refresh reloaded the site offscreen
- **When** the app is foregrounded again
- **Then** the composited frame reaches the page color (the BUG-001
  assertion applied to the post-refresh surface)

---

### Requirement: INTEG-013 — Home-shortcut behavior scenarios

`integration_test/shortcut_behavior_test.dart` SHALL drive the Android
home-shortcut flows of [home-shortcut](../home-shortcut/spec.md)
through the real widget tree on an Android emulator/device, covering
the *wiring* in `lib/main.dart` that the engine unit tests in
`test/startup_restore_engine_test.dart` cannot reach: which prompt a
`LaunchResolution` raises, what the user's answer persists, whether the
"Home Shortcut" menu item is offered, and what deleting a site does to
the launcher tiles that still reach it. The suite SHALL cover at least
HS-002/HS-006 (cold launch), HS-004/HS-005 (menu gating, including the
rebound-site case), HS-001/HS-012 (pin + ledger record), HS-011
(orphan confirm / reroute / create, and the remembered rebind), and
HS-013 (delete-time Keep/Reassign/Disable prompt).

The platform channel SHALL be mocked, because a launcher pin dialog and
a real pinned set are not reachable from in-process; the mock SHALL
drain `getLaunchSiteId` on read, mirroring MainActivity's
`intent.removeExtra`, so a resume-cadence re-poll cannot re-navigate.
Pages come from an in-process loopback server, and each test seeds its
own `SharedPreferences` (site list, ledger, rebind map) before calling
`app.main()`, so the runs share no state.

A warm tap is delivered by driving the lifecycle round trip through
`inactive` only — never `paused` or `hidden`. `SchedulerBinding` sets
`framesEnabled = false` for those two states, which makes
`scheduleFrame()` a no-op, so the next `tester.pump()` waits forever for
a frame nobody schedules (observed as a full-cap CI hang). Any future
integration test that drives app lifecycle SHALL follow the same rule.
Each test SHALL also carry its own `timeout:` so a hang fails that test
with its widget-tree and log dump rather than expiring the suite's
wall-clock cap with no output.

Warm taps SHALL stay in the adb tier: a tap on a pinned tile while the
app runs is delivered as `onNewIntent` against the running activity,
which an in-process test cannot produce. Those two scenarios live in
`scripts/run_android_lifecycle_tests.sh` alongside the INTEG-011
lifecycle scenarios, which already own the emulator, the page server,
and the frame classifier.

#### Scenario: Cold launch opens the pinned site at its home URL

- **Given** a seeded site whose persisted `currentUrl` drifted away
  from its `initUrl`, and a pending launch carrying its `siteId`
- **When** the app cold-starts
- **Then** that site is the activated one, no other site is mounted,
  and its `currentUrl` is back at `initUrl` (HS-006)
- **And** the startup reconcile has recorded the pinned site's url in
  `shortcutUrlLedger` (HS-012)

#### Scenario: Menu gating is asserted in both directions

- **Given** sites in three pin states — pinned, unpinned, and rebound
  to by an orphaned pinned tile
- **When** the overflow menu is opened for each
- **Then** "Home Shortcut" is absent for the pinned and the rebound
  site and present for the unpinned one (HS-005), and tapping it
  reaches `pinShortcut` on the channel with that site's id and label
  and records its url in the ledger (HS-001 / HS-012)

#### Scenario: An orphaned tile's prompt outcome is what gets persisted

- **Given** a pinned tile whose site is gone but whose ledger url
  matches a live site's base domain
- **When** the tile is tapped and the user declines
- **Then** no site is opened and no rebind is remembered, and the next
  tap prompts again
- **When** the user confirms instead
- **Then** the matched site is activated, `shortcutSiteRemap` binds the
  tile to it, and a subsequent tap opens it with no prompt (HS-011)

#### Scenario: A tile with no domain match can be rerouted or given a new site

- **Given** a pinned tile whose ledger url matches no live site
- **When** the tile is tapped
- **Then** the missing-site chooser offers reroute and create; choosing
  reroute binds the tile to the picked site, and choosing create builds
  a site rooted at the ledger url and binds the tile to it (HS-011)

#### Scenario: Deleting a site prompts for every tile that reaches it

- **Given** a site reachable by two pinned tiles — its own, and an
  orphaned tile rebound to it
- **When** the site is deleted and the user picks Disable
- **Then** `disableShortcut` is called for both tiles and their ledger
  and rebind entries are dropped (HS-013)
- **And** deleting a site no pinned tile reaches raises no prompt

#### Scenario: Warm taps are covered out of process

- **Given** the app is running with the shortcut-seeded sites
- **When** the adb harness issues `am start ... --es siteId <other>`
- **Then** the other site composites (HS-002 "app already running")
- **And** after driving a site off its `initUrl` and re-tapping its own
  shortcut, the frame still shows the navigated page — a warm tap
  preserves the live session (HS-006), and a reset to `initUrl` would
  repaint the home page instead

#### Scenario: Runs as its own wrapper script in build-android

- **Given** the emulator step runs one wrapper script per in-process
  suite (the runner executes each `script:` line as a separate `sh -c`,
  so the device id has to stay in scope with `flutter test`)
- **When** `run_android_shortcut_tests.sh` runs after
  `run_android_integration_tests.sh` and before the lifecycle tier
- **Then** the suite executes on every push/PR under its own 20-minute
  wall-clock backstop, and a failure fails `build-android`

#### Scenario: Desktop loops skip the Android-only suite

- **Given** the Linux and macOS integration loops iterate
  `integration_test/*_test.dart`
- **When** they reach `shortcut_behavior_test.dart`
- **Then** both skip it by basename (like `white_screen_test.dart`),
  because every path it drives is `Platform.isAndroid`-gated and the
  file's own `skip:` guard would still cost a desktop debug build

---

### Requirement: INTEG-014 — Offline and degraded-network scenarios

`integration_test/offline_connection_test.dart` SHALL drive the offline,
slow and shaky network postures against a real engine and an in-process
loopback fixture server. Each posture is a negotiation between a Dart
decision and the engine's load lifecycle, which is what puts it out of
reach of the unit tier: `test/connectivity_service_test.dart` and
`test/resume_reload_engine_test.dart` cover the decisions in isolation,
but neither sees the signals a live WebView actually emits.

"Offline" SHALL be simulated at the layer the app decides on
(`ConnectivityService.onlineOverride`), not by cutting the runner's
network — the assertion is about the gate, and a runner without network
cannot serve the fixture that proves the online half. "Shaky" SHALL be
produced by the fixture server refusing the connection or truncating a
promised body, so the failure is deterministic rather than waited for.

Assertions SHALL be split by who owns the behavior:

- **Dart-owned** — whether the cached-then-live reload was issued,
  whether a load failure was reported, whether a cache save was
  attempted. Asserted strictly on every platform.
- **Engine-owned** — whether the engine reloads an
  `InAppWebViewInitialData` page back to its `baseUrl`, and whether it
  reports a network failure to the Dart layer at all. Asserted only once
  observed; otherwise the test SHALL log a `SKIP` line naming what the
  engine did not do, rather than assert a vacuous truth (the
  `privacy_settings_test.dart` posture).

The engine-owned split is not hypothetical: Linux WPE maps
`WEBKIT_NETWORK_ERROR_FAILED` (299) to no `WebResourceErrorType`, and
`WebResourceError.fromMap` force-unwraps that lookup, so a plain
connection failure never reaches `onReceivedError` on that target. The
macOS runner exercises the failure assertions for real.

#### Scenario: Offline construction renders the snapshot and touches no network

- **Given** a site with a cached snapshot and `ConnectivityService`
  reporting offline
- **When** the webview is constructed
- **Then** the snapshot is painted, `onReloadIssued` never fires, the
  fixture server records zero requests for the site's path, and no
  main-frame failure is reported

#### Scenario: Online construction swaps the snapshot for the live page once

- **Given** the same construction with `ConnectivityService` reporting
  online
- **When** the cached parse settles
- **Then** exactly one live reload is issued — not a loop — and the live
  bytes replace the snapshot in the DOM

#### Scenario: A slow response is never reported as a failure

- **Given** a route that sits on the request for several seconds
- **When** the load is in flight
- **Then** no main-frame failure is reported mid-flight, the load
  eventually settles, and the live bytes commit — a slow link must not
  reach `ResumeReloadEngine` as a stranded load and get re-issued out
  from under a response that was about to arrive

#### Scenario: A dropped connection is a retryable failure type

- **Given** a refused connection, and separately a response truncated
  mid-body
- **When** the engine reports the main-frame failure
- **Then** every reported error type is in
  `ResumeReloadEngine.retryableErrorTypes` — a type outside that set
  means PAUSE-022 recovery silently never fires for the exact case it
  exists for, which no unit test can catch because the unit tier feeds
  the engine the strings this test discovers

#### Scenario: A failed load never overwrites the offline snapshot

- **Given** a site whose main-frame navigation fails for a network
  reason
- **When** the engine commits its own error page and fires `onLoadStop`
  for it
- **Then** `onHtmlLoaded` is not invoked, so the site's last-good
  snapshot survives the flake that makes the snapshot matter — caching
  the error page is what the next offline cold start would render
- **And** because neither desktop target can positively verify this
  (Linux never delivers the failure, WKWebView never settles it), the
  guard SHALL additionally be pinned structurally by
  `test/js/offline_cache_failure_gate.test.js`, which fails if the
  `onLoadStop` cache save stops being gated on the failure record

---

## Known Limitations

- **Build time per test**: each `flutter test integration_test/<file>.dart`
  rebuilds the linux debug bundle if cmake's incremental graph is invalidated
  (~3 minutes from cold cache; ~30 seconds from warm). Adding more
  scenarios scales linearly under the current invocation pattern. A future
  refactor could batch all integration tests into one binary using
  `flutter drive` + a custom test driver, but the simplicity of one-test-
  per-file outweighs the wall-time gain at the current count.
- **`pass-secret-service` patches**: the two `sed` patches applied in the
  workflow's `Install pass-secret-service` step are pinned to the
  upstream 0.1a0 release. When upstream ships a release that handles
  `cryptography>=46` and pydbus's `list[int]` buffer convention natively,
  drop the patches. No version pin in the workflow today; track
  https://github.com/mkhon/pass-secret-service for the fix.
- **Webview rendering not exercised on desktop**: the smoke test reaches
  App Settings without ever loading a webview; `settings_backup_roundtrip_test.dart`
  is the same. Webview-loading scenarios (Tier C of the integration
  test backlog) may surface a new class of headless rendering issues
  that this spec doesn't cover. On Android, `white_screen_test.dart`
  (INTEG-010) does exercise real webview rendering down to composited
  pixels on every push/PR via the emulator step in `build-android`.
- **Emulator compositing is not device compositing**: the emulator runs
  `-gpu swiftshader_indirect`, so INTEG-010's scenarios exercise the
  funnels and detector plumbing deterministically but may never
  reproduce a device-specific SurfaceFlinger race (Mali/Adreno). A
  green run means "no blank window on this compositor", not "BUG-001
  cannot happen"; a red run is a real, labeled reproduction.
- **proot is for local dev only**: locally on a non-sid host (eg. a
  Debian bookworm dev container) the harness can run inside a sid
  chroot via `proot -r /var/lib/sid-chroot`, but proot 5.1.0 (bookworm)
  has known statx + access syscall bugs that break Flutter's
  `which clang++` and other plugin lookups. Use proot ≥ 5.3.1 from
  upstream; CI does not have this constraint because the container is
  natively sid.

---

## Files

### Modified
- [`.github/workflows/build-and-test.yml`](../../../.github/workflows/build-and-test.yml)
  — `build-linux` job's `Install container base + Flutter Linux + WPE WebKit deps`,
  `Install pass-secret-service`, and `Run Linux integration tests` steps;
  `build-apple` job's `Run macOS integration tests` step (`-d macos`).

### Existing
- [`integration_test/white_screen_test.dart`](../../../integration_test/white_screen_test.dart)
  — INTEG-010: BUG-001 entry paths against composited window pixels
  (Android emulator tier). Sampler:
  [`android/.../SurfaceDiagPlugin.kt`](../../../android/app/src/main/kotlin/org/codeberg/theoden8/webspace/SurfaceDiagPlugin.kt)
  + [`lib/services/surface_diag_native.dart`](../../../lib/services/surface_diag_native.dart)
  (classification unit-tested in
  [`test/surface_diag_classification_test.dart`](../../../test/surface_diag_classification_test.dart))
- [`integration_test/shortcut_behavior_test.dart`](../../../integration_test/shortcut_behavior_test.dart)
  — INTEG-013: [home-shortcut](../home-shortcut/spec.md) launch, menu
  gating, orphan routing and delete-time tile prompt through the widget
  tree (Android emulator tier), run by
  [`scripts/run_android_shortcut_tests.sh`](../../../scripts/run_android_shortcut_tests.sh);
  the resolution rules themselves stay in
  [`test/startup_restore_engine_test.dart`](../../../test/startup_restore_engine_test.dart)
- [`scripts/run_android_lifecycle_tests.sh`](../../../scripts/run_android_lifecycle_tests.sh)
  — INTEG-011: adb-driven lifecycle tier (warm start, bfcache back,
  activity recreation, white control); INTEG-012: background-refresh
  scenario (NOTIF-005-A); INTEG-013: warm home-shortcut taps. Frame
  classifier:
  [`scripts/classify_window_pixels.py`](../../../scripts/classify_window_pixels.py);
  launch seeding: [`lib/services/diag_seed.dart`](../../../lib/services/diag_seed.dart)
  (`getDiagSeed` in MainActivity, debuggable builds only; parsing
  unit-tested in [`test/diag_seed_test.dart`](../../../test/diag_seed_test.dart))
- [`integration_test/camera_test.dart`](../../../integration_test/camera_test.dart)
  — CAM-010: per-site camera modes against a real Android WebView
  (virtual serves the picked image, block denies, real hands over the
  device camera). Runner:
  [`scripts/run_android_camera_tests.sh`](../../../scripts/run_android_camera_tests.sh)
  (pre-grants the CAMERA runtime permission so the OS dialog cannot
  block the run). See [web-camera-access](../web-camera-access/spec.md)
- [`integration_test/offline_connection_test.dart`](../../../integration_test/offline_connection_test.dart)
  — INTEG-014: offline / slow / shaky network postures against a
  loopback fixture server (both desktop targets). The decisions it
  drives are unit-tested in
  [`test/connectivity_service_test.dart`](../../../test/connectivity_service_test.dart)
  and [`test/resume_reload_engine_test.dart`](../../../test/resume_reload_engine_test.dart);
  this suite supplies the live-engine signals those tests stub
- [`integration_test/settings_smoke_test.dart`](../../../integration_test/settings_smoke_test.dart)
  — harness pin
- [`integration_test/settings_backup_roundtrip_test.dart`](../../../integration_test/settings_backup_roundtrip_test.dart)
  — PWD-005 user-facing surface
- [`integration_test/screenshot_test.dart`](../../../integration_test/screenshot_test.dart)
  — separate pipeline (mobile Android/iOS, not the desktop `-d`
  targets); skipped by both the Linux and macOS loops. See
  [`screenshots`](../screenshots/spec.md)
