## 1. Data model

- [ ] 1.1 Add `OutboundPreference` in `lib/services/outbound_preference.dart` (`final DomainClaim claim`, `final String targetSiteId`, equality, `toJson` / `fromJson`), beside `lib/services/domain_claim.dart` to avoid an import cycle with `web_view_model.dart`.
- [ ] 1.2 Extend `WebViewModel` with `bool routeOutboundLinks` (default `false`) and `List<OutboundPreference> outboundPreferences` (default `[]`).
- [ ] 1.3 `toJson` omits `routeOutboundLinks` when `false` and `outboundPreferences` when empty; `fromJson` defaults both when absent.
- [ ] 1.4 `SiteSettingsQrCodec`: `routeOutboundLinks` into `includedKeys`, `outboundPreferences` into `excludedKeys`. The drift test in `test/site_settings_qr_codec_test.dart` builds a default model, whose `toJson` omits default-valued fields; give it a model with non-default outbound fields so these two (and the next omitted-at-default field) are actually classified.
- [ ] 1.5 Tests in `test/web_view_model_test.dart`: round-trip with values, omission at default, legacy load, preservation across copy/duplicate.

## 2. Navigation engine: surface the gesture

- [ ] 2.1 `NavigationDecisionResult` gains `hadGesture`: `effectiveGesture` from `decideShouldOverrideUrlLoading`, `hasRecentGesture` from `decideOnUrlChanged`. `OnUrlChangedHandled` carries it through `handleOnUrlChanged`. No decision changes.
- [ ] 2.2 Tests in `test/navigation_decision_engine_test.dart`: direct gesture, a propagated gesture inside the window, no gesture outside it, on both paths.

## 3. Resolver layer

- [ ] 3.1 Add the `OutboundResolution` sealed type to `lib/services/link_routing_service.dart`: `preference(RoutableSite)`, `global(RoutingMatch)`, `selfMatch()`.
- [ ] 3.2 Implement `resolveOutbound(Uri targetUrl, String sourceSiteId, List<OutboundPreference> sourcePrefs, List<RoutableSite> candidates)`: score preferences with the existing `_score` (port-aware via `hostAuthority`), skipping targets not in `candidates`; ties by list order; otherwise `resolve(targetUrl, candidates)`; collapse any result naming the source to `selfMatch`.
- [ ] 3.3 Add `outboundCandidates(source, sites, sameSide)`: the sites on the source's side of the archive boundary (`sameSide` supplied by the caller from `isArchiveTier` and `_archiveSlices`, so the service does not learn about archives).
- [ ] 3.4 Tests in `test/link_routing_test.dart`: preference beats global single (personal site claims `baseDomain:github.com`); preference skipped when its target is not a candidate; equal scores resolve by order; `exactHost:gist.github.com` beats `baseDomain:github.com`; ambiguous passes through; self-match via preference and via claim; a `host:port` URL scores like `resolve`; archive-tier sites are not candidates of an app-tier source and vice versa.

## 4. Dispatch engine

- [ ] 4.1 Add `DispatchNestedFallback` and `DispatchOpenExternal(url)` to the sealed `DispatchAction` hierarchy in `lib/services/link_intent_dispatch_engine.dart`, and `OutboundFallback { nested, external }`.
- [ ] 4.2 Add `bool sourceIsParent` to `DispatchOpenNested` (default `false`, so inbound callers are unchanged).
- [ ] 4.3 Add `String? source` and `OutboundFallback? fallback` to `DispatchShowPicker`. `offerBind` and `offerCreate` already exist.
- [ ] 4.4 Add `static DispatchAction dispatchOutbound({required Uri targetUrl, required DispatchableSite source, required List<OutboundPreference> sourcePrefs, required List<DispatchableSite> candidates, required OutboundFallback fallback, required bool hadGesture, required bool containersActive})` per the D3 table.
- [ ] 4.5 Tests in `test/link_intent_dispatch_engine_test.dart`: every D3 row, both fallback kinds, the no-gesture and legacy-engine short-circuits.
- [ ] 4.6 Extend `_describeDispatchAction` for the new variants (log entries stay `LogSensitivity.sensitive`).

## 5. Executor and wiring

- [ ] 5.1 Add `typedef OutboundLinkHandler = bool Function(String url, NavigationDecision decision, bool hadGesture)` in `lib/web_view_model.dart`; thread `onOutboundLink` through `getController(...)` / `getWebView(...)`.
- [ ] 5.2 In the four branches of `getWebView` (`blockOpenNested` and `blockOpenExternal`, in `shouldOverrideUrlLoading` and in `onUrlChanged`), call `onOutboundLink` first and run the existing `launchUrlFunc(...)` / `launchUrlInSystemBrowser(...)` line only when it returns `false`. The `onUrlChanged` navigate-back stays ahead of both.
- [ ] 5.3 In `_WebSpacePageState`, build the hook per model: read `routeOutboundLinks` live, compute candidates, call `dispatchOutbound`; return `false` for the two fallback actions; otherwise schedule `_executeOutboundDispatch` and return `true`.
- [ ] 5.4 `_executeOutboundDispatch`: `DispatchOpenNested(sourceIsParent: true)` runs `_executeOpenNested` without `_maybeSwitchToAllForSite`; `DispatchShowPicker(source: ...)` runs the picker (section 6).
- [ ] 5.5 Proxy return path (D6): when the routed open changed the process-global proxy (Android without router mode, Linux), await the route and re-run the source's activation before it is interactive. Keep the source out of `_loadedIndices` until then.
- [ ] 5.6 `test/js/outbound_link_funnel.test.js`: every `blockOpenNested` / `blockOpenExternal` branch in `lib/web_view_model.dart` consults `onOutboundLink` before launching. Add it to the runner `npm run test:js` picks up.

