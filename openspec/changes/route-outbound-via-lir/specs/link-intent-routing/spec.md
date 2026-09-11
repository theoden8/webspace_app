## ADDED Requirements

### Requirement: LIR-013 - Per-Site Outbound Routing Toggle And Preferences

Each site SHALL carry a `routeOutboundLinks` boolean (default `false`) and a `outboundPreferences` list of `(DomainClaim claim, String targetSiteId)` entries (default empty). When the boolean is `false`, the site's cross-domain navigation behaviour SHALL be byte-identical to the pre-change behaviour — `NavigationDecisionEngine`'s `blockOpenNested` decision opens a nested `InAppWebViewScreen` carrying the source site's siteId / cookies / container / settings. Serialization of `WebViewModel.toJson` SHALL omit `routeOutboundLinks` when `false` and `outboundPreferences` when empty so on-disk JSON for users who never enable the feature is unchanged.

#### Scenario: Legacy site loads with defaults

- **WHEN** a `WebViewModel` is deserialized from JSON that does not contain `routeOutboundLinks` or `outboundPreferences`
- **THEN** `routeOutboundLinks` is `false`
- **AND** `outboundPreferences` is `[]`
- **AND** subsequent serialization omits both fields

#### Scenario: Toggle off preserves today's nested behaviour

- **GIVEN** site A has `routeOutboundLinks = false` and an outbound preference for `exactHost(github.com) → site B`
- **WHEN** the user clicks a `github.com` link inside site A's webview
- **THEN** the dispatch engine returns `DispatchNestedFallback`
- **AND** the executor opens a nested webview with site A's settings (siteId, cookies, container, language, scripts, ...)
- **AND** site B's container is not consulted

#### Scenario: Preferences persist across restart

- **GIVEN** the user saves `[(exactHost:github.com, work-gh), (wildcardSubdomain:github.com, work-gh)]` on a DDG site with `routeOutboundLinks = true`
- **WHEN** the app is restarted
- **THEN** the DDG site loads with both preferences and the toggle on

---

### Requirement: LIR-014 - Outbound Resolution Order

When a source site has `routeOutboundLinks == true` and a cross-domain navigation would invoke the nested-launch path, the system SHALL resolve the target URL through `LinkRoutingService.resolveOutbound(targetUrl, sourceSiteId, sourcePrefs, allSites)`. The resolution SHALL apply the following order:

1. **Source preferences**: score every `OutboundPreference` whose `targetSiteId` is currently present in `allSites` against `targetUrl` using LIR-002's specificity table (`exactHost` = 300, `wildcardSubdomain` = 200, `baseDomain` = 100). The highest-scored entry returns `OutboundResolution.preference(target)`. Source preferences SHALL win over any global LIR result, including unambiguous ones.
2. **Global LIR**: when no source preference matches, the system SHALL fall back to `LinkRoutingService.resolve(targetUrl, allSites)` and wrap the result as `OutboundResolution.global(...)`.
3. **Self-match collapse**: any resolution that targets the source site itself SHALL collapse to `OutboundResolution.selfMatch()`, regardless of whether it arrived via source preference or global LIR.

#### Scenario: Source preference beats global single match

- **GIVEN** the source has `OutboundPreference(exactHost:github.com, targetSiteId: work-gh)`
- **AND** the global resolver would return `RoutingSingle(personal-gh)` for `https://github.com/x` because `personal-gh` claims `wildcardSubdomain:github.com`
- **WHEN** `resolveOutbound` runs
- **THEN** the result is `OutboundResolution.preference(work-gh)`

#### Scenario: Source preference skipped when target site deleted

- **GIVEN** the source has `OutboundPreference(exactHost:github.com, targetSiteId: work-gh)`
- **AND** `work-gh` is no longer in `allSites`
- **WHEN** `resolveOutbound` runs on `https://github.com/x`
- **THEN** the preference is skipped
- **AND** resolution falls through to global LIR

#### Scenario: No source preference falls through to global

- **GIVEN** the source has no preference covering `https://github.com/x`
- **AND** the global resolver returns `RoutingSingle(work-gh)`
- **WHEN** `resolveOutbound` runs
- **THEN** the result is `OutboundResolution.global(RoutingSingle(work-gh))`

#### Scenario: Self-match collapses regardless of path

- **GIVEN** the source is the DuckDuckGo site, which claims `wildcardSubdomain:duckduckgo.com`
- **WHEN** the user clicks `https://links.duckduckgo.com/help` from inside that site
- **THEN** `resolveOutbound` returns `OutboundResolution.selfMatch()`
- **AND** the executor SHALL invoke `DispatchNestedFallback`, leaving today's source-settings nested-open behaviour in place

