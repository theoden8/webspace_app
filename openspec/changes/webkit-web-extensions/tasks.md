# Tasks

## 1. Gate

- [x] 1.1 Add `hostRunsWebExtensions` (`AppleOsFloor.webExtensions`: iOS 18.4+ and macOS 15.4+, minor version included; false elsewhere) and the Web extensions `AppPref` with its `ExperimentalFeature` (WEBEXT-001, design D6); verify `fvm flutter test test/apple_os_floor_test.dart test/settings_backup_test.dart` passes (the pref rides `AppPref.values`)
- [x] 1.2 Add the row to the Experimental group's screen and a widget test that the switch shows where `hostRunsWebExtensions` holds and not elsewhere (`test/web_extension_screens_test.dart`, WEBEXT-001); verify it passes

## 2. Import and library

- [x] 2.1 Add `lib/services/web_extension_package_engine.dart`: `readExtensionPackage(bytes)`, the sealed `PackageRead` and `PackageRefusal` (design D5), inflating through the shared `inflateBounded` and `hostDeflateDecoder`; verify `node --test test/js/layers.test.js` and `test/named_arguments_test.dart` pass
- [x] 2.2 Add `test/web_extension_package_test.dart` and `test/helpers/extension_packages.dart`: the cases and planted mistakes of design D9's Package row; test names cite WEBEXT-013; verify `flutter test test/web_extension_package_test.dart` passes
- [x] 2.2a Move the download engine's and the QR codec's bounded inflation into `lib/services/bounded_inflate.dart`, tested by `test/bounded_inflate_test.dart`; verify `flutter test test/bounded_inflate_test.dart test/download_engine_test.dart test/site_settings_qr_codec_test.dart` passes
- [x] 2.3 Add `WebExtensionId` (an extension type with `parse` and `mint`), the library store `WebExtensionLibrary` over `ExtensionFolders`, its folder under the documents directory, and its start in `main`; verify `test/web_extension_library_test.dart` passes (round trip, an import cut short, removal, the launch sweep)
- [x] 2.4 Add App Settings > Extensions (`lib/screens/app_extensions.dart`): import through `FileDialog` of any file, read off the UI thread, the summary before adding (signature not checked), a refusal in its own words, removal (WEBEXT-002); strings in `lib/l10n/app_en.arb`; verify `test/web_extension_screens_test.dart` and `npm run test:js` pass
- [ ] 2.5 Show what WebKit reports it could not load on each library entry (WEBEXT-003); needs the channel of task 4.3

## 3. Per site

- [x] 3.1 Add the `enabledWebExtensions` `SiteField` (QR withheld) and its save and read arms in `lib/web_view_model_json.dart`; clear it in `sanitizeImportedSites` (WEBEXT-011); verify `fvm flutter test test/settings_backup_test.dart test/settings_backup_compat_test.dart` passes and `tool/backup_compat/superset.json` names the field
- [x] 3.2 Add `planExtensionGrants` (design D3) and `test/web_extension_grants_test.dart` with its planted mutants; test names cite WEBEXT-014 and WEBEXT-015; verify it passes
- [x] 3.3 Add `planExtensionAttach` and the sealed `ExtensionAttach` (design D4) and `test/web_extension_attach_test.dart` over the matrix with its planted mutants; test names cite WEBEXT-016; verify it passes
- [x] 3.3a Resolve it in `WebViewModel.sitePosture` into `SitePage.extensions` and hand `AttachExtensions` to the fork's `webExtensions` setting in the factory (`nativeExtensions`, `lib/services/web_extension_native.dart`); verify `test/web_extension_posture_test.dart` passes
- [x] 3.4 `forNested()` keeps `extensions`: `SitePage` is a record with every field required, so dropping it does not compile, and the NESTED-010 test compares the page whole; `test/web_extension_posture_test.dart` checks the nested posture holds the same plan
- [x] 3.5 Add the site's Settings > Extensions screen (`lib/screens/site_extensions.dart`): a switch per library entry, the consent dialog before switching one on with what the site grants, the archive and kiosk lock read from the site's plan (WEBEXT-004, WEBEXT-009); verify `test/web_extension_screens_test.dart` and `npm run test:js` pass
- [ ] 3.6 Add `OrphanStore.webExtensionData` and its sweep in `PageOrphanSweep`; verify `fvm flutter analyze` is clean (the sweep's exhaustive switch) and the orphan sweep test passes

## 4. Fork (iOS and macOS)

- [x] 4.1 In `theoden8/flutter_inappwebview` (branch `claude/web-extensions`, commit 823cb4b), add the `webExtensions` setting to `InAppWebViewSettings` (platform interface, iOS, macOS) and apply it in `preWKWebViewConfiguration` beside the container binding: the per-container controller cache (design D2), contexts loaded from paths, grants applied (D3), refusals of tabs, windows and native messaging; verified: the app's Build IPA and Build macOS steps compiled it with the app pinned to that commit
- [ ] 4.2 Add the `WKWebExtensionControllerDelegate` (design D7): the site's window and tabs, tab and window requests, popup and options page presentation, refusals; verify XCTests in the fork's `RunnerTests` for controller reuse per container id, grants on a loaded context and each refusal pass
- [ ] 4.3 Add the channel the site menu uses: list attached contexts' actions, `performAction`, remove a controller's data records; verify a Dart test of the channel's codec passes
- [x] 4.4 Tag the fork (`v6.2.0-beta.3-privacy-v13.8`, at 823cb4b) and move the `dependency_overrides` ref in `pubspec.yaml`; `flutter pub get` resolves the same commit, which CI built for iOS and macOS

## 5. Runner and UI glue

- [ ] 5.1 Show each attached extension's action in the site menu (`lib/widgets/site_menu.dart`) and call `performAction` on pick (WEBEXT-008); verify a widget test with a fake channel passes
- [ ] 5.2 Remove a deleted site's extension data through `SiteDeletion`; if it adds an await, make it a `Step` of `SiteDeletion.deleteTable` and run `./formal/verify.sh`; verify the deletion test and, if touched, `verify.sh` pass
- [ ] 5.3 Commit the 66 translated `app_*.arb` files in their own commit after the strings of groups 2 and 3; verify `npm run test:js` passes `l10n_coverage` and `l10n_language`

## 6. End to end and bookkeeping

- [ ] 6.1 Add `integration_test/web_extensions_test.dart` (design D9, end to end) and run it in the macOS CI job; verify it passes on a macOS 15.4+ runner and fails with the planted shared controller
- [x] 6.2 Add a map row for the extension plan to `CLAUDE.md` and the slug to its OpenSpec table; verify `npm run test:js` passes
- [ ] 6.3 Remove WEBEXT-001 to WEBEXT-012 from `openspec/unverified.tsv` as their tests land; verify `node --test test/js/spec_verification.test.js` passes
- [ ] 6.4 Run `./scripts/test_all.sh`, `fvm flutter analyze` and `npx openspec validate --no-interactive --all`; verify each exits 0

## Workflow follow-up

- Ask App Review about user-imported extensions (guidelines 2.5.2 and 4.7) before the feature leaves the Experimental group.
- Sync the deltas into `openspec/specs/` and archive the change once merged.
