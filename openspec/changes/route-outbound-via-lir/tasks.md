## 1. Data model

- [ ] 1.1 Add `OutboundPreference` value type in `lib/services/outbound_preference.dart` with `final DomainClaim claim`, `final String targetSiteId`, canonical equality, and `toJson` / `fromJson`. Mirror the file layout of `lib/services/domain_claim.dart` to avoid an import cycle with `web_view_model.dart`.
- [ ] 1.2 Extend `WebViewModel` with `bool routeOutboundLinks` (default `false`) and `List<OutboundPreference> outboundPreferences` (default `[]`).
- [ ] 1.3 `toJson` omits `routeOutboundLinks` when `false` and `outboundPreferences` when empty. `fromJson` defaults both when absent.
- [ ] 1.4 Unit tests in `test/web_view_model_test.dart`: JSON round-trip with explicit values, omission of defaults, legacy-load without the fields, preservation across copy/duplicate.

## 2. Resolver layer

- [ ] 2.1 Add `OutboundResolution` sealed type to `lib/services/link_routing_service.dart` with variants `preference(RoutableSite target)`, `global(RoutingMatch underlying)`, `selfMatch()`.
- [ ] 2.2 Implement `OutboundResolution resolveOutbound(Uri targetUrl, String sourceSiteId, List<OutboundPreference> sourcePrefs, List<RoutableSite> allSites)`:
  - Score each `sourcePrefs[i].claim` against `targetUrl` using LIR-002's specificity table. Skip entries whose `targetSiteId` is not in `allSites`.
  - Highest-scored matching pref returns `preference(target)` unless target == source → `selfMatch`.
  - On no pref match, call existing `resolve(targetUrl, allSites)` and wrap as `global(...)`. Collapse `RoutingSingle` whose site == source to `selfMatch`.
- [ ] 2.3 Unit tests in `test/link_routing_test.dart`:
  - Source pref `exactHost(github.com) → work-gh` beats global `wildcardSubdomain(github.com) → personal-gh`.
  - Source pref skipped when `targetSiteId` not in `allSites`.
  - No pref → returns wrapped `RoutingAmbiguous` unchanged.
  - Self-match collapses (both pref-self and global-self paths).
  - Specificity ordering within `sourcePrefs` (multiple prefs match same URL).

## 3. Dispatch engine

- [ ] 3.1 Add `DispatchNestedFallback` variant to the sealed `DispatchAction` hierarchy in `lib/services/link_intent_dispatch_engine.dart`.
- [ ] 3.2 Add `bool sourceIsParent` field to `DispatchOpenNested` (default `false` to keep inbound callers unchanged).
- [ ] 3.3 Extend `DispatchShowPicker` with `bool offerBind` (default `true`), `bool offerCreate` (already exists), `String? source` (default `null`).
- [ ] 3.4 Add `static DispatchAction dispatchOutbound({required Uri targetUrl, required DispatchableSite source, required List<OutboundPreference> sourcePrefs, required List<DispatchableSite> allSites, required bool routeOutboundLinks})`:
  - If `!routeOutboundLinks` → `DispatchNestedFallback()`.
  - Else call `resolveOutbound(...)`:
    - `preference(t)` → `DispatchOpenNested(siteId: t.siteId, url: targetUrl.toString(), sourceIsParent: true)`.
    - `global(RoutingSingle(t))` → same.
    - `global(RoutingAmbiguous(sites))` → `DispatchShowPicker(winnerSiteIds: sites.map(siteId), offerBind: false, offerCreate: false, source: source.siteId)`.
    - `global(RoutingNone)` → `DispatchNestedFallback()`.
    - `selfMatch` → `DispatchNestedFallback()`.
- [ ] 3.5 Engine tests in `test/link_intent_dispatch_engine_test.dart`: every branch above, plus the launcher-off short-circuit.

## 4. Executor + wiring

- [ ] 4.1 New executor `_executeOutboundDispatch(DispatchAction action, Uri targetUrl, WebViewModel source, _OutboundLaunchArgs sourceArgs)` in `_WebSpacePageState`:
  - `DispatchOpenNested(sourceIsParent: true)` → look up destination model, call `launchUrl(...)` with destination's fields, **without** invoking `_maybeSwitchToAllForSite`.
  - `DispatchShowPicker(source: src)` → reuse `_showDispatchPicker` with the picker reporting `outboundRememberSource: bool` alongside the choice; on remember, append `claimsToAdoptHost(targetUrl.host)` to `source.outboundPreferences` deduplicated, then `_saveWebViewModels()`, then recurse.
  - `DispatchNestedFallback()` → call the existing `launchUrl(...)` with `sourceArgs` (source siteId / cookies / settings).
