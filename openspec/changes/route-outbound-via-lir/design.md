## Context

LIR handles **inbound** URLs (Android `ACTION_SEND`, the iOS/macOS Share Extension, `webspace://`) through `LinkRoutingService.resolve` and `LinkIntentDispatchEngine`. Cross-domain navigation inside a site's own webview bypasses it:

- `NavigationDecisionEngine.decideShouldOverrideUrlLoading` (and `decideOnUrlChanged` for a server-side 3xx) returns `blockOpenNested` for a cross-domain navigation that survived the `blockAutoRedirects` and background-site checks, or `blockOpenExternal` when the site has `externalLinksInBrowser` on and none of its `effectiveDomainClaims` covers the target (NESTED-009).
- `WebViewModel.getWebView` answers `blockOpenNested` with `launchUrlFunc(url, ...)` carrying the source's whole posture (NESTED-010) and `blockOpenExternal` with `launchUrlInSystemBrowser(url)`. There is one such pair in the `shouldOverrideUrlLoading` callback and one in `onUrlChanged`.
- `target="_blank"` anchors reach the same path, because NESTED-008 rewrites them to `_self`. Script `window.open` never opens a nested screen: `onCreateWindow` dismisses everything except captcha challenges (NESTED-013).

That is right for "open this article in the private context of the search engine I'm using" and wrong for "open this GitHub link in my GitHub site, where I'm signed in". LIR has the data (per-site `domainClaims`) to make the second choice; the outbound path never asks it.

What the inbound side already provides and this change reuses:

- `_executeOpenNested(DispatchOpenNested)` in `_WebSpacePageState`. On Android without router mode, and on Linux, it runs the PROXY-008 sequence for the chosen site before pushing the screen and fails closed when the proxy cannot be applied (the SEC-004 fix). It then opens through `_launchNestedForModel`, the one funnel a nested screen of an existing site opens through (NESTED-010, gated by `test/nested_webview_field_parity_test.dart` and `test/js/nested_webview_posture_parity.test.js`). It also calls `_maybeSwitchToAllForSite` (WEBSPACE-012), which outbound must skip.
- `_DispatchPickerSheet` / `_showDispatchPicker`, the LIR-010 sheet. `DispatchShowPicker` already carries `offerBind` and `offerCreate`, but the sheet reads neither directly: it shows the send-to-a-site row whenever any site exists, and takes `canCreate` from the executor.
- `LinkRoutingService.claimsToAdoptUrl`, the port-aware successor of `claimsToAdoptHost`, and `urlMatchesAnyClaim`, which the external-links path already uses to keep claimed links in the app.

Constraints from the codebase as it stands:

- Per-site settings MUST reach nested webviews (CLAUDE.md, NESTED-010). A routed screen opens through `_launchNestedForModel(destination, url)`, never a hand-built `launchUrl` call, so it inherits the parity gates.
- Engines stay pure Dart. Resolution lives in `link_routing_service.dart`, the decision in `link_intent_dispatch_engine.dart`, the executor in `_WebSpacePageState`.
- The legacy cookie engine gives a nested screen the shared jar (ISO-007), not the destination's cookies (D10).
- The archive boundary (ARCH-001, ARCH-006): app-tier persisted state must not name archive-tier sites, and an archive-tier session must not write into an app-tier container (D11).
- Link handling lives on the per-site Behaviour screen (BEHAV-001), and a settings row keeps its explanation behind its hint (HINT-001, HINT-002) (D8).

## Goals / Non-Goals

**Goals:**
- A tap on a GitHub link inside DuckDuckGo lands in the user's GitHub site (container, cookies, posture) once the user opts DuckDuckGo into routing.
- A source preference settles multi-candidate cases (work GitHub vs personal GitHub) without a picker every time.
- Anything routing does not claim keeps today's destination: the source-posture nested screen, or the system browser when `externalLinksInBrowser` sends it there.
- Back from a routed screen returns to the source in the webspace the user started in, with the source's proxy in force.

**Non-Goals:**
- Changing what `NavigationDecisionEngine` decides. It only starts returning the effective gesture it already computes (D2).
- Routing inside a nested screen. It has nowhere further to nest and navigates in place (NESTED-010).
- Routing script popups. There are none to route (NESTED-013).
- Auto-creating a site for an unmatched outbound URL.
- Changing inbound LIR: picker contents and webspace switching for shared URLs stay as in `default-app-for-links`.

## Decisions

### D1. Outbound preference data shape

Per-site additions to `WebViewModel`:

