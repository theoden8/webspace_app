## ADDED Requirements

### Requirement: LIR-013 - Per-Site Outbound Routing Toggle And Preferences

Each site SHALL carry a `routeOutboundLinks` boolean (default `false`) and an `outboundPreferences` list of `(DomainClaim claim, String targetSiteId)` entries (default empty). While `routeOutboundLinks` is `false`, the site's cross-domain navigation SHALL behave exactly as it did before this change: a `blockOpenNested` decision from `NavigationDecisionEngine` opens a nested `InAppWebViewScreen` with the site's own posture, and a `blockOpenExternal` decision (NESTED-009, `externalLinksInBrowser`) hands the URL to the system browser. `WebViewModel.toJson` SHALL omit `routeOutboundLinks` when `false` and `outboundPreferences` when empty, so the on-disk JSON of a user who never enables the feature is unchanged.

Both fields SHALL ride settings backup through `WebViewModel.toJson` and SHALL NOT be registered in `kExportedAppPrefs`. The site QR share (site-settings-qr) SHALL carry `routeOutboundLinks` and SHALL NOT carry `outboundPreferences`: every entry names a device-local `siteId`, the same reason QR-003 refuses `siteId` itself.

#### Scenario: Legacy site loads with defaults

- **WHEN** a `WebViewModel` is deserialized from JSON that does not contain `routeOutboundLinks` or `outboundPreferences`
- **THEN** `routeOutboundLinks` is `false`
- **AND** `outboundPreferences` is `[]`
- **AND** subsequent serialization omits both fields

#### Scenario: Toggle off keeps today's routing

- **GIVEN** site A has `routeOutboundLinks = false` and an outbound preference for `exactHost(github.com) -> site B`
- **WHEN** the user taps a `github.com` link inside site A's webview
- **THEN** no outbound resolution runs
- **AND** the navigation takes the path `NavigationDecisionEngine` chose: a nested screen with site A's posture, or the system browser when A has `externalLinksInBrowser` on and no A claim covers `github.com`
- **AND** site B's container is not consulted

#### Scenario: Preferences persist across restart

- **GIVEN** the user saves `[(exactHost:github.com, work-gh), (wildcardSubdomain:github.com, work-gh)]` on a DuckDuckGo site with `routeOutboundLinks = true`
- **WHEN** the app is restarted
- **THEN** the DuckDuckGo site loads with both preferences and the toggle on

#### Scenario: QR share carries the toggle, not the preferences

- **GIVEN** a site with `routeOutboundLinks = true` and one outbound preference
- **WHEN** its settings are encoded with `SiteSettingsQrCodec.encode(SiteSettingsQrCodec.shareableSubset(model.toJson()))`
- **THEN** the payload contains `routeOutboundLinks`
- **AND** the payload does not contain `outboundPreferences` or the target `siteId`

---

### Requirement: LIR-014 - Outbound Resolution Order

Outbound routing SHALL run for a navigation only when all of the following hold:

1. The source site has `routeOutboundLinks == true`.
2. The navigation came from the source's own webview through `shouldOverrideUrlLoading` or `onUrlChanged`, and `NavigationDecisionEngine` returned `blockOpenNested` or `blockOpenExternal`. `allow`, `blockSilent` and `blockSuppressed` are never routed. A nested `InAppWebViewScreen` does not route: it has nowhere further to nest and navigates in place (NESTED-010).
3. The navigation carried an effective user gesture: the gesture flag of `shouldOverrideUrlLoading`, or the gesture propagation window (NESTED-007) that `NavigationDecisionEngine` already computes, which it SHALL return on its result. A gesture-less cross-domain navigation, reachable when `blockAutoRedirects` is off, SHALL NOT be routed, or a page could load a URL of its choosing inside another site's signed-in container without a click.
4. The container engine is active. On the legacy engine a nested screen runs in the shared cookie jar (ISO-007), so a routed screen would carry neither the destination's cookies nor its isolation.
5. Developer mode is on (DEVTOOLS-010). Routing has run only in tests; until it has run on devices it sits behind developer mode, like router mode (PROXY-013). While developer mode is off, `routeOutboundLinks` and `outboundPreferences` keep their stored values and nothing is routed.
6. The kiosk shell is not locked (KIOSK-001). A routed open is another site's signed-in identity, which a locked shell must not reach (KIOSK-002); links there take the navigation engine's path with the source's posture.