- [ ] 4.2 Add `outboundLaunchFunc` typedef in `lib/web_view_model.dart` and thread it through `getController(...)` alongside `launchUrlFunc`. Build the closure in `_WebSpacePageState` so it captures the source model + executor.
- [ ] 4.3 Replace the two `launchUrlFunc(url, ...)` call sites in `web_view_model.dart` (`shouldOverrideUrlLoading` → `blockOpenNested` and `onUrlChanged` → `blockOpenNested`) with `outboundLaunchFunc(url)`. The closure decides fallback vs hijack.
- [ ] 4.4 Confirm both nested call sites end up at the same place in legacy and container modes (no engine-specific branching in the executor).

## 5. Picker remember-checkbox

- [ ] 5.1 Add `CheckboxListTile` to `_DispatchPickerSheet` shown only when `widget.source != null`. Label: "Always use this when opening links from {sourceName}". Default `true`.
- [ ] 5.2 Change the sheet's return type from `_DispatchChoice` to `({_DispatchChoice choice, bool rememberSource})` (or a small sealed type) so the executor can branch.
- [ ] 5.3 Suppress the "Send {host} to a site" row when `widget.offerBind == false` and the "Create new site" row when `widget.offerCreate == false`.
- [ ] 5.4 Picker widget tests in `test/link_handling_settings_test.dart` (or sibling): outbound mode hides bind+create, checkbox toggles remember flag, returned tuple is wired correctly.

## 6. UI surface

- [ ] 6.1 `OutboundRoutingSection` widget in per-site settings (`lib/screens/settings.dart`): `SwitchListTile` + `OutboundPreferencesEditor` (visible only when toggle on).
- [ ] 6.2 `OutboundPreferencesEditor` reuses `DomainClaimsEditor` for the claim row primitive, plus a `DropdownButton<String>` over `allSites.where((s) => s.siteId != currentSiteId)`.
- [ ] 6.3 Empty-state copy: when toggle on with zero prefs, render "Falls back to global routing. Add a preference to override for a specific domain.". When toggle off, render "When on, clicks to other domains can route into the site that claims that domain.".
- [ ] 6.4 Widget tests: toggle gates editor visibility, dropdown excludes self, save round-trips through `WebViewModel.toJson`.

## 7. Orphan GC

- [ ] 7.1 Add `_gcOutboundPreferences()` to `_WebSpacePageState`: walk every site, drop prefs whose `targetSiteId` is not in `{m.siteId for m in _webViewModels}`. Persist if anything dropped.
- [ ] 7.2 Call at the three existing cleanup points: app startup (after `_loadWebViewModels`), post-`_deleteSite`, post-`_importSettings`.
- [ ] 7.3 Unit test `test/outbound_preference_gc_test.dart`: builds a `_WebSpacePageState`-shaped fake, asserts dangling targets are dropped at each cleanup site and that no other prefs are touched.

## 8. Backup / import alignment

- [ ] 8.1 Confirm `routeOutboundLinks` and `outboundPreferences` ride `WebViewModel.toJson` automatically (no entry in `kExportedAppPrefs`). Update [test/settings_backup_test.dart](test/settings_backup_test.dart) only if a regression is observed.
- [ ] 8.2 Manual: export a backup with prefs set, wipe install, import, verify prefs and toggle round-trip and that GC drops any prefs whose target site failed to re-import.

## 9. Validation and CI

- [ ] 9.1 `fvm flutter analyze` clean.
- [ ] 9.2 `fvm flutter test` green (new + existing).
- [ ] 9.3 `npx openspec validate route-outbound-via-lir --strict` passes.
- [ ] 9.4 No unintended diffs in `openspec/specs/link-intent-routing/` until the change is archived.

## 10. Manual smoke

- [ ] 10.1 Android: create a GitHub site (logged in), enable launcher mode on DDG, click a `github.com` result, verify the nested view is logged in.
- [ ] 10.2 Android: back-gesture returns to DDG in the same webspace.
- [ ] 10.3 Two GitHub sites (work + personal): add an outbound pref on DDG for `exactHost(github.com) → work`, verify clicks land on work-GitHub even when both sites claim `github.com`.
- [ ] 10.4 Launcher mode off: outbound clicks behave exactly as before (source-settings nested view).
- [ ] 10.5 Self-match: from a Mastodon site, click a link to the same instance — no hijack, navigates in place.
- [ ] 10.6 Delete the work-GitHub site, verify DDG's pref pointing at it is dropped without a snackbar.
- [ ] 10.7 Ambiguous case: two sites claim `github.com`, click from DDG, picker fires; tick remember, repeat the click, verify no picker the second time.