```dart
class OutboundPreference {
  final DomainClaim claim;        // reused from link-intent-routing
  final String targetSiteId;      // which site to route to
}

class WebViewModel {
  bool routeOutboundLinks;                       // default false
  List<OutboundPreference> outboundPreferences;  // default []
}
```

`OutboundPreference` lives in `lib/services/outbound_preference.dart`, beside `lib/services/domain_claim.dart`, for the same import-cycle reason that file was extracted.

```json
{
  "routeOutboundLinks": true,
  "outboundPreferences": [
    {"claim": {"kind": "exactHost", "value": "github.com"}, "targetSiteId": "work-github-abc123"},
    {"claim": {"kind": "wildcardSubdomain", "value": "github.com"}, "targetSiteId": "work-github-abc123"}
  ]
}
```

`toJson` omits `routeOutboundLinks` when `false` and `outboundPreferences` when empty. The list holds at most one entry per claim: the picker writeback dedups by claim (D4), and the editor refuses a second target for a claim it already has, so "which target does this claim mean" always has one answer.

QR share: `routeOutboundLinks` goes in `SiteSettingsQrCodec.includedKeys`, `outboundPreferences` in `excludedKeys`. Every entry names a device-local `siteId`, which QR-003 already refuses to share; the receiver's sites have other ids. The codec's drift test builds a default model, and defaults are omitted from `toJson`, so a field that is omitted at its default never reaches the drift check (`domainClaims` and `externalLinksInBrowser` slip past it today). The test gains a model with non-default outbound fields.

**Alternative considered**: a `Map<String, String>` keyed by destination host or base domain. Rejected: `DomainClaim` granularity lets `wildcardSubdomain(google.com) -> google-site` cover every Google subdomain the way LIR-001 claims do, and reuses the claim canonicalisation and editor.

**Alternative considered**: a global registry keyed by `(sourceSiteId, claim)`. Rejected: per-site state round-trips through `WebViewModel.toJson` (settings-backup, site-editing); a registry would need its own GC and import/export plumbing for no gain.

### D2. When routing runs, and the resolution order

Routing runs only when every gate holds (LIR-014):

1. `source.routeOutboundLinks`.
2. `NavigationDecisionEngine` returned `blockOpenNested` or `blockOpenExternal` for the source's own webview.
3. The navigation carried an effective gesture. `decideShouldOverrideUrlLoading` computes `effectiveGesture` and `decideOnUrlChanged` computes `hasRecentGesture`; both are dropped today. `NavigationDecisionResult` and `OnUrlChangedHandled` gain `hadGesture` so the caller can read it without re-deriving the propagation window. Without this gate, a page on a site with `blockAutoRedirects` off could script-navigate to `https://github.com/settings/...` and have it load in the user's signed-in GitHub container with no click. Today the same navigation lands in the source's own container.
4. The container engine is active (D10).

Candidates are the sites on the source's side of the archive boundary (D11).

`LinkRoutingService.resolveOutbound(targetUrl, sourceSiteId, sourcePrefs, candidates)` returns `OutboundResolution.preference(site)`, `OutboundResolution.global(RoutingMatch)` or `OutboundResolution.selfMatch()`:

1. Score each preference whose target is a candidate with the resolver's own scoring (`_score`, port-aware through `hostAuthority`; `wildcardSubdomain(x)` does not match `x` itself). Highest score wins; among equal scores the earlier entry wins, so the editor's order is the precedence.
2. No preference matches: `resolve(targetUrl, candidates)`.
3. A result naming the source collapses to `selfMatch`. Because the navigation already failed the same-domain test, a self-match means the source claims a domain outside its own navigation domain (a Mastodon site claiming `joinmastodon.org`).

**Composition with `externalLinksInBrowser`**: a resolution that names a destination wins over `blockOpenExternal`; one that names none leaves the navigation engine's decision in force. So a DuckDuckGo site with both switches on sends GitHub results to the GitHub site and everything unclaimed to the system browser. The other order (external first) would make routing dead on any site with external links on, because NESTED-009 only keeps the source's own claimed links in the app, and those resolve to `selfMatch`.

**Source-preference-wins rule**: a preference at any score beats a global winner at any score. The user wrote the preference from this source's context, which is a more specific signal than the global claim graph, and the work-vs-personal-GitHub case needs it.

### D3. Dispatch shape

