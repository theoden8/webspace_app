## 1. Bundled icon assets

- [ ] 1.1 Define a deterministic, collision-free asset-key derivation from a suggestion URL (host-based) and a unit test over `kDefaultSuggestions` asserting keys are unique
- [ ] 1.2 Add `scripts/regen_suggested_icons.sh` (or `tool/regen_suggested_icons.dart`): a developer-run runner that fetches current favicons for `kDefaultSuggestions` and writes `assets/suggested_icons/<key>.<ext>`; document it is never called by the build
- [ ] 1.3 Run the regenerator and commit the resulting assets under `assets/suggested_icons/`
- [ ] 1.4 Register `assets/suggested_icons/` in `pubspec.yaml` flutter assets
- [ ] 1.5 Add a test asserting every `kDefaultSuggestions` entry maps to a committed bundled asset (SUGGEST-007, no curated placeholder)

## 2. Offline read path (icon_service)

- [ ] 2.1 Add an offline read entry point in `lib/services/icon_service.dart` (e.g. `suggestionIconStream` / `cachedFaviconUrl`) that consults bundled assets, then `_faviconCache`/`_svgContentCache`, then persisted disk cache, and resolves a placeholder on miss without calling `_proxiedClient` (ICON-009)
- [ ] 2.2 Verify the offline path shares the module-level caches with the network path (no forked cache) (ICON-011)
- [ ] 2.3 Add a bundled-asset loader that maps a suggestion URL to its committed asset via the key derivation from 1.1

## 3. Wire the suggestions list to offline

- [ ] 3.1 Route the suggestions grid tiles in `lib/screens/add_site.dart` (`UnifiedFaviconImage` usage ~750-810) through the offline read path
- [ ] 3.2 Keep the add-suggestion / add-custom-site action on the network-capable fetch path so it warms the shared cache (ICON-010)
- [ ] 3.3 Confirm the main site grid and nested webviews still use the network path (offline scope is the suggestions list only)

## 4. Reconcile flavors

- [ ] 4.1 Change `flavorDefaultSuggestions` in `lib/services/suggested_sites_service.dart:40-41` to return `kDefaultSuggestions` for all flavors (drop the fdroid branch) (SUGGEST-001)
- [ ] 4.2 Update `test/suggested_sites_test.dart` flavor expectation to the reconciled default
- [ ] 4.3 Verify `kExportedAppPrefs` / settings backup round-trip for `suggested_sites` is unaffected

## 5. Zero-network regression test

- [ ] 5.1 Add a test reusing the `RecordingFactory` pattern from `test/outbound_http_call_sites_test.dart`: render the curated suggestions through the offline path and assert `outboundHttp.clientFor()` is never called (SUGGEST-007)
- [ ] 5.2 Add a test that add-time fetch warms the cache so a subsequent offline read resolves from cache with no network (ICON-010)

## 6. Validate

- [ ] 6.1 `fvm flutter analyze` and `fvm flutter test` (suggested sites, icon, outbound-http, settings-backup suites)
- [ ] 6.2 `npx openspec validate --changes offline-suggested-site-icons --no-interactive`
- [ ] 6.3 Manual: build fdroid flavor offline (no network) and confirm the suggestions list renders icons with no fetch