The candidate sites SHALL be those on the source's side of the archive boundary: every app-tier site when the source is app-tier, and the sites of the same open archive when the source is archive-tier (ARCH-001, ARCH-006). A site on the other side SHALL never be a candidate, whether a preference or a claim names it.

`LinkRoutingService.resolveOutbound(targetUrl, sourceSiteId, sourcePrefs, candidates)` SHALL apply, in order:

1. **Source preferences**: score every `OutboundPreference` whose `targetSiteId` is a candidate against `targetUrl` with the resolver's specificity table (`exactHost` = 300, `wildcardSubdomain` = 200, `baseDomain` = 100, port-aware as in `LinkRoutingService.resolve`). The highest-scored entry returns `OutboundResolution.preference(target)`; among equal scores the earlier entry in the list wins. A matching preference SHALL win over any global result, including an unambiguous one.
2. **Global LIR**: when no preference matches, the result of `LinkRoutingService.resolve(targetUrl, candidates)` wrapped as `OutboundResolution.global(...)`.
3. **Self-match collapse**: any resolution that names the source itself SHALL collapse to `OutboundResolution.selfMatch()`.

A resolution that names a destination (a preference, a global single, or a picker choice under LIR-016) SHALL take precedence over a `blockOpenExternal` decision: a link to a site the user keeps in the app stays in the app. A resolution that names no destination (`RoutingNone`, `selfMatch`) SHALL leave the navigation engine's decision in force.

#### Scenario: Source preference beats global single match

- **GIVEN** the source has `OutboundPreference(exactHost:github.com, work-gh)`
- **AND** the global resolver would return `RoutingSingle(personal-gh)` for `https://github.com/x` because `personal-gh` claims `baseDomain:github.com`
- **WHEN** `resolveOutbound` runs
- **THEN** the result is `OutboundResolution.preference(work-gh)`

#### Scenario: Source preference skipped when target site deleted

- **GIVEN** the source has `OutboundPreference(exactHost:github.com, work-gh)`
- **AND** `work-gh` is not among the candidates
- **WHEN** `resolveOutbound` runs on `https://github.com/x`
- **THEN** the preference is skipped
- **AND** resolution falls through to global LIR

#### Scenario: No source preference falls through to global

- **GIVEN** the source has no preference covering `https://github.com/x`
- **AND** the global resolver returns `RoutingSingle(work-gh)`
- **WHEN** `resolveOutbound` runs
- **THEN** the result is `OutboundResolution.global(RoutingSingle(work-gh))`

#### Scenario: Self-match collapses regardless of path

- **GIVEN** a Mastodon site at `https://mastodon.social/` whose claims include `exactHost:joinmastodon.org`
- **WHEN** the user taps `https://joinmastodon.org/apps` inside that site, which is cross-domain for it
- **THEN** `resolveOutbound` returns `OutboundResolution.selfMatch()`
- **AND** the link opens in a nested screen with the Mastodon site's posture, as it does today

#### Scenario: Higher-specificity source preference wins among multiple

- **GIVEN** the source has `[OutboundPreference(baseDomain:github.com, personal-gh), OutboundPreference(exactHost:gist.github.com, work-gh)]`
- **WHEN** `resolveOutbound` runs on `https://gist.github.com/abc`
- **THEN** the result is `OutboundResolution.preference(work-gh)`

#### Scenario: A routed destination wins over the system browser

- **GIVEN** a DuckDuckGo site with `routeOutboundLinks` and `externalLinksInBrowser` both on, whose claims do not cover `github.com`
- **AND** a GitHub site that is the single global match for `github.com`
- **WHEN** the user taps `https://github.com/x` in DuckDuckGo
- **THEN** the link opens nested with the GitHub site's posture
- **AND** the system browser is not opened
- **AND** a tap on `https://blog.example/` that no site claims still opens in the system browser

#### Scenario: A gesture-less navigation is not routed

- **GIVEN** a DuckDuckGo site with `routeOutboundLinks` on and `blockAutoRedirects` off
- **AND** no same-domain gesture was recorded in the propagation window
- **WHEN** a script navigates the page to `https://github.com/settings`
- **THEN** no outbound resolution runs
- **AND** the navigation takes today's path with DuckDuckGo's posture

#### Scenario: A site behind the archive boundary is not a candidate