`LinkIntentDispatchEngine.dispatchOutbound({targetUrl, source, sourcePrefs, candidates, fallback, hadGesture, containersActive})`, where `fallback` is `OutboundFallback.nested` or `OutboundFallback.external` (the navigation engine's decision):

| Input | Action |
|-------|--------|
| no gesture, or legacy engine | fallback action |
| `preference(site)` | `DispatchOpenNested(siteId, url, sourceIsParent: true)` |
| `global(RoutingSingle(site))` | `DispatchOpenNested(siteId, url, sourceIsParent: true)` |
| `global(RoutingAmbiguous(sites))` | `DispatchShowPicker(winnerSiteIds, offerBind: false, offerCreate: false, source, fallback)` |
| `global(RoutingNone)`, `selfMatch` | fallback action |

The fallback action is `DispatchNestedFallback()` for `OutboundFallback.nested` and `DispatchOpenExternal(url)` for `OutboundFallback.external`. The toggle-off case never reaches the engine (D5).

`DispatchOpenNested` gains `sourceIsParent` (default `false`, so inbound callers are unchanged). `DispatchShowPicker` gains `source` (`String?`) and `fallback` (`OutboundFallback?`); `offerBind` and `offerCreate` already exist.

**Alternative considered**: collapse `DispatchOpenNested` and the fallbacks into one variant with a `useSourceSettings` flag. Rejected: destination settings versus source settings is the whole point of the change, and the action types are sealed-class shaped for distinct semantics.

### D4. Picker in outbound mode

`_showDispatchPicker` passes the sheet `offerBind`, `offerCreate` (today it passes only `canCreate` and decides the bind row itself), `source` and `fallback`. In outbound mode the sheet:

1. Lists one "Open in {site}" row per winner.
2. Adds "Open without routing", which returns `_DispatchChoiceFallback` and runs the fallback action.
3. Hides the send-or-open-to-a-site row (`offerBind == false`) and the create row (`offerCreate == false`). Mid-browse is not the moment to change a destination's claims or spawn a site.
4. Shows "Always use this when opening links from {sourceName}" beneath the winners, checked by default: the user already chose a winner, and remembering is what stops the picker recurring.
5. Returns `_DispatchChoiceOpen(site, remember: bool)`. Dismissal returns null, and null opens nothing, the same as the inbound sheet.

On `remember`, the executor appends `OutboundPreference(claim, site.siteId)` for each claim of `claimsToAdoptUrl(targetUrl)` that the source does not already hold (by claim, whatever the target), persists with `_saveWebViewModels`, then executes `DispatchOpenNested(sourceIsParent: true)`. `claimsToAdoptUrl` rather than `claimsToAdoptHost`, so a `host:port` URL yields its one port-bearing `exactHost` as the inbound bind does.

### D5. Executor wiring

`getController(...)` / `getWebView(...)` gain an optional hook, supplied by `_WebSpacePageState` for every site:

```dart
typedef OutboundLinkHandler = bool Function(
    String url, NavigationDecision decision, bool hadGesture);
```

Each of the four branches in `web_view_model.dart` (`blockOpenNested` and `blockOpenExternal`, in `shouldOverrideUrlLoading` and in `onUrlChanged`) calls the hook first and runs its current line only when the hook returns `false`:

```dart
if (onOutboundLink?.call(url, result.decision, hadGesture) ?? false) return false;
launchUrlFunc(url, /* whole chain, unchanged */);
```

The hook reads the source's live `routeOutboundLinks` (settings edits apply without a webview rebuild), applies the gates and runs the pure `dispatchOutbound` synchronously. For `DispatchNestedFallback` and `DispatchOpenExternal` it returns `false`, so the call site does exactly what it does today and the fallback needs no second copy of the launch chain. For `DispatchOpenNested` and `DispatchShowPicker` it schedules `_executeOutboundDispatch` and returns `true`. With the toggle off, no resolver runs and no new code path is taken.

`_executeOutboundDispatch`:
- `DispatchOpenNested(sourceIsParent: true)`: `_executeOpenNested` without `_maybeSwitchToAllForSite`, plus the return path in D6.
- `DispatchShowPicker(source: ...)`: `_showDispatchPicker`; on a winner, optional writeback (D4) then the routed open; on "Open without routing", `_launchNestedForModel(source, url)` or `launchUrlInSystemBrowser(url)`. This is the one place the fallback runs from `main.dart`, and it goes through the NESTED-010 funnel.

### D6. Webspace and proxy on the way back

`sourceIsParent: true` skips `_maybeSwitchToAllForSite`. The user is mid-browse in webspace X; routing must not relocate them. This intentionally differs from inbound LIR-011, where the user came from outside the app and the "Switched to All" snackbar makes the destination discoverable.

The proxy is the part that does not come back by itself. On Android without router mode, and on Linux, `_executeOpenNested` unloads every loaded site whose effective proxy differs from the destination's, which includes the source whenever the two differ, and applies the destination's proxy. `launchUrl` awaits the route, and nothing after the pop re-applies anything. So the executor awaits the push and, when it changed the process-global proxy, re-runs the source's activation (`_setCurrentIndex` for the source's index, which runs the PROXY-008 sequence and rebuilds it with its captured state queued) before the source is interactive. The capture in `_unloadSiteForOtherReason` is what makes the source's back stack survive. Until that re-activation the source stays out of `_loadedIndices`, so nothing is built under the wrong proxy. The inbound LIR-011 open has the same shape and may want the same return path (Open Question 4).

