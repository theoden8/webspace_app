## Why

Today, when the user clicks a cross-domain link inside a site (e.g. a GitHub link in DuckDuckGo's search results), `NavigationDecisionEngine` returns `blockOpenNested` and `web_view_model.dart` pushes an `InAppWebViewScreen` carrying the **source** site's settings — DDG's cookies, DDG's container, DDG's user scripts. The user lands on GitHub signed out, with a session scoped to DDG, even though they already have a configured GitHub site with their login.

LIR (`link-intent-routing`) already classifies an arbitrary URL against per-site `domainClaims` for inbound shares; the same resolver could decide which existing site is the *right* container for an outbound link. This change wires the resolver into the cross-domain nested-open path so a click from a launcher-style site (DDG, Google, Kagi, HN frontpage) lands inside the user's claimed destination site instead of trapping in the source's session.

UX has to be opt-in per source: nesting today is silent and back-gesture-reversible, so adding a mid-browse picker or even a snackbar on every outbound link would regress launcher-style flows. The toggle stays off by default; flipping it on DDG/Google is a one-time act.

## What Changes

- **Per-site outbound-routing toggle** (`WebViewModel.routeOutboundLinks`, default `false`). When `true`, cross-domain navigations originating from this site run through LIR before the existing nested-open path is invoked.
- **Per-site outbound preferences** (`WebViewModel.outboundPreferences: List<OutboundPreference>`, where each entry is `(DomainClaim claim, String targetSiteId)`). Lets a source site override the global LIR resolver when the user has multiple sites that could match the same destination (e.g. work-GitHub vs personal-GitHub). Source preference wins over global LIR per the resolution order below.
- **Outbound dispatch path on `LinkIntentDispatchEngine`** mirroring the inbound shape: a new entry point `dispatchOutbound({source, targetUrl, sites})` returns one of:
  - `DispatchOpenNested(targetSiteId, url, sourceIsParent: true)` — silent hijack to the destination site's container, opened as a nested `InAppWebViewScreen` so back-gesture still returns to the source.
  - `DispatchShowPicker(...)` — for ambiguous resolver results, only when the source has launcher mode on; reuses the LIR-010 sheet, gains a "Always use this from {source}" checkbox that writes back into source's `outboundPreferences`.
  - `DispatchNestedFallback()` — the source site's existing nested launch, unchanged. Used for no-match, self-match (target resolves to source), and when launcher mode is off.
- **Resolution order** when launcher mode is on:
  1. Source's `outboundPreferences`, highest-specificity claim first (`exactHost` > `wildcardSubdomain` > `baseDomain`).
  2. Global `LinkRoutingService.resolve(targetUrl, allSites)` — accepts only `RoutingSingle`.
  3. Ambiguous → picker (with remember checkbox).
  4. No match, or any match equal to the source site itself → `DispatchNestedFallback`.
- **Picker writeback**: when the user picks "Open in {Site}" from the launcher-mode picker with the remember box ticked, an `OutboundPreference(claim: exactHost(host) + wildcardSubdomain(baseDomain), targetSiteId: site.siteId)` is appended to the source's prefs (deduplicated). The picker's "bind to site" and "create new site" options are suppressed in the outbound flow — outbound is not the right moment to mutate the destination site's claims or to spawn a brand-new site.
- **No webspace switch on outbound hijack**: unlike inbound (WEBSPACE-011), an outbound hijack opens the destination as a nested screen without activating its webspace. Back-gesture returns the user to the source site in the webspace they started in.
- **GC** of dangling `targetSiteId` entries in `outboundPreferences` at the three existing cleanup sites (`_deleteSite`, post-import settings, app startup). Mirrors the cookie-secure-storage orphan pattern.
- **Per-site settings UI**: under each site, a "Outbound link routing" section with the master toggle and a `OutboundPreferencesEditor` (claim pattern via the existing `DomainClaimsEditor` widget + a target-site dropdown).
- **Settings backup**: `routeOutboundLinks` and `outboundPreferences` ride `WebViewModel.toJson` automatically; no new entries in `kExportedAppPrefs`.

### Explicitly out of scope

- Auto-detecting launcher sites by `?q=`/`?query=` heuristics — the per-site toggle is honest and zero-config-after-flip.
- Hijacking `window.open` / `target=_blank` / popup-window paths in `inappbrowser.dart`. v1 confines outbound hijacking to `NavigationDecisionEngine`'s `blockOpenNested` decisions (gesture-driven cross-domain) and the cross-domain `onUrlChanged` redirect path; everything else falls through to today's behaviour.
- Auto-creating a new site for unmatched outbound URLs (LIR-010 option 3). Auto-spawning sites from a search-result click is surprising; the existing inbound flow remains the only path to create.
- Per-host disable list ("hijack everything except this host"). The pref list already supports negative routing by claim specificity if the user really needs it.

## Capabilities

### Modified Capabilities

- `link-intent-routing`: adds LIR-013 (per-site outbound toggle + preferences), LIR-014 (outbound resolution order), LIR-015 (outbound dispatch executes as nested using destination settings, no webspace switch), LIR-016 (picker remember checkbox writes outbound preference back to source), LIR-017 (outbound preference GC on delete / import).

No other capabilities are touched. `nested-url-blocking` is unaffected — `NavigationDecisionEngine` still owns the "should this be a nested open at all" decision; LIR only chooses *which* site the nested view is bound to.

## Impact

- **Flutter code**:
  - `WebViewModel`: new `routeOutboundLinks: bool` and `outboundPreferences: List<OutboundPreference>` fields. JSON round-trip omits both when false / empty (legacy stable).
  - `lib/services/outbound_preference.dart`: new pure-Dart value type `(DomainClaim claim, String targetSiteId)` with canonical serialization.
  - `lib/services/link_intent_dispatch_engine.dart`: new static `dispatchOutbound(...)` plus result variants. Existing inbound entry points untouched.
  - `lib/services/link_routing_service.dart`: new `resolveOutbound(targetUrl, sourcePrefs, allSites)` that layers source prefs over the existing `resolve`.
  - `lib/web_view_model.dart`: the two `launchUrlFunc(...)` sites (`shouldOverrideUrlLoading` → `blockOpenNested` and `onUrlChanged` cross-domain redirect) call `dispatchOutbound` first; executor lives in `_WebSpacePageState` (`_executeOutboundDispatch`).
  - Per-site settings screen: new `OutboundRoutingSection` widget composed of `SwitchListTile` + `OutboundPreferencesEditor`.
  - `_WebSpacePageState`: GC routine extended to drop dangling `targetSiteId` entries.
- **Specs touched**: only `link-intent-routing` (delta). No changes to `webspaces`, `nested-url-blocking`, `per-site-cookie-isolation`, or `per-site-containers`.
- **Migration**: existing sites deserialize with `routeOutboundLinks=false` and empty `outboundPreferences`; serialization omits both. No user-visible change until the user flips the toggle.
- **Tests**: unit tests for `resolveOutbound` (source-pref priority, self-match fall-through, ambiguity), engine tests for `dispatchOutbound` variants, widget test for picker writeback, GC test.
- **Security**: outbound preferences carry only `siteId` references; no URLs, cookies, or secrets. Backup round-trips through normal `WebViewModel` JSON.
- **Performance**: one extra resolver call per cross-domain navigation gesture. Resolver is O(claims × sites); negligible for typical site counts.
