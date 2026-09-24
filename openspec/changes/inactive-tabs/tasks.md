Tasks for hosted tabs and reattach (LIR-018 to LIR-027). The tab model itself (TAB-001 to TAB-011) is implemented; its steps are the Migration Plan in `design.md`.

## 1. Hosted tabs: prerequisites

- [ ] 1.1 Start once the tab model has landed, on the names it uses (`SiteTab`, `_switchActiveTab`, `webViewStateKey`, `removeStatesForSite`, `TabLifecycleEngine`).
- [ ] 1.2 Mix gate first (CLAUDE.md "Formal verification"; design D14). A loaded slot's required proxy stops being a per-site constant, so, without editing app code yet:
  - `formal/proxy.tla`: slot identity as a variable; `Rebind(s, i)` for the visible and a background slot; `OpenNestedAs(i)` / `PopNested` for LIR-015 and its return path; `Inv_EgressMatchesConfig` and off-mode `Inv_ProxyCoherent` over the identity; negative demonstrator (background rebind to a mismatched identity without unloading) and positive witness (a hosted slot co-loaded with the host's own slot).
  - `formal/containers.tla`: slot-to-identity map, `Inv_Disjoint` over identities, new `Inv_PostureMatchesContainer`; negative demonstrator binding the host's container while mirroring cookies to the owner.
  - `formal/kernel.tla`: if the tab switch is modelled as a surface attach, enable it for hosted targets and re-check `RepaintLiveness` and `Inv_CurrentLoaded`.
  - `./formal/check.sh` green; restate `formal/proofs/proxy_coherent.tla` and `containers_disjoint.tla` so `formal/proofs/check_proofs.sh` passes. A counterexample means the design changes, not the model.

## 2. Hosted tabs: model and keys

- [ ] 2.1 `SiteTab.hostSiteId` (`String?`): `toJson` omits null; `fromJson` sanitises like `parentId`; `TabLifecycleEngine.normalize` stores a host equal to the owner as null.
- [ ] 2.2 `WebViewModel.stateKeyForTab(tab)` = `webViewStateKey(tab.hostSiteId ?? siteId, tab.id)`; `activeStateKey` follows it. `_liveStateKeys` builds the orphan sweep's live set with it.
- [ ] 2.3 `WebViewStateStorage.renameState(oldKey, newKey)` on the interface, `SecureWebViewStateStorage` (a file rename: the AES-GCM blob binds no associated data to its name today; if it ever does, rename becomes load and re-save) and `InMemoryWebViewStateStorage`; a missing source is a no-op; an existing destination is overwritten.
- [ ] 2.4 Persistence (LIR-022): `toJson` writes a hosted tab only when the host has neither `incognito` nor `alwaysOpenHome`; the capture gate writes bytes only for a persisted record whose identity has `persistsNavState`.
- [ ] 2.5 Tests: model round-trip with and without a host; normalisation; host-keyed keys; session-only records for an Always open Home host; `renameState` on both storages; orphan sweep keeps host-keyed live keys.

## 3. Hosted tabs: running as the host

- [ ] 3.1 Identity view in `getWebView` (design D9): every POSTURE field, the identity plumbing (`cookieSiteId`, the `onCookiesChanged` target model and its `saveFunc`, `blockedCookies`, fingerprint seed, block-stats and notification attribution) and the navigation rules (`initUrl`, claims, `blockAutoRedirects`, `externalLinksInBrowser`, the `onOutboundLink` source) read from the running identity; slot plumbing reads `this`.
- [ ] 3.2 Gate: extend `test/js/nested_webview_posture_parity.test.js` (or a sibling) so every POSTURE field in `getWebView`'s `WebViewConfig(...)` and in both `launchUrlFunc(...)` calls is read from the identity, never from `this`.
- [ ] 3.3 HTML cache: `onHtmlLoaded`, `shouldFetchHtml` and `initialHtml` are inert while the active tab has a host.
- [ ] 3.4 Owner loads bind an own tab first (design D8): home-shortcut launch, the Always open Home reset, `_executeOpenInMain`. A pure helper `TabLifecycleEngine.ownTabFor(tabs, activeTabId)` returns the tab to bind or null (seed a root).
- [ ] 3.5 The tab sheet names the host on a hosted row.
- [ ] 3.6 Tests: posture and cookie mirror follow the host (a fake `ContainerCookieManager` keyed by site); HTML cache untouched; a shortcut launch on a hosted active tab binds the own parent first.

## 4. Hosted tabs: eligibility and creation

- [ ] 4.1 `hostCandidates(url, owner, sites, mayHost)` in `lib/services/link_routing_service.dart` (pure): navigation-domain filter, then LIR order (owner preferences, claim score, site order), minus the current identity. `mayHost` from `_WebSpacePageState`: container engine, both sides app-tier, host not effectively incognito.
- [ ] 4.2 Long-press menu (`_showLinkLongPressMenu`): for a link outside the running identity's domain, one "Open in new tab as {site}" row per candidate, creating a parked child hosted by it (TAB-006 snackbar); in-domain links keep "Open in new tab" with the active tab's host.
- [ ] 4.3 `InAppWebViewScreen` gains `onKeepAsTab` (null for inbound-opened screens and under a locked kiosk shell). The menu item resolves the host per LIR-021, pops the screen, inserts the child under the tab it was opened from (root if that tab closed), and switches to it through `_switchActiveTab`.
- [ ] 4.4 Tests: `hostCandidates` (navigation-domain filter, claim-only non-candidate, ordering, incognito and archive exclusion, legacy engine); menu rows; Keep as tab for a routed screen, for a source-posture screen with a candidate, and disabled with none; no Keep as tab on an inbound-opened screen.

## 5. Hosted tabs: host lifecycle

- [ ] 5.1 A pure `HostedTabGc.closeForHost(sites, hostId)` returning per-owner close plans (TAB-007 re-parenting, next active, bytes to drop).
- [ ] 5.2 `_deleteSite(host)`: apply the plans and re-bind affected owners before `ContainerIsolationEngine.onSiteDeleted`. `_deleteSite(owner)`: drop its hosted tabs' host-keyed bytes.
- [ ] 5.3 `_clearSiteData(host)`: dispose every slot whose identity is the host before `clearForSite`; `removeStatesForSite(host)` covers the bytes.
- [ ] 5.4 `_moveSiteToArchive`: close tabs the site hosts elsewhere and the hosted tabs it owns, before the move. Settings save that turns `incognito` on for a host: close its hosted tabs.
- [ ] 5.5 GC at startup, import and delete: close tabs whose `hostSiteId` names no eligible host.
- [ ] 5.6 Tests: delete ordering (the container delete sees no bound slot), clear disposes the owner slot, archive move and incognito close, import GC re-parents children; extend `test/archive_neutrality_test.dart` so an app-tier site with hosted tabs stays byte-identical with and without archives.

## 6. Hosted tabs: proxy and Tor

- [ ] 6.1 `SiteUnloadEngine.indicesToUnloadForProxyMismatch`, `indicesToUnloadForTorExitMismatch`, `torExitNodesFor` gain `identityOf(int index)` (default `models[i]`); router mode's `sharesDefaultSession` reads the identity.
- [ ] 6.2 Visible-slot rebind to a mismatched identity runs the PROXY-008 sequence first and fails closed; a background-slot rebind to a mismatched identity leaves the slot disposed and out of `_loadedIndices`.
- [ ] 6.3 Tests in `test/site_unload_engine_test.dart` and `test/proxy_mechanism_parity_test.dart`: identity-based eviction, the host's own slot kept when proxies agree, background rebind left unloaded, Tor pin read from the identity.

## 7. Reattach instruments: engine

- [ ] 7.1 `TabLifecycleEngine.moveSubtree(...)` returning `TabMovePlan` (design D15): identities preserved and re-normalised against the destination; id re-minted on collision with a rename; drops when the destination does not persist the record; refusals (legacy engine, archive tier, a resulting host that may not host, a parent not in the destination).
- [ ] 7.2 `TabLifecycleEngine.reparent(tabs, tabId, newParentId)`: refuses a parent inside the subtree; moves the subtree to follow the new parent's last descendant.
- [ ] 7.3 `TabLifecycleEngine.changeHost(owner, tabId, newHostId)`: normalised host, the old key to drop, children untouched.
- [ ] 7.4 `test/tab_lifecycle_engine_test.dart`: every rule above with in-memory fakes that model the host-keyed store (a moved tab's bytes are found under the same key afterwards; a renamed primary tab's bytes under the new one; a host change leaves nothing under either key).

## 8. Reattach instruments: UI and wiring

- [ ] 8.1 Row overflow menu in `lib/widgets/tabs_sheet.dart`: "Move to site...", "Move under...", "Run as..."; hidden under a locked kiosk shell; "Move to site..." and "Run as..." hidden on the legacy engine.
- [ ] 8.2 Pickers: eligible owners, then the destination tree with a "Top level" row; the same site's tree with the moved subtree greyed; hosts with the current one checked.
- [ ] 8.3 Call sites: guard with `_isTabHandling`; capture a moving active tab before applying the plan; apply renames and drops; re-bind the source owner through `_switchActiveTab(captureOutgoing: false)`; run 6.2 for any rebind; persist once; snackbar with "Switch" after a move.
- [ ] 8.4 Strings: code plus `lib/l10n/app_en.arb` (descriptions for every key: action labels, "Top level", "Open in new tab as {site}", "Keep as tab", "Keep as tab as {site}", refusal reasons) in one commit, the 66 translations in the next.
- [ ] 8.5 Widget tests in `test/tabs_sheet_test.dart`: menu visibility per engine and kiosk, picker contents, the moved subtree greyed, refusal messages.

## 9. Hosted tabs and reattach: manual smoke

- [ ] 9.1 Android and iOS: long-press a GitHub result in DuckDuckGo, "Open in new tab as GitHub", switch to it: signed in; back at its start returns to the results tab.
- [ ] 9.2 A routed GitHub screen, "Keep as tab": the tab stays in DuckDuckGo's tree after a restart.
- [ ] 9.3 Android without router mode, DuckDuckGo and GitHub on different proxies: activating the hosted tab applies GitHub's proxy; switching back applies DuckDuckGo's.
- [ ] 9.4 Move a subtree from DuckDuckGo to Mastodon; restart; both trees and back stacks survive.
- [ ] 9.5 Run a tab as Work GitHub instead of Personal GitHub: it reloads signed in as Work, with no back history.
- [ ] 9.6 Delete GitHub while a DuckDuckGo tab it hosts is active: the tab closes, DuckDuckGo shows the parent, GitHub's login is gone (a new GitHub site starts signed out).