### D7. Orphan GC for `targetSiteId`

An entry is an orphan when its target is not an LIR-014 candidate of its source: the site is gone, or it is across the archive boundary.

- **Startup**: pruned in memory inside `_loadWebViewModels`, which then sets `_needsMigrationResave`, so the post-paint `DeferredStartupEngine.runPostPaintMaintenance` persists it with the rest of the load-time migration. No extra prefs write on the first-frame path.
- **`_deleteSite`**: pruned on the survivors before its existing `_saveWebViewModels`, so a delete stays one persist.
- **`_importSettings`**: pruned on `restoredSites` before they replace the live list. Import is all-or-nothing now (the whole backup is parsed before live state is touched), so a dangling entry comes from the backup itself: a hand-edited file, or a site that pointed at a deleted one before the prune ran.
- **Archive moves**: `_moveSiteToArchive` and `_moveSiteOutOfArchive` drop the entries the move leaves pointing across the boundary, in both directions. Without this, the app-tier list would name an archive-tier site while the archive is open and not after it closes, which is an ARCH-001 break.

No user notification: an orphaned preference is silent state, not configuration the user should be alerted about. `resolveOutbound` ignores targets that are not in its live `candidates` argument anyway, which covers the window before a prune runs.

### D8. UI surface

Per-site link handling lives on the Behaviour screen (BEHAV-001), so the routing controls go into its "Link handling" group (BEHAV-003):

```
Link handling
  Block auto-redirects
  Route links to my sites                 [switch] (?)   off by default
    Routing preferences   2 preferences   >             only while the switch is on
  Open external links in browser          [switch] (?)
  Domain claims                           (editor)
```

- Routing sits above external links because it wins over them (D2); the claims editor stays last, under the switch whose hint points at it.
- The switch's explanation ("taps on links to other domains open in the site that claims them, with that site's login and settings; links no site claims behave as before") goes in its `HintButton`. The switch has no subtitle, except the state string "Needs per-site containers" when the legacy engine disables it (D10).
- The preferences row's subtitle is state-derived: `loc.outboundPreferencesCount(n)`, or "Global routing only" when `n == 0`. It opens `OutboundPreferencesScreen`, which lists `claim -> target` rows. Adding a row reuses `_AddClaimDialog` and `_claimLabel` from `lib/screens/link_handling_settings.dart`, so the new editor lives in that file beside `DomainClaimsEditor` (both are private there today). The target dropdown lists the site's LIR-014 candidates minus the site itself.
- Both fields ride `SiteBehaviourValues` and the settings screen's dirty snapshot (BUG-006, EDIT-009). The claims editor stays the one control that writes straight to the model.
- `_buildBehaviourRow` adds the switch to its "names of what is on" summary (BEHAV-002).

New strings go through `app_en.arb` with descriptions; the 66 translations ride their own commit (CLAUDE.md).

### D9. Tests

Pure Dart, fast:

- `test/link_routing_test.dart`: `resolveOutbound`: preference beats global single; preference skipped when its target is not a candidate; equal-score preferences resolve by list order; global single and ambiguous pass through; self-match through a preference and through a claim; port-bearing URLs score like `resolve`.
- `test/link_intent_dispatch_engine_test.dart`: `dispatchOutbound`: every table row in D3, including no-gesture and legacy-engine fallbacks and both fallback kinds.
- `test/navigation_decision_engine_test.dart`: `hadGesture` on both decisions: a direct gesture, a propagated one inside the window, none outside it.
- `test/web_view_model_test.dart`: JSON round-trip of both fields, omission at default, legacy load.
- `test/site_settings_qr_codec_test.dart`: the toggle is shared, the list is not; the drift test gains a model with non-default outbound fields.
- `test/outbound_preference_gc_test.dart` (new): the prune as a pure function over `(sites, candidatesOf)`, exercised for startup, delete, import and both archive moves; untouched entries stay.
- `test/site_behaviour_screen_test.dart`: row order, hint without subtitle, legacy-engine disable, preferences row visibility, dirty-snapshot round-trip.
- Picker: outbound mode hides bind and create, shows "Open without routing", the checkbox drives `remember`, dismissal returns null.

