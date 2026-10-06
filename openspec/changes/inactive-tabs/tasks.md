Tasks for hosted tabs and reattach (LIR-018 to LIR-027). The tab model itself (TAB-001 to TAB-012) is implemented, behind the Experimental group's Site tabs switch (TAB-012, DEVTOOLS-011); its steps are the Migration Plan in `design.md`. Hosted tabs sit behind the same switch. The hosted-tab core (sections 1 to 3, 5 and 6) landed with web search (`web-search`), whose results from another site open as hosted tabs; creating one from a link (section 4) and the reattach instruments (7 and 8) are not built.

## 1. Hosted tabs: prerequisites

- [x] 1.1 Start once the tab model has landed, on the names it uses (`SiteTab`, `_switchActiveTab`, `webViewStateKey`, `removeStatesForSite`, `TabLifecycleEngine`).
- [x] 1.2 Mix gate first (CLAUDE.md "Formal verification"; design D14). A loaded slot's required proxy stops being a per-site constant, so, without editing app code yet: *Done for `proxy.tla` (`ident`, `RebindVisible`, `RebindBackground`, the `staleident` and `sitenotslot` demonstrators, the `Reach_HostedCoLoaded` witness) and `containers.tla` (`bound`, `posture`, `Inv_PostureMatchesContainer`, the `ownermirror` demonstrator, `Reach_Hosted`), with both proofs restated. Not modelled: `OpenNestedAs`/`PopNested` for LIR-015. The kernel models no tab switch, so it is unchanged.*
  - `formal/proxy.tla`: slot identity as a variable; `Rebind(s, i)` for the visible and a background slot; `OpenNestedAs(i)` / `PopNested` for LIR-015 and its return path; `Inv_EgressMatchesConfig` and off-mode `Inv_ProxyCoherent` over the identity; negative demonstrator (background rebind to a mismatched identity without unloading) and positive witness (a hosted slot co-loaded with the host's own slot).
  - `formal/containers.tla`: slot-to-identity map, `Inv_Disjoint` over identities, new `Inv_PostureMatchesContainer`; negative demonstrator binding the host's container while mirroring cookies to the owner.
  - `formal/kernel.tla`: if the tab switch is modelled as a surface attach, enable it for hosted targets and re-check `RepaintLiveness` and `Inv_CurrentLoaded`.
  - `./formal/check.sh` green; restate `formal/proofs/proxy_coherent.tla` and `containers_disjoint.tla` so `formal/proofs/check_proofs.sh` passes. A counterexample means the design changes, not the model.

## 2. Hosted tabs: model and keys

- [x] 2.1 `SiteTab.hostSiteId` (`String?`): `toJson` omits null; `fromJson` sanitises like `parentId`; `TabLifecycleEngine.normalize` stores a host equal to the owner as null. *The owner-equal normalisation is in the `WebViewModel` constructor.*
- [x] 2.2 `WebViewModel.stateKeyForTab(tab)` = `webViewStateKey(tab.hostSiteId ?? siteId, tab.id)`; `activeStateKey` follows it. `_liveStateKeys` builds the orphan sweep's live set with it.
- [ ] 2.3 `WebViewStateStorage.renameState(oldKey, newKey)` on the interface, `SecureWebViewStateStorage` (a file rename: the AES-GCM blob binds no associated data to its name today; if it ever does, rename becomes load and re-save) and `InMemoryWebViewStateStorage`; a missing source is a no-op; an existing destination is overwritten.
- [x] 2.4 Persistence (LIR-022): `toJson` writes a hosted tab with the owner's list, which an incognito owner never writes; the capture gate writes bytes only for a persisted record whose identity has `persistsNavState`.
- [ ] 2.5 Tests: model round-trip with and without a host; normalisation; host-keyed keys; session-only records for an incognito owner; `renameState` on both storages; orphan sweep keeps host-keyed live keys. *Done except `renameState`, which waits for 2.3.*

## 3. Hosted tabs: running as the host

- [x] 3.1 Identity view in `getWebView` (design D9): every POSTURE field, the identity plumbing (`cookieSiteId`, the `onCookiesChanged` target model and its `saveFunc`, `blockedCookies`, fingerprint seed, block-stats and notification attribution) and the navigation rules (`initUrl`, claims, `blockAutoRedirects`, `externalLinksInBrowser`, the `onOutboundLink` source) read from the running identity; slot plumbing reads `this`.
- [x] 3.2 Gate: extend `test/js/nested_webview_posture_parity.test.js` (or a sibling) so every POSTURE field in `getWebView`'s `WebViewConfig(...)` and in both `launchUrlFunc(...)` calls is read from the identity, never from `this`. *As `test/web_search_entry_test.dart` (the identity fields of `getWebView`) and `test/js/site_info_container_source.test.js` (the config binds `id.`), not an extension of the posture parity test.*
- [x] 3.3 HTML cache: `onHtmlLoaded`, `shouldFetchHtml` and `initialHtml` are inert while the active tab has a host. *`htmlSource` is `HtmlSource.none` while a hosted tab is active.*
- [x] 3.4 Owner loads bind an own tab first (design D8): home-shortcut launch, the Always open Home reset, `_executeOpenInMain`. A pure helper `TabLifecycleEngine.ownTabFor(tabs, activeTabId)` returns the tab to bind or null (seed a root). *The helper is `TabLifecycleEngine.ownerRunTab`; `_bindOwnerRunTab` goes through `_switchActiveTab` when the slot is loaded.*
- [x] 3.5 The tab sheet names the host on a hosted row.
- [ ] 3.6 Tests: posture and cookie mirror follow the host (a fake `ContainerCookieManager` keyed by site); HTML cache untouched; a shortcut launch on a hosted active tab binds the own parent first. *Structural checks and `test/hosted_tabs_test.dart` only; no cookie-manager fake yet.*

## 4. Hosted tabs: eligibility and creation

- [ ] 4.1 `hostCandidates(url, owner, sites, mayHost)` in `lib/services/link_routing_service.dart` (pure): navigation-domain filter, then LIR order (owner preferences, claim score, site order), minus the current identity. `mayHost` from `_WebSpacePageState`: container engine, both sides app-tier, host not effectively incognito. *`_mayHost` exists; `hostCandidates` does not.*
- [ ] 4.2 Long-press menu (`_showLinkLongPressMenu`): for a link outside the running identity's domain, one "Open in new tab as {site}" row per candidate, creating a parked child hosted by it (TAB-006 snackbar); in-domain links keep "Open in new tab" with the active tab's host.
- [ ] 4.3 `InAppWebViewScreen` gains `onKeepAsTab` (null for inbound-opened screens and under a locked kiosk shell). The menu item resolves the host per LIR-021, pops the screen, inserts the child under the tab it was opened from (root if that tab closed), and switches to it through `_switchActiveTab`.
- [ ] 4.4 Tests: `hostCandidates` (navigation-domain filter, claim-only non-candidate, ordering, incognito and archive exclusion, legacy engine); menu rows; Keep as tab for a routed screen, for a source-posture screen with a candidate, and disabled with none; no Keep as tab on an inbound-opened screen.

## 5. Hosted tabs: host lifecycle

- [x] 5.1 A pure `HostedTabGc.closeForHost(sites, hostId)` returning per-owner close plans (TAB-007 re-parenting, next active, bytes to drop). *As `TabLifecycleEngine.closeWhere`.*
- [x] 5.2 `_deleteSite(host)`: apply the plans and re-bind affected owners before `ContainerIsolationEngine.onSiteDeleted`. `_deleteSite(owner)`: drop its hosted tabs' host-keyed bytes.
- [x] 5.3 `_clearSiteData(host)`: dispose every slot whose identity is the host before `clearForSite`; `removeStatesForSite(host)` covers the bytes.
- [x] 5.4 `_moveSiteToArchive`: close tabs the site hosts elsewhere and the hosted tabs it owns, before the move. Settings save that turns `incognito` on for a host: close its hosted tabs.
- [x] 5.5 GC at startup, import and delete: close tabs whose `hostSiteId` names no eligible host.
- [ ] 5.6 Tests: delete ordering (the container delete sees no bound slot), clear disposes the owner slot, archive move and incognito close, import GC re-parents children; extend `test/archive_neutrality_test.dart` so an app-tier site with hosted tabs stays byte-identical with and without archives. *Structural checks in `test/web_search_entry_test.dart` and the import prune only.*

## 6. Hosted tabs: proxy and Tor

- [x] 6.1 `SiteUnloadEngine.indicesToUnloadForProxyMismatch`, `indicesToUnloadForTorExitMismatch`, `torExitNodesFor` gain `identityOf(int index)` (default `models[i]`); router mode's `sharesDefaultSession` reads the identity. *The engines take `_slotIdentities()` as their model list instead of an `identityOf` parameter.*
- [x] 6.2 Visible-slot rebind to a mismatched identity runs the PROXY-008 sequence first and fails closed; a background-slot rebind to a mismatched identity leaves the slot disposed and out of `_loadedIndices`.
- [ ] 6.3 Tests in `test/site_unload_engine_test.dart` and `test/proxy_mechanism_parity_test.dart`: identity-based eviction, the host's own slot kept when proxies agree, background rebind left unloaded, Tor pin read from the identity. *Covered by the structural check that every engine call site reads `_slotIdentities(`.*

## 7. Reattach instruments: engine

- [ ] 7.1 `TabLifecycleEngine.moveSubtree(...)` returning `TabMovePlan` (design D15): identities preserved and re-normalised against the destination; id re-minted on collision with a rename; drops when the destination does not persist the record; refusals (legacy engine, archive tier, a resulting host that may not host, a parent not in the destination).
- [x] 7.2 `TabLifecycleEngine.reparent(tabs, tabId, newParentId)`: refuses a parent inside the subtree; moves the subtree to follow the new parent's last descendant. Built with dragging (TAB-015) on `TabLifecycleEngine.move` and `drop`.
- [ ] 7.3 `TabLifecycleEngine.changeHost(owner, tabId, newHostId)`: normalised host, the old key to drop, children untouched.
- [ ] 7.4 `test/tab_lifecycle_engine_test.dart`: every rule above with in-memory fakes that model the host-keyed store (a moved tab's bytes are found under the same key afterwards; a renamed primary tab's bytes under the new one; a host change leaves nothing under either key).

## 8. Reattach instruments: UI and wiring

- [ ] 8.1 Row overflow menu in `lib/widgets/tabs_sheet.dart`: "Move to site...", "Move under...", "Run as..."; hidden under a locked kiosk shell; "Move to site..." and "Run as..." hidden on the legacy engine.
- [ ] 8.2 Pickers: eligible owners, then the destination tree with a "Top level" row; the same site's tree with the moved subtree greyed; hosts with the current one checked.
- [ ] 8.3 Call sites: guard with `_isTabHandling`; capture a moving active tab before applying the plan; apply renames and drops; re-bind the source owner through `_switchActiveTab(captureOutgoing: false)`; run 6.2 for any rebind; persist once; snackbar with "Switch" after a move.
- [ ] 8.4 Strings: code plus `lib/l10n/app_en.arb` (descriptions for every key: action labels, "Top level", "Open in new tab as {site}", "Keep as tab", "Keep as tab as {site}", refusal reasons) in one commit, the 66 translations in the next.
- [ ] 8.5 Widget tests in `test/tabs_sheet_test.dart`: menu visibility per engine and kiosk, picker contents, the moved subtree greyed, refusal messages.
- [x] 8.6 All sites view: drag a site's heading onto another to reorder sites (TAB-016) through the drawer's `_reorderSite`; the host hands the sheet its sites afresh.

- [x] 8.7 This site view: the subtrees other sites' trees run as the site, under "In {site}" (TAB-017), not draggable from there; collapse kept per site and tab.
- [x] 8.8 Container colours (TAB-018): `ContainerColors` tokens, `ContainerColorEngine` (least used, kept, app tier only), `ContainerMark` on every row and All sites heading, the dot in site info.
- [x] 8.9 TAB-017 across webspaces: the sheet gets every site with tabs, flagged in or out of the current webspace, and a tap on a hidden site's row switches to All. Covered end to end by `test/tabs_sheet_app_test.dart`, which pumps the shipped app and taps a link through the webview's own callback.
- [x] 8.10 This site is the list of the site the tab on screen runs as, with other sites' trees whole and folded around what runs as it (TAB-017); the way back from a jump, by Back or the "where you were" tab (TAB-019). `TabLifecycleEngine.rowsAround`, `TabReturnEngine`, real-app round trips in `test/tabs_sheet_app_test.dart`.
- [x] 8.9 Tests: `subtreesRunningAs` and `ContainerColorEngine` in `test/link_tab_container_test.dart`, the palette in `test/design_tokens_validity_test.dart`, the sheet in `test/tabs_sheet_test.dart`.
- [x] 8.10 Restored colours (TAB-018): `ContainerColorEngine.release`, applied by `planSettingsImport` and `_moveSiteOutOfArchive`; a moved-in site keeps its colour in the archive; `containerColor` excluded from the QR share and added to the backup superset. Tests in `test/link_tab_container_test.dart`.

## 9. Hosted tabs and reattach: manual smoke

- [ ] 9.1 Android and iOS: long-press a GitHub result in DuckDuckGo, "Open in new tab as GitHub", switch to it: signed in; back at its start returns to the results tab.
- [ ] 9.2 A routed GitHub screen, "Keep as tab": the tab stays in DuckDuckGo's tree after a restart.
- [ ] 9.3 Android without router mode, DuckDuckGo and GitHub on different proxies: activating the hosted tab applies GitHub's proxy; switching back applies DuckDuckGo's.
- [ ] 9.4 Move a subtree from DuckDuckGo to Mastodon; restart; both trees and back stacks survive.
- [ ] 9.5 Run a tab as Work GitHub instead of Personal GitHub: it reloads signed in as Work, with no back history.
- [ ] 9.6 Delete GitHub while a DuckDuckGo tab it hosts is active: the tab closes, DuckDuckGo shows the parent, GitHub's login is gone (a new GitHub site starts signed out).