- **GIVEN** an app-tier DuckDuckGo site with `routeOutboundLinks` on
- **AND** an open archive holds the only site that claims `github.com`
- **WHEN** the user taps `https://github.com/x` in DuckDuckGo
- **THEN** the archive-tier site is not a candidate
- **AND** the navigation takes today's path with DuckDuckGo's posture

#### Scenario: Developer mode off does not route

- **GIVEN** a DuckDuckGo site with `routeOutboundLinks` on, and a GitHub site that is the single global match for `github.com`
- **AND** developer mode is off
- **WHEN** the user taps `https://github.com/x` in DuckDuckGo
- **THEN** no outbound resolution runs
- **AND** the navigation takes today's path with DuckDuckGo's posture
- **AND** DuckDuckGo still has `routeOutboundLinks` on, so turning developer mode back on routes again

#### Scenario: A locked kiosk shell does not route

- **GIVEN** a DuckDuckGo site with `routeOutboundLinks` and `kioskMode` on, launched from its home-screen shortcut
- **AND** a GitHub site that is the single global match for `github.com`
- **WHEN** the user taps `https://github.com/x` in DuckDuckGo
- **THEN** no outbound resolution runs
- **AND** the navigation takes today's path with DuckDuckGo's posture

#### Scenario: The legacy engine does not route

- **GIVEN** the device runs the legacy cookie engine
- **AND** a DuckDuckGo site has `routeOutboundLinks` on
- **WHEN** the user taps a link another site claims
- **THEN** no outbound resolution runs
- **AND** the navigation takes today's path with DuckDuckGo's posture

---

### Requirement: LIR-015 - Outbound Dispatch Opens Destination As Nested Without Webspace Switch

For a resolution that names a destination, the dispatch engine SHALL emit `DispatchOpenNested(siteId: destinationSiteId, url: targetUrl, sourceIsParent: true)`. The executor SHALL run the same path as an inbound cross-domain open (`_executeOpenNested`, whose ordering lives in the pure `NestedOpenEngine`): on Android without router mode, and on Linux, the PROXY-008 sequence for the destination before the screen is pushed, failing closed when the proxy cannot be applied (SEC-004); then `_launchNestedForModel(destination, url)`, the one funnel for a nested screen of an existing site (NESTED-010), so the screen carries every `LaunchUrlFunc` field of the destination read through its `effective*` getters. With `sourceIsParent: true` the executor SHALL NOT call `_maybeSwitchToAllForSite`: the user stays in the source's webspace, and back from the pushed screen returns to the source with no webspace transition.

When pushing the destination's screen changed the process-global proxy (Android without router mode, Linux), popping it SHALL re-run the source's activation, its PROXY-008 sequence and, if the mismatch unload disposed it, its rebuild with its captured navigation state queued, before the source is shown again. The source SHALL NOT be rebuilt while the destination's proxy is still applied, or the source's traffic would leave through the destination's proxy.

When routing runs and names no destination, the engine SHALL emit `DispatchNestedFallback` for a `blockOpenNested` decision and `DispatchOpenExternal` for a `blockOpenExternal` one. The call site SHALL then run the code it runs today: `launchUrlFunc(url, ...)` with the source's posture, or `launchUrlInSystemBrowser(url)`. On the `onUrlChanged` path routing decides only where the link opens: the source webview is left as it is without routing, whatever the dispatch result.

#### Scenario: Outbound hijack opens nested with destination settings

- **GIVEN** source DuckDuckGo has `routeOutboundLinks = true` and the resolver picks site `work-gh` for `https://github.com/x`
- **WHEN** the user taps the link inside DuckDuckGo
- **THEN** the executor pushes an `InAppWebViewScreen` with `siteId == work-gh`
- **AND** every `LaunchUrlFunc` field of the screen comes from `work-gh`: container, incognito, language, user scripts, proxy, location, WebRTC policy, ClearURLs, DNS and content blocking, camera and microphone modes, `blockAutoRedirects`, `externalLinksInBrowser`
- **AND** the current webspace is unchanged

#### Scenario: Back gesture returns to source in the same webspace

- **GIVEN** the user is on the DuckDuckGo site in webspace "Personal" and taps `https://github.com/x`
- **AND** the resolver routes to `work-gh`, which lives in webspace "Work"
- **WHEN** the nested view loads and the user presses the system Back button
- **THEN** the nested screen pops
- **AND** the active site is still DuckDuckGo
- **AND** the active webspace is still "Personal"

#### Scenario: The source's proxy is back before the source is