#### Scenario: Higher-specificity source preference wins among multiple

- **GIVEN** the source has `[OutboundPreference(wildcardSubdomain:github.com, personal-gh), OutboundPreference(exactHost:github.com, work-gh)]`
- **WHEN** `resolveOutbound` runs on `https://github.com/orgs/...`
- **THEN** the result is `OutboundResolution.preference(work-gh)` (exactHost beats wildcardSubdomain)

---

### Requirement: LIR-015 - Outbound Dispatch Opens Destination As Nested Without Webspace Switch

The dispatch engine SHALL emit `DispatchOpenNested(siteId: destinationSiteId, url: targetUrl, sourceIsParent: true)` for an outbound hijack. The executor SHALL invoke `launchUrl(...)` carrying the **destination** site's siteId, incognito flag, third-party cookies setting, ClearURL / DNS-block / content-block / LocalCDN / tracking-protection toggles, language, location settings, WebRTC policy, user scripts, proxy settings, and notifications flag. The executor SHALL **NOT** invoke `_maybeSwitchToAllForSite` for an outbound hijack — the user remains in the source's current webspace, and back-gesture from the pushed `InAppWebViewScreen` returns directly to the source site without an intermediate webspace transition.

`DispatchNestedFallback` SHALL be the engine's output when (a) the source has `routeOutboundLinks == false`, (b) `resolveOutbound` returns `selfMatch`, or (c) `resolveOutbound` returns `global(RoutingNone)`. The executor SHALL implement `DispatchNestedFallback` by calling `launchUrl(...)` with the **source** site's args, byte-identical to the pre-change `launchUrlFunc(url, ...)` call site in `web_view_model.dart`.

#### Scenario: Outbound hijack opens nested with destination settings

- **GIVEN** source DDG has `routeOutboundLinks = true` and the resolver picks site `work-gh` for `https://github.com/x`
- **WHEN** the user clicks the link inside DDG
- **THEN** the executor pushes an `InAppWebViewScreen` with `siteId == work-gh`
- **AND** the screen's `WebViewConfig` carries work-gh's container, cookies, language, user scripts, proxy settings, location, WebRTC policy, ClearURLs and blocking toggles
- **AND** the current webspace is unchanged (no `_maybeSwitchToAllForSite` call)

#### Scenario: Back gesture returns to source in the same webspace

- **GIVEN** the user is on the DDG site in webspace "Personal" and clicks `https://github.com/x`
- **AND** the resolver routes to `work-gh` (which lives in webspace "Work")
- **WHEN** the nested view loads and the user presses the system Back button
- **THEN** the nested screen pops
- **AND** the active site is still DDG
- **AND** the active webspace is still "Personal"

#### Scenario: Launcher mode off uses fallback

- **GIVEN** source DDG has `routeOutboundLinks = false`
- **WHEN** the user clicks `https://github.com/x`
- **THEN** the executor invokes `DispatchNestedFallback`
- **AND** the nested `InAppWebViewScreen` carries DDG's siteId, cookies, container, and settings (today's behaviour)

#### Scenario: Self-match uses fallback

- **GIVEN** source DDG has `routeOutboundLinks = true`
- **AND** the target URL resolves to DDG itself (self-claim or self-pref)
- **WHEN** the user clicks the link
- **THEN** the executor invokes `DispatchNestedFallback`
- **AND** the nested view carries DDG's settings

---

### Requirement: LIR-016 - Picker Remember Checkbox Writes Outbound Preference Back To Source

When `resolveOutbound` returns `OutboundResolution.global(RoutingAmbiguous(sites))`, the engine SHALL emit `DispatchShowPicker(winnerSiteIds: sites, offerBind: false, offerCreate: false, source: sourceSiteId)`. The picker SHALL render one row per winner candidate, suppress the "Send {host} to a site" row, suppress the "Create new site for {host}" row, and SHALL display a `CheckboxListTile` "Always use this when opening links from {sourceName}" beneath the candidate rows. The checkbox SHALL default to checked.

When the user picks a winner with the checkbox in its checked state, the executor SHALL:

1. Compute `claims = LinkRoutingService.claimsToAdoptHost(targetUrl.host)` — `[exactHost(host), wildcardSubdomain(getBaseDomain(host))]`.
2. For each claim not already present in `source.outboundPreferences`, append `OutboundPreference(claim, chosenSiteId)`.
3. Persist via `_saveWebViewModels()`.
4. Continue with the outbound hijack as if the resolver had returned `OutboundResolution.preference(chosen)`.

