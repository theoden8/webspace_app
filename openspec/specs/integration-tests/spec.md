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
`white_screen_test.dart` (INTEG-010) runs inside the `build-android`
job on every push/PR, on the same AVD profile and snapshot cache the
screenshots lane uses (the emulator prerequisite steps are ungated;
only the screenshot generation itself stays `workflow_dispatch`),
followed in the same emulator step by the adb-driven lifecycle tier
(INTEG-011), which drives warm start, bfcache back navigation, and
activity recreation from outside the app process. INTEG-010 is
Android-only (window-level `PixelCopy`), so both desktop loops skip
it by basename exactly as they skip `screenshot_test.dart`; the
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
(`PAUSE-019`), and fresh activation with other sites live
(`PAUSE-017`). Warm start, activity recreation, and bfcache back
navigation need real activity lifecycle transitions an in-process
test cannot produce; those belong to the adb-driven lifecycle tier
(INTEG-011).

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
- **When** the `Run white-screen pixel scenarios` step runs
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
a pixel check on the shortcut launch path (Attempt 2's trigger).

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

- **Given** the `Run white-screen pixel scenarios` emulator step ran
  `run_android_integration_tests.sh`, whose `flutter test` installs an
  APK with the *test* Dart entrypoint
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
- [`scripts/run_android_lifecycle_tests.sh`](../../../scripts/run_android_lifecycle_tests.sh)
  — INTEG-011: adb-driven lifecycle tier (warm start, bfcache back,
  activity recreation, white control). Frame classifier:
  [`scripts/classify_window_pixels.py`](../../../scripts/classify_window_pixels.py);
  launch seeding: [`lib/services/diag_seed.dart`](../../../lib/services/diag_seed.dart)
  (`getDiagSeed` in MainActivity, debuggable builds only; parsing
  unit-tested in [`test/diag_seed_test.dart`](../../../test/diag_seed_test.dart))
- [`integration_test/settings_smoke_test.dart`](../../../integration_test/settings_smoke_test.dart)
  — harness pin
- [`integration_test/settings_backup_roundtrip_test.dart`](../../../integration_test/settings_backup_roundtrip_test.dart)
  — PWD-005 user-facing surface
- [`integration_test/screenshot_test.dart`](../../../integration_test/screenshot_test.dart)
  — separate pipeline (mobile Android/iOS, not the desktop `-d`
  targets); skipped by both the Linux and macOS loops. See
  [`screenshots`](../screenshots/spec.md)