- **GIVEN** Android without router mode, DuckDuckGo loaded with proxy P1, and `work-gh` configured with proxy P2
- **WHEN** a routed tap opens `work-gh`'s nested screen
- **THEN** DuckDuckGo is captured and disposed and P2 is applied before the screen is pushed
- **AND** when the screen pops, P1 is applied before DuckDuckGo's webview is rebuilt
- **AND** DuckDuckGo's back stack is restored from its captured state

#### Scenario: Launcher mode off uses today's path

- **GIVEN** source DuckDuckGo has `routeOutboundLinks = false`
- **WHEN** the user taps `https://github.com/x`
- **THEN** the nested `InAppWebViewScreen` carries DuckDuckGo's siteId, container and settings

#### Scenario: Self-match uses the fallback

- **GIVEN** source DuckDuckGo has `routeOutboundLinks = true`
- **AND** the target URL resolves to DuckDuckGo itself
- **WHEN** the user taps the link
- **THEN** the engine emits `DispatchNestedFallback`
- **AND** the nested view carries DuckDuckGo's settings

#### Scenario: An unrouted external link stays external

- **GIVEN** source DuckDuckGo has `routeOutboundLinks` and `externalLinksInBrowser` on
- **AND** no candidate claims `blog.example`
- **WHEN** the user taps `https://blog.example/post`
- **THEN** the engine emits `DispatchOpenExternal`
- **AND** the URL opens in the system browser

---

### Requirement: LIR-016 - Picker Remember Checkbox Writes Outbound Preference Back To Source

When `resolveOutbound` returns `OutboundResolution.global(RoutingAmbiguous(sites))`, the engine SHALL emit `DispatchShowPicker(winnerSiteIds: sites, offerBind: false, offerCreate: false, source: sourceSiteId, fallback: ...)`, where `fallback` names the navigation engine's decision. The picker SHALL render one "Open in {site}" row per winner, SHALL render an "Open without routing" row that runs the fallback (the source-posture nested screen, or the system browser), SHALL suppress the send-or-open-to-a-site row and the create row, and SHALL show a "Always use this when opening links from {sourceName}" checkbox beneath the winner rows, checked by default. Dismissing the picker SHALL open nothing: the source page stays as it was.

When the user picks a winner with the checkbox checked, the executor SHALL:

1. Compute `claims = LinkRoutingService.claimsToAdoptUrl(targetUrl)`: `[exactHost(host), wildcardSubdomain(getBaseDomain(host))]` for a default-port URL, the single `exactHost(host:port)` otherwise.
2. Append `OutboundPreference(claim, chosenSiteId)` for each claim that no entry of `source.outboundPreferences` already holds, whatever that entry's target.
3. Persist via `_saveWebViewModels()`.
4. Continue as if the resolver had returned `OutboundResolution.preference(chosen)`.

With the checkbox unchecked, the executor SHALL route this navigation only and SHALL NOT change `outboundPreferences`. "Open without routing" SHALL never write a preference.

#### Scenario: Ambiguous resolution shows the outbound picker

- **GIVEN** source DuckDuckGo has `routeOutboundLinks = true` and no outbound preference covering `github.com`
- **AND** two sites both claim `exactHost:github.com`
- **WHEN** the user taps a `github.com` link inside DuckDuckGo
- **THEN** the picker lists both sites and an "Open without routing" row
- **AND** the send-or-open-to-a-site row is hidden
- **AND** the create row is hidden
- **AND** an "Always use this when opening links from DuckDuckGo" checkbox is shown, checked

#### Scenario: Remember writes outbound preferences

- **GIVEN** the outbound picker is showing for `https://github.com/x` from source DuckDuckGo
- **WHEN** the user taps "Open in Work GitHub" with the checkbox checked
- **THEN** DuckDuckGo's `outboundPreferences` gains `OutboundPreference(exactHost:github.com, work-gh)` and `OutboundPreference(wildcardSubdomain:github.com, work-gh)`
- **AND** the change is persisted
- **AND** the GitHub URL opens nested with work-gh's settings
- **AND** a later `github.com` tap from DuckDuckGo routes to work-gh without a picker

#### Scenario: Unchecked remember does not mutate prefs

- **GIVEN** the outbound picker is showing for `https://github.com/x` from source DuckDuckGo
- **WHEN** the user unticks the checkbox and taps "Open in Work GitHub"
- **THEN** the GitHub URL opens nested with work-gh's settings
- **AND** DuckDuckGo's `outboundPreferences` is unchanged
- **AND** the next `github.com` tap from DuckDuckGo shows the picker again