When the user picks a winner with the checkbox unchecked, the executor SHALL proceed with the outbound hijack for *this navigation only*, without mutating `outboundPreferences`.

The remember writeback SHALL be idempotent — repeated picks of the same winner do not introduce duplicate preference entries.

#### Scenario: Ambiguous resolution shows outbound-mode picker

- **GIVEN** source DDG has `routeOutboundLinks = true` and no outbound preference for `github.com`
- **AND** two sites both claim `exactHost:github.com`
- **WHEN** the user clicks a `github.com` link inside DDG
- **THEN** the picker is shown listing both sites
- **AND** the "Send github.com to a site" row is hidden
- **AND** the "Create new site" row is hidden
- **AND** a "Always use this when opening links from DuckDuckGo" checkbox is shown, defaulted to checked

#### Scenario: Remember writes outbound preference

- **GIVEN** the outbound picker is showing for `https://github.com/x` from source DDG
- **WHEN** the user taps "Open in Work GitHub" with the remember checkbox checked
- **THEN** DDG's `outboundPreferences` gains `OutboundPreference(exactHost:github.com, work-gh)` and `OutboundPreference(wildcardSubdomain:github.com, work-gh)`
- **AND** the state is persisted to disk
- **AND** the GitHub URL opens nested with work-gh's settings
- **AND** a subsequent `github.com` click from DDG resolves silently to work-gh without showing the picker

#### Scenario: Unchecked remember does not mutate prefs

- **GIVEN** the outbound picker is showing for `https://github.com/x` from source DDG
- **WHEN** the user unticks the checkbox and taps "Open in Work GitHub"
- **THEN** the GitHub URL opens nested with work-gh's settings
- **AND** DDG's `outboundPreferences` is unchanged
- **AND** the next `github.com` click from DDG shows the picker again

#### Scenario: Repeated remember is idempotent

- **GIVEN** DDG already has `OutboundPreference(exactHost:github.com, work-gh)` and `OutboundPreference(wildcardSubdomain:github.com, work-gh)`
- **WHEN** the user manually invokes the outbound picker for `https://github.com/y` from DDG and re-picks Work GitHub with remember on
- **THEN** the preference list is unchanged (no duplicates)

#### Scenario: Picker is suppressed when launcher mode is off

- **GIVEN** source DDG has `routeOutboundLinks = false`
- **AND** two sites both claim `exactHost:github.com`
- **WHEN** the user clicks a `github.com` link inside DDG
- **THEN** the picker is not shown
- **AND** the executor invokes `DispatchNestedFallback` (today's nested with DDG settings)

---

### Requirement: LIR-017 - Orphan Cleanup For Outbound Preferences

The system SHALL drop any `OutboundPreference` entries whose `targetSiteId` is not present in `_webViewModels` at three points:

1. After `_loadWebViewModels` during app startup.
2. After `_deleteSite` removes a site.
3. After `_importSettings` finishes restoring sites from a backup.

The cleanup SHALL persist via `_saveWebViewModels` only when at least one entry was dropped. The cleanup SHALL NOT touch `outboundPreferences` entries whose target site is present, even if the target's claims no longer match the preference's claim — preferences remain valid as long as the target exists.

The dispatch engine SHALL additionally guard against the race window between cleanups: `resolveOutbound` SHALL ignore any preference whose `targetSiteId` is not in the live `allSites` argument, even if the persisted preference list still contains it.

#### Scenario: Site delete drops dangling preferences

- **GIVEN** DDG has `OutboundPreference(exactHost:github.com, work-gh)`
- **WHEN** the user deletes `work-gh`
- **THEN** DDG's `outboundPreferences` list no longer contains the preference
- **AND** the change is persisted to disk
- **AND** no user-visible notification is shown

#### Scenario: Import drops preferences whose target failed to re-import

- **GIVEN** a backup file with two sites and a preference on site A pointing to site B
- **WHEN** the user imports the backup but site B fails restore (e.g. duplicate ID conflict resolved by drop)
- **THEN** after import completes, site A's preference list does not contain the dangling entry
- **AND** the orphan cleanup runs as part of the import flow

#### Scenario: Live race ignores not-yet-cleaned preference

- **GIVEN** DDG has `OutboundPreference(exactHost:github.com, work-gh)` persisted
- **AND** `work-gh` has been deleted but the cleanup has not yet run
- **WHEN** the user clicks a `github.com` link inside DDG
- **THEN** `resolveOutbound` ignores the preference (target missing in `allSites`)
- **AND** resolution falls through to global LIR
