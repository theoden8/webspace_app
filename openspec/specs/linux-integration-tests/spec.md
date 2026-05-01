# Linux Integration Tests Specification

## Purpose

Drive the full Flutter app under WPE WebKit + GTK on Linux through the
`integration_test` framework, against a real Xvfb display, dbus session,
and Secret Service provider — the surface that the unit tests in
`test/` and the JS shim tests in `test/js/`/`test/browser/` cannot
reach. Goal: catch UI / orchestration regressions that depend on app
initialization order, async race conditions across SharedPreferences
+ secure storage, and ScaffoldMessenger / Navigator interaction across
async gaps.

## Status

- **Status**: Implemented
- **Platforms**: Linux desktop (CI: GitHub Actions debian:sid container)
- **CI Integration**: GitHub Actions
  ([`build-and-test.yml`](../../../.github/workflows/build-and-test.yml)
  → `build-linux` job → `Run Linux integration tests` step)

---

## Pipeline Architecture

The pipeline has three layers:

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

### Requirement: LINTEG-001 — Headless Secret Service

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

### Requirement: LINTEG-002 — Sid container for WPE WebKit ≥ 2.50

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

### Requirement: LINTEG-003 — Plugin dialogs mocked at the platform-interface level

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

### Requirement: LINTEG-004 — Demo mode + SharedPreferences mock

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

### Requirement: LINTEG-005 — Pop-then-callback navigation pattern

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

### Requirement: LINTEG-006 — Self-diagnosing widget-tree dumps on failure

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

### Requirement: LINTEG-007 — Existing scenarios

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

### Requirement: LINTEG-008 — Adding a new scenario

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
- **Webview rendering not exercised**: the smoke test reaches App Settings
  without ever loading a webview; `settings_backup_roundtrip_test.dart`
  is the same. Webview-loading scenarios (Tier C of the integration
  test backlog) may surface a new class of headless rendering issues
  that this spec doesn't cover.
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
  `Install pass-secret-service`, and `Run Linux integration tests` steps.

### Existing
- [`integration_test/settings_smoke_test.dart`](../../../integration_test/settings_smoke_test.dart)
  — harness pin
- [`integration_test/settings_backup_roundtrip_test.dart`](../../../integration_test/settings_backup_roundtrip_test.dart)
  — PWD-005 user-facing surface
- [`integration_test/screenshot_test.dart`](../../../integration_test/screenshot_test.dart)
  — separate pipeline (Android/iOS, not Linux); see
  [`screenshots`](../screenshots/spec.md)
