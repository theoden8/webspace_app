## 1. Search sites

- [x] 1.1 `lib/services/web_search_engine.dart`: the known hosts table, `capabilityOf` (a custom address wins, an invalid one searches nothing), `isValidTemplate`, `buildUrl`, `urlFor` with `site:`.
- [x] 1.2 `WebViewModel.searchAddress`, `searchesWeb`, `searchSites`, `searchDefault`: `toJson` omits defaults, `fromJson` reads a wrong type as absent.
- [x] 1.3 QR codec: `searchAddress` and `searchesWeb` included, `searchSites` and `searchDefault` excluded; `tool/backup_compat/superset.json` carries all four.
- [x] 1.4 Tests: `test/web_search_engine_test.dart`, the per-site fields in `test/hosted_tabs_test.dart`.

## 2. The sheet

- [x] 2.1 `WebSearchEngine.options`, `offersThisSite`, `initialScope`, `preselect`.
- [x] 2.2 `lib/widgets/web_search_sheet.dart`: query, scope, chips, the empty state with known engines to add; nothing to add inside an archive.
- [x] 2.3 `webSearchDefaultSite` in `kExportedAppPrefs`, default empty; the Default search row in App Settings.
- [x] 2.4 `_webSearch` in `lib/main.dart`: kiosk and re-entry guards, candidates from `_outboundCandidates`, the add-a-site path.
- [x] 2.5 Web search row in both overflow menus, below Find.
- [x] 2.6 Tests: `test/web_search_sheet_test.dart`, `test/web_search_entry_test.dart`.

## 3. Landing

- [x] 3.1 `WebSearchEngine.land`: child tab, hosted child tab, in place, or the search site.
- [x] 3.2 `_runSearch` and `_openSearchTab` (tab entry points behind the site's TAB-012 and TAB-013 gate).
- [x] 3.3 Fallback: `InboundOrigin.search` on `openInChosen`, no reset flags, `DispatchOpenInMain.newTab` while tabs are on; `_executeOpenInMain` opens it through `_newTab`.
- [x] 3.4 Return to owner (S6): `returnsToOwner` in `getWebView` before the nested and routed launches; `_returnToOwner` adds the child tab.
- [x] 3.5 Tests: the `land` group, the `openInChosen` search-origin group in `test/link_intent_dispatch_engine_test.dart`, the structural S6 checks.

## 4. References

- [x] 4.1 `WebViewModel.pruneSearchReferences`; `_pruneSearchReferences` beside every `_pruneOutboundPreferences`; `planSettingsImport` prunes against the restored sites and clears an app default it does not restore.
- [x] 4.2 `_pruneSearchDefaultPref` clears a missing or archive-tier app default.

## 5. Behaviour screen

- [x] 5.1 Search group: address dialog (known address kept unset when saved unchanged, Reset), default from this site, sites offered (dropping the default with it).
- [x] 5.2 Fields on `SiteBehaviourValues`, the settings screen's snapshot, load and save.
- [x] 5.3 Tests: the BEHAV-005 group in `test/site_behaviour_screen_test.dart`.

## 6. Links into the user's sites (LIR-032) and site info

- [x] 6.1 `LinkIntentDispatchEngine.routeToTab` and `DispatchOpenInTab`; the picker's `asTab`.
- [x] 6.2 `_routeOutboundLink(owner, ...)` asks `_tabRouteFor` before routing; `_openChildTab` shared by search, S6 and LIR-032; the long-press row enabled with "as {site}".
- [x] 6.3 `InAppWebViewScreen.onOpenAsTab`: the screen closes once, `launchUrl` opens the tab after the pop; a share-opened screen gets none.
- [x] 6.4 Routed nested screens open over the slot (`source: owner`), fixing the return from a hosted tab.
- [x] 6.5 Site info: `siteInfoContainerOf`, Tab of, Opened from.
- [x] 6.6 Tests: the `routeToTab` group, `test/link_as_tab_entry_test.dart`, `test/site_info_sheet_test.dart`.

## 7. Strings

- [x] 7.1 `webSearch*`, `tabsRunsAs` and the site info keys in `lib/l10n/app_en.arb`, then the 66 translations in their own commit.

## 8. Manual smoke

- [ ] 8.1 Android and iOS, Site tabs on: search the web from GitHub with a DuckDuckGo site; the results tab is labelled "as DuckDuckGo" and a `github.com` result returns to GitHub signed in.
- [ ] 8.2 Kagi signed in as its own site: search GitHub through Kagi; the results are signed in and GitHub's cookies are unchanged.
- [ ] 8.3 Android without the proxy router, GitHub and DuckDuckGo on different proxies: opening and leaving the results tab applies each proxy.
- [ ] 8.4 Site tabs off: the search switches to DuckDuckGo and loads there.
