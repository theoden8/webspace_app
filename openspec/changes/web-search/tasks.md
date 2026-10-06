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
- [x] 2.5 Web search in the Tabs sheet header beside New tab, the label dropping to its icon where it does not fit; the overflow-menu rows only for a site without tabs (TAB-013).
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

## 6a. Link tabs follow their opener (LIR-034)

- [x] 6a.1 `SiteTab.openerSiteId` and `homeUrl`, sanitised on read; `routeToTab` takes the source's `routeOutboundLinks`; `linkTabRunsAs` for a stored tab.
- [x] 6a.2 Foreign tabs: `isForeignTab`, `navigationHomeUrl`, `navigationMatchesClaim`, `decideUserOpenedLink` anchored at the tab's home; `ownerRunTab` skips them; Home, the URL bar, web search scope and the long-press row read the tab's anchor.
- [x] 6a.3 `_reconcileLinkTabs` after site settings, at startup and after an import, deferred through `TabHandlingGate` while a tab handler runs; the capture keeps the key it started under.
- [x] 6a.4 With tabs on, the route hint says which site a link tab runs as, with its sign-in and settings (`siteSettingsRouteOutboundLinksTabsHint`).
- [x] 6a.5 Tests: the `linkTabRunsAs` matrix, `test/link_tab_container_test.dart`, `test/tab_handling_gate_test.dart`, `test/link_tab_reconcile_entry_test.dart`.
- [ ] 6a.6 Manual, Site tabs on: a `github.com` result from DuckDuckGo with routing on runs signed in; turn routing off, close settings: it reloads signed out; Home stays on `github.com`.

## 7. Strings

- [x] 7.1 `webSearch*`, `tabsRunsAs` and the site info keys in `lib/l10n/app_en.arb`, then the 66 translations in their own commit.

## 8. Manual smoke

- [ ] 8.1 Android and iOS, Site tabs on: search the web from GitHub with a DuckDuckGo site; the results tab is labelled "as DuckDuckGo" and a `github.com` result returns to GitHub signed in.
- [ ] 8.2 Kagi signed in as its own site: search GitHub through Kagi; the results are signed in and GitHub's cookies are unchanged.
- [ ] 8.3 Android without the proxy router, GitHub and DuckDuckGo on different proxies: opening and leaving the results tab applies each proxy.
- [ ] 8.4 Site tabs off: the search switches to DuckDuckGo and loads there.

## 9. URL bar search (LIR-033)

- [x] 9.1 `looksLikeAddress` in `lib/utils/url_utils.dart`; `WebSearchEngine.barOptions`.
- [x] 9.2 `UrlBar`: magnifier, search mode with the search site picker, a submit button that shows whether Enter searches; `searchSites`, `defaultSearchSiteId`, `onSearch`.
- [x] 9.3 `_urlBarSearchFor` and `_searchFromUrlBar` in `lib/main.dart`; the cached app default; `WebSearchSheet.initialQuery` for a search with no search site.
- [x] 9.4 `urlBarSearchSiteTooltip` in `lib/l10n/app_en.arb`, then the 66 translations.
- [x] 9.5 Tests: `test/url_bar_search_test.dart`, `looksLikeAddress` in `test/url_utils_test.dart`, the `barOptions` group, the structural LIR-033 checks.
- [ ] 9.6 Manual, URL bar shown: the magnifier searches with the default and the picker switches site; `flutter hot reload` typed in the address field searches, `codeberg.org` opens.

## 10. Engines, discovery and telling sites apart

- [x] 10.1 Known hosts: Perplexity takes `site:`; Google country domains, `duck.com` and DuckDuckGo's HTML and Lite editions, `cn.bing.com`, Qwant, MetaGer, Swisscows, Marginalia, Yahoo, Yandex, Baidu, Naver, Seznam.
- [x] 10.2 `lib/services/opensearch_engine.dart` (description parser, `discoverPageSearch`), `lib/services/search_link_watcher_shim.dart`, the `kSearchLinksHandler` in `webview.dart`, `SiteSearchTarget` from `WebViewModel.getWebView`; `fetchPageLinkedBytes` shared with page icons.
- [x] 10.3 `discoveredSearchAddress` and `discoveredSearchesWeb` on `WebViewModel` (incognito keeps them in memory), excluded from the QR share, in the backup superset.
- [x] 10.4 `WebSearchEngine.addable`: the empty state never offers an engine the user has.
- [x] 10.5 `SiteIdLine` under each site in Default search and the Behaviour pickers, a colour dot on each sheet chip.
- [x] 10.6 Tests: `test/opensearch_engine_test.dart`, `test/js/search_link_watcher.test.js`, the LIR-035 structural check in `test/js/page_bridge_authority.test.js`, the table and discovery groups in `test/web_search_engine_test.dart`, sheet, Behaviour and App Settings widget tests.
- [ ] 10.7 Manual, Site tabs on: add a SearXNG instance, open it once; it appears in Default search and as a chip for The web, and searching from GitHub through it with `site:` lands in a hosted tab.
- [x] 10.8 Site search list (LIR-036): `site_search_list_engine.dart` (reduction, lookup), `SiteSearchListService` (download through the app-wide proxy, stored reduction, clear), the App Settings row behind the search gate, `assets/licenses/kagi_bangs.txt`; `webSearchSiteList*` strings in `app_en.arb`, then the 66 translations. Tests: `test/site_search_list_test.dart`, the row in `test/app_settings_experimental_test.dart`, the gate in `test/web_search_entry_test.dart`.
- [ ] 10.9 Manual, Site tabs on: download the site search list, add `https://www.imdb.com/`, search it from its own sheet.