#### Scenario: Open without routing runs today's path

- **GIVEN** the outbound picker is showing for `https://github.com/x` from source DuckDuckGo, whose `externalLinksInBrowser` is off
- **WHEN** the user taps "Open without routing"
- **THEN** the URL opens nested with DuckDuckGo's posture
- **AND** `outboundPreferences` is unchanged

#### Scenario: Dismissing the picker opens nothing

- **GIVEN** the outbound picker is showing for `https://github.com/x`
- **WHEN** the user dismisses it
- **THEN** no screen is pushed and the system browser is not opened
- **AND** DuckDuckGo still shows the page the tap came from

#### Scenario: Remember skips a claim already held

- **GIVEN** DuckDuckGo holds `OutboundPreference(wildcardSubdomain:github.com, work-gh)`, which does not cover `github.com` itself
- **AND** two sites claim `exactHost:github.com`
- **WHEN** the picker for `https://github.com/x` is answered with Work GitHub and the checkbox checked
- **THEN** only `OutboundPreference(exactHost:github.com, work-gh)` is appended
- **AND** the list holds no two entries with the same claim

#### Scenario: Picker is suppressed when launcher mode is off

- **GIVEN** source DuckDuckGo has `routeOutboundLinks = false`
- **AND** two sites both claim `exactHost:github.com`
- **WHEN** the user taps a `github.com` link inside DuckDuckGo
- **THEN** the picker is not shown
- **AND** the link opens nested with DuckDuckGo's posture

---

### Requirement: LIR-017 - Orphan Cleanup For Outbound Preferences

The system SHALL drop every `OutboundPreference` whose `targetSiteId` is not a candidate of its source under LIR-014 (the site is gone, or it is on the other side of the archive boundary) at these points:

1. **Startup**: in memory, once `_loadWebViewModels` holds the full site list; persisted by the post-paint migration resave (`DeferredStartupEngine.runPostPaintMaintenance`), which the prune SHALL request.
2. **`_deleteSite`**: on the surviving sites, before its `_saveWebViewModels`.
3. **Import**: in `planSettingsImport`, on the restored list, so the plan `_importSettings` applies and persists never names a site the backup does not restore (BACKUP-013).
4. **Archive moves**: `_moveSiteToArchive` and `_moveSiteOutOfArchive` SHALL drop every preference that the move leaves pointing across the boundary, in both directions.

A cleanup SHALL persist only when it dropped at least one entry. It SHALL NOT touch an entry whose target is still a candidate, even if the target's claims no longer match the entry's claim.

`resolveOutbound` SHALL additionally ignore any preference whose `targetSiteId` is not in the live `candidates` argument, so the window between a change and its cleanup cannot route to a missing or cross-boundary site.

#### Scenario: Site delete drops dangling preferences

- **GIVEN** DuckDuckGo has `OutboundPreference(exactHost:github.com, work-gh)`
- **WHEN** the user deletes `work-gh`
- **THEN** DuckDuckGo's `outboundPreferences` no longer contains the entry
- **AND** the change is persisted
- **AND** no user-visible notification is shown

#### Scenario: Import drops preferences whose target is not in the backup

- **GIVEN** a backup whose site A carries a preference naming a `siteId` that no site in the backup has (a hand-edited file, or one exported before a delete was saved)
- **WHEN** the user imports it
- **THEN** after the import completes, site A's preference list does not contain that entry

#### Scenario: Live race ignores a not-yet-cleaned preference

- **GIVEN** DuckDuckGo has `OutboundPreference(exactHost:github.com, work-gh)` persisted
- **AND** `work-gh` has been deleted but the cleanup has not yet run
- **WHEN** the user taps a `github.com` link inside DuckDuckGo
- **THEN** `resolveOutbound` ignores the preference
- **AND** resolution falls through to global LIR

#### Scenario: Moving the target into an archive drops the app-tier preference

- **GIVEN** app-tier DuckDuckGo has `OutboundPreference(exactHost:github.com, work-gh)`
- **WHEN** `work-gh` is moved into an archive
- **THEN** DuckDuckGo's preference naming `work-gh` is dropped and persisted
- **AND** the app-tier site list is byte-identical to what it would be after the archive is closed (ARCH-001)