Structural: `test/nested_webview_field_parity_test.dart` already holds every `launchUrl(` in `main.dart` to the whole chain, and the routed open adds no new one. A new `test/js/outbound_link_funnel.test.js` asserts each of the four `blockOpenNested` / `blockOpenExternal` branches in `web_view_model.dart` consults `onOutboundLink` before launching, so a fifth branch cannot skip routing silently.

Manual: DuckDuckGo with routing on, on Android: a GitHub result lands in the GitHub site signed in; back returns to DuckDuckGo in the same webspace; with mismatched proxies, DuckDuckGo comes back under its own proxy.

### D10. Container engine only

On the legacy engine a nested screen uses the singleton `CookieManager` (ISO-007): whatever jar the active site left materialised. A routed screen there would show GitHub's page with the source's cookies, and GitHub's cookies set during the visit would land in the jar the source's next capture reads. That is worse than today, not better. So the gate in D2 falls back on the legacy engine, and the Behaviour switch is disabled there with a state subtitle. The inbound LIR-011 open already claims to carry "the chosen site's container settings" on both engines, and on the legacy engine it cannot. That is out of scope here and listed as Open Question 3.

### D11. The archive boundary

Candidates for an app-tier source are app-tier sites; for an archive-tier source, the sites of its own open archive slice (`_archiveSlices`). Routing across the boundary fails both ways: an app-tier preference naming an archive site would put an archive `siteId` into app-tier prefs (ARCH-001), and an archive session opening an app-tier site would write archive-originated browsing into an app-tier container (ARCH-006). The preferences editor offers only candidates, and D7 prunes what a tier move leaves behind.

## Risks / Trade-offs

- **[Risk] The user turns routing on for a site that needs same-session nested context** (a CMS linking to an embedded report that needs the CMS cookies). Mitigation: opt-in per site, and the hint says what changes.
- **[Risk] A preference points at a deleted site between prunes.** Mitigation: `resolveOutbound` checks the live candidate list, not the persisted preferences (LIR-017).
- **[Risk] The picker fires mid-browse.** Mitigation: only on a true tie between candidates; the checkbox is checked by default, and "Open without routing" keeps the old behaviour one tap away.
- **[Risk] An incognito destination does not share the destination's live session.** On iOS, macOS and Linux an incognito site owns no named container (`siteOwnsContainerProfile` is false under incognito), so its nested screen gets an ephemeral store of its own: the destination's posture, not its session. Android binds the named profile even under incognito. Archive-tier destinations are forced incognito and behave the same way. This is how every nested screen for an incognito site already behaves; routed screens inherit it.
- **[Risk] Proxy-mismatched routing costs the source a cold start** on Android without router mode and on Linux (D6). Mitigation: the captured state restores the back stack; router mode (PROXY-013) removes the eviction where it is available.
- **[Trade-off] Preferences are directional** (source to destination). Changing a destination's claims does not change them, and renaming a destination does not break them, since they name a `siteId`.
- **[Trade-off] One extra resolver pass per routed gesture.** O(claims x sites), a few hundred string comparisons for a typical user. Not measured; not expected to matter.

## Migration Plan

1. Data model and JSON migration (silent until the toggle is on); QR classification.
2. `hadGesture` on the navigation results; `resolveOutbound` and `dispatchOutbound` with pure-Dart tests.
3. The `onOutboundLink` hook in the four branches and `_executeOutboundDispatch`, including the proxy return path.
4. Behaviour-screen rows and the preferences screen.
5. Picker outbound mode and writeback.
6. The prune at the four points.

Each step ships on its own. Rollback: the fields stay in the model; removing the switch from the Behaviour screen removes the effect.

## Open Questions

1. Should the toggle and preferences be cloned when a site is duplicated? Proposal: clone; the intent belongs to the source identity.
2. Should a matching preference route even with the toggle off? Proposal: no. The toggle gates the whole feature, so with it off, outbound taps take exactly today's path.
3. The inbound LIR-011 nested open on the legacy engine uses the shared jar (ISO-007) while its requirement promises the chosen site's container settings. Fix in the base change, or document the gap there?
4. The inbound LIR-011 open leaves the chosen site's proxy applied after its screen pops, on Android without router mode and on Linux, with the formerly active site unloaded. Adopt D6's return path for inbound too?
