> Design deviation (D1): the offline read is implemented at the **widget**
> layer, not as an `icon_service` function. `UnifiedFaviconImage` renders the
> resolved icon via `CachedNetworkImage`, so a URL-returning offline function
> in `icon_service` would still fetch image bytes at render time. Rendering
> `Image.asset`/monogram and bypassing both the fetch stream and
> `CachedNetworkImage` is what actually guarantees zero network. ICON-009/010/011
> are satisfied by this widget-layer path plus the existing online widget on the
> main grid (which warms caches when a site is added).

## 1. Bundled icon assets

- [x] 1.1 Deterministic host-based asset key (`normalizeIconHost`) + unit test asserting `kDefaultSuggestions` keys are unique
- [x] 1.2 `scripts/regen_suggested_icons.sh` developer-run runner; documented as never called by the build
- [ ] 1.3 Run the regenerator and commit assets under `assets/suggested_icons/` (DEFERRED — pending decision on bundling real logos vs monogram-only; trademark/licensing consideration)
- [ ] 1.4 Register `assets/suggested_icons/` in `pubspec.yaml` (DEFERRED — only valid once 1.3 produces assets; empty asset dir breaks the build)
- [x] 1.5 Coverage via monogram fallback: every suggestion renders offline with no network whether or not a bundled asset exists (zero-network test below). A "committed asset per suggestion" assertion is deferred with 1.3.

## 2. Offline read path

- [x] 2.1 `lib/services/bundled_icons.dart`: `bundledIconAssetFor` (asset) + monogram helpers; widget offline branch never calls the network (ICON-009)
- [x] 2.2 No forked icon cache — the offline path does not touch `_faviconCache`/`_svgContentCache` at all (ICON-011 holds trivially)
- [x] 2.3 Bundled-asset loader maps host → committed asset via `normalizeIconHost`

## 3. Wire the suggestions list to offline

- [x] 3.1 Suggestions grid `FaviconImage` in `lib/screens/add_site.dart` passes `offline: true`
- [x] 3.2 Add action: site is added to the main list and rendered by the online widget there, which fetches+caches (ICON-010, existing behavior)
- [x] 3.3 Main site grid and nested webviews unchanged (offline scope is the suggestions list only)

## 4. Reconcile flavors

- [x] 4.1 `flavorDefaultSuggestions` returns `kDefaultSuggestions` for all flavors (SUGGEST-001)
- [x] 4.2 `test/suggested_sites_test.dart` flavor expectation updated
- [x] 4.3 `suggested_sites` backup round-trip unaffected (no key/shape change)

## 5. Zero-network regression test

- [x] 5.1 `test/suggestion_icons_offline_test.dart` renders the curated suggestions offline and asserts `outboundHttp.clientFor()` is never called (SUGGEST-007)
- [x] 5.2 Add-time warming is the existing online-widget behavior; covered by `test/outbound_http_call_sites_test.dart`

## 6. Validate

- [x] 6.1 `fvm flutter analyze` (no new issues) + `fvm flutter test` on the affected suites (27 passed)
- [x] 6.2 `npx openspec validate --changes offline-suggested-site-icons --no-interactive`
- [ ] 6.3 Manual: build fdroid flavor offline and confirm the suggestions list renders with no fetch (DEFERRED — manual device step)