## 6. Picker outbound mode

- [ ] 6.1 `_showDispatchPicker` passes `offerBind`, `offerCreate`, `source` and `fallback` to `_DispatchPickerSheet`; the sheet hides the send-or-open-to-a-site row when `offerBind` is false (it shows it whenever a site exists today) and the create row when `offerCreate` is false.
- [ ] 6.2 In outbound mode, add the "Open without routing" row (`_DispatchChoiceFallback`) and the remember `CheckboxListTile` under the winner rows ("Always use this when opening links from {sourceName}", default checked).
- [ ] 6.3 `_DispatchChoiceOpen` carries `remember`. On remember, append `claimsToAdoptUrl(targetUrl)` entries the source does not already hold by claim, `_saveWebViewModels()`, then open. `_DispatchChoiceFallback` runs `_launchNestedForModel(source, url)` or `launchUrlInSystemBrowser(url)`. A null result opens nothing.
- [ ] 6.4 Widget tests: outbound mode hides bind and create, shows the fallback row, the checkbox drives `remember`, dismissal returns null; inbound mode is unchanged.

## 7. UI surface (Behaviour screen, BEHAV-003)

- [ ] 7.1 `SiteBehaviourValues` gains `routeOutboundLinks` and `outboundPreferences`; `SettingsScreen` keeps them in its fields and dirty snapshot and saves them with the rest.
- [ ] 7.2 `SiteBehaviourScreen`: the routing switch between Block auto-redirects and Open external links in browser, with a `HintButton` (title = the row's title, label `Flexible`) and no subtitle; disabled with the state subtitle "Needs per-site containers" on the legacy engine.
- [ ] 7.3 The "Routing preferences" row under the switch while it is on; subtitle `loc.outboundPreferencesCount(n)`, or "Global routing only" when empty. It opens `OutboundPreferencesScreen`.
- [ ] 7.4 `OutboundPreferencesScreen` in `lib/screens/link_handling_settings.dart`, reusing `_AddClaimDialog` and `_claimLabel`; the target dropdown lists the site's candidates minus itself; a second target for an existing claim is refused.
- [ ] 7.5 `_buildBehaviourRow` names the routing switch when it is on (BEHAV-002).
- [ ] 7.6 Strings: code plus `lib/l10n/app_en.arb` (every key with a `description`) in one commit, the 66 translations in the next, pushed together. Classify any new UI file in `test/js/l10n_no_hardcoded_text.test.js`.
- [ ] 7.7 Tests in `test/site_behaviour_screen_test.dart`: row order, hint and no subtitle, legacy disable, preferences row visibility, dirty-snapshot round-trip. `test/js/settings_hint_placement.test.js` and `test/js/settings_title_row_overflow.test.js` pass.

## 8. Orphan GC

- [ ] 8.1 A pure prune function (`OutboundPreferenceGc.prune(sites, candidatesOf)`) returning the sites whose lists changed.
- [ ] 8.2 Call it at startup inside `_loadWebViewModels` (set `_needsMigrationResave` when it changed anything), in `_deleteSite` before its `_saveWebViewModels`, in `_importSettings` on `restoredSites`, and in `_moveSiteToArchive` / `_moveSiteOutOfArchive`.
- [ ] 8.3 `test/outbound_preference_gc_test.dart`: dangling targets dropped at each point; cross-boundary targets dropped on both archive moves; entries whose target remains are untouched. Extend `test/archive_neutrality_test.dart` with a site holding a preference so app-tier bytes stay identical with and without an archive.

## 9. Backup and import alignment

- [ ] 9.1 Confirm both fields ride `WebViewModel.toJson` (no `kExportedAppPrefs` entry); touch `test/settings_backup_test.dart` only if a regression shows.
- [ ] 9.2 Manual: export with preferences set, wipe, import; preferences and toggle round-trip, and a hand-edited dangling entry is dropped.

## 10. Validation and CI

- [ ] 10.1 `fvm flutter analyze` clean.
- [ ] 10.2 `fvm flutter test` and `npm run test:js` green.
- [ ] 10.3 `npx openspec validate route-outbound-via-lir --strict --no-interactive` passes.
- [ ] 10.4 No edits to `openspec/specs/link-intent-routing/` or `openspec/specs/site-behaviour/` until the change is archived.

## 11. Manual smoke

- [ ] 11.1 Android: a GitHub site signed in, routing on for DuckDuckGo; a `github.com` result opens the GitHub site's screen signed in.
- [ ] 11.2 Back returns to DuckDuckGo in the same webspace.
- [ ] 11.3 Android without router mode, DuckDuckGo and GitHub on different proxies: after back, DuckDuckGo reloads under its own proxy with its back stack.
- [ ] 11.4 Two GitHub sites: a DuckDuckGo preference `exactHost(github.com) -> work` routes to work even though both claim `github.com`.
- [ ] 11.5 Routing off: taps behave exactly as before.
- [ ] 11.6 Self-match: a Mastodon site claiming `joinmastodon.org` opens that link with its own posture.
- [ ] 11.7 Delete the work GitHub site; DuckDuckGo's preference naming it is gone, with no snackbar.
- [ ] 11.8 Ambiguous: picker appears; with remember, the next tap does not show it; "Open without routing" opens with DuckDuckGo's posture.
- [ ] 11.9 Routing and external links both on: GitHub results route in-app, unclaimed links go to the system browser.
- [ ] 11.10 Legacy engine (or a device without `MULTI_PROFILE`): the switch is disabled and taps behave as before.
