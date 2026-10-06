## ADDED Requirements

### Requirement: LIR-028 - Search Sites

A search engine SHALL be one of the user's sites, never a bare address setting: a search runs in that site's container, with its sign-in, proxy, blockers and every other per-site setting.

A site SHALL be a **search site** when it has a search address, an http(s) URL with a host and at least one `%s` where the query goes. The address SHALL be the site's `searchAddress` when set and valid, else the one its host is known for, else the one its pages declared (LIR-035), else none. A `searchAddress` that is not a valid address SHALL make the site search nothing rather than fall back to the known one, so a user who typed an address never gets a different engine silently.

A search site SHALL be of one of two kinds:

- a **web search**, which searches everything;
- a **site search**, which searches only its own site.

A web search MAY take `site:<host>` to search inside another site. A site search never does.

Known hosts SHALL be recognised by the host of the site's `initUrl`. Each address is the one the engine's own OpenSearch description gives, less parameters that only name the referrer (`client=opensearch`, `fr=opensearch`). An engine takes `site:` only where its own documentation says so; one that does not say is offered for the web only.

| Host | Address | Kind | `site:` |
|------|---------|------|---------|
| `duckduckgo.com` and under, `duck.com` | `https://duckduckgo.com/?q=%s`; `html.` and `lite.` keep their own pages (`/html/?q=%s`, `/lite/?q=%s`) | web | yes |
| `search.brave.com` only (not `brave.com`) | `https://search.brave.com/search?q=%s` | web | yes |
| `kagi.com` and under | `https://kagi.com/search?q=%s` | web | yes |
| `perplexity.ai` and under | `https://www.perplexity.ai/search/new?q=%s` | web | yes |
| `google.com` and Google's country domains (`google.de`, `google.co.uk`, `google.com.au`), with or without `www.` | `https://www.<domain>/search?q=%s` | web | yes |
| `startpage.com` and under | `https://www.startpage.com/do/search?q=%s` | web | yes |
| `bing.com`, `www.bing.com`, `cn.bing.com` | `https://<host>/search?q=%s` (`www.bing.com` for the bare domain) | web | yes |
| `mojeek.com` and under | `https://www.mojeek.com/search?q=%s` | web | yes |
| `ecosia.org` and under | `https://www.ecosia.org/search?q=%s` | web | yes |
| `qwant.com` and under | `https://www.qwant.com/?q=%s` | web | yes |
| `metager.org`, `metager.de` and under | `https://<metager.org or metager.de>/meta/meta.ger3?eingabe=%s` | web | no |
| `swisscows.com` and under | `https://swisscows.com/web?query=%s` | web | no |
| `marginalia-search.com` and under, `search.marginalia.nu` | `https://marginalia-search.com/search?query=%s` | web | yes |
| `search.yahoo.com` | `https://search.yahoo.com/search?p=%s` | web | yes |
| Yandex's country domains (`yandex.ru`, `yandex.com.tr`) and `ya.ru` | `https://<domain>/search/?text=%s` | web | yes |
| `baidu.com`, `www.baidu.com` | `https://www.baidu.com/s?wd=%s` | web | yes |
| `naver.com`, `www.naver.com`, `search.naver.com` | `https://search.naver.com/search.naver?query=%s` | web | no |
| `search.seznam.cz` | `https://search.seznam.cz/?q=%s` | web | no |
| `github.com`, `www.github.com` | `https://github.com/search?q=%s` | site | n/a |
| `<lang>.wikipedia.org` | `https://<lang>.wikipedia.org/w/index.php?search=%s` | site | n/a |
| `youtube.com` and under | `https://www.youtube.com/results?search_query=%s` | site | n/a |
| `reddit.com` and under | `https://www.reddit.com/search/?q=%s` | site | n/a |
| `stackoverflow.com` and under | `https://stackoverflow.com/search?q=%s` | site | n/a |

A service on an engine's domain is not the engine: `mail.google.com`, `mail.yahoo.com` and `seznam.cz` search nothing until given an address. SearXNG has no host to recognise; its instances are found by LIR-035.

A `searchAddress` SHALL carry the kind the user gave it with `searchesWeb`: on, a web search that takes `site:`; off, a site search. Both fields are per-site configuration: they ride `WebViewModel.toJson`, are omitted at their defaults (null and false), and are read as absent when a backup holds a value of the wrong type.

A search URL SHALL be the address with every `%s` replaced by the trimmed query, encoded as one URL query component. A scoped search by a web search SHALL use the query `site:<host> <query>`, where `<host>` is the normalized domain of the site being searched. A blank query SHALL build nothing.

#### Scenario: A known engine needs no setup

- **GIVEN** the user has a site at `https://duckduckgo.com/`
- **THEN** it is a web search site with the address `https://duckduckgo.com/?q=%s`
- **AND** it takes `site:`

#### Scenario: Each Wikipedia searches its own language

- **GIVEN** a site at `https://de.wikipedia.org/wiki/Hauptseite`
- **THEN** it is a site search with the address `https://de.wikipedia.org/w/index.php?search=%s`

#### Scenario: An unknown site searches once given an address

- **GIVEN** a blog at `https://blog.example/` with no search address
- **THEN** it is not a search site
- **WHEN** the user sets its search address to `https://blog.example/?s=%s` with Searches the whole web off
- **THEN** it is a site search that does not take `site:`

#### Scenario: A self-hosted engine is a web search

- **GIVEN** a site at `https://searx.lan/` with search address `https://searx.lan/search?q=%s` and Searches the whole web on
- **THEN** it is a web search site that takes `site:`

#### Scenario: brave.com is not Brave Search

- **GIVEN** a site at `https://brave.com/`
- **THEN** it is not a search site

#### Scenario: The query stays one query

- **WHEN** the user searches for `a&b=c #d` with DuckDuckGo
- **THEN** the URL's `q` parameter is `a&b=c #d`
- **AND** the URL has no other parameter and no fragment

---

### Requirement: LIR-029 - Web Search From The Page Menu

Web search SHALL be reachable only while the Site tabs gate is open (TAB-012, DEVTOOLS-011): developer mode on and the Experimental group's Site tabs switch on. A search's results are a hosted tab, the feature tabs exist for, so the two ship together. While the gate is closed no page menu, sheet or URL bar SHALL offer a search, App Settings SHALL NOT offer Default search, the Behaviour screen SHALL have no Search group (BEHAV-005), and the URL bar SHALL load what is typed as an address, as before LIR-033. Search settings already stored SHALL be kept for when the gate opens again. Every way into a search SHALL return before acting, not only hide its button. The gate SHALL be read when it is used, so flipping either switch takes effect without a restart.

The Tabs sheet (TAB-008) SHALL offer "Web search" in its header, beside "New tab": a search opens a tab (LIR-030), so it sits with the other ways to make one. The label SHALL drop to its icon, with the label as its tooltip, when it would leave the sheet's title too little room, before "New tab" does, so the header fits a phone in every locale. While the site on screen has no tabs (TAB-012, TAB-013) there is no Tabs sheet for it, and both page overflow menus (the app bar's, and the bottom bar's when the tab strip is shown) SHALL offer "Web search" below Find instead; while it has tabs they SHALL NOT. Neither is reachable while the kiosk shell is locked (KIOSK-002). The URL bar searches too, under LIR-033. Find and shared links SHALL NOT change.

"Web search" SHALL open a sheet for the site on screen. The site on screen is the slot's running identity (LIR-018): the host when a hosted tab is active, else the site. The sheet SHALL hold a query field, a scope and a row of search-site chips.

- **Scope** SHALL be "The web" or the site on screen, by name. The site scope SHALL be offered only when the site on screen is not itself a web search, and the sheet SHALL start on it when the site has its own search, else on The web.
- **Chips for The web** SHALL be the web search sites.
- **Chips for the site** SHALL be its own search first, when it has one, then the web search sites that take `site:`, other than the site itself.
- **Candidates** SHALL be the site's LIR-014 candidates, which keeps a search on its own side of an archive boundary: from an app-tier site the app-tier sites, from an archive-tier site the sites of its archive.
- **Per-site list.** A site MAY declare `searchSites`, a list of siteIds. When non-empty, it limits the web search chips to the sites it names; the site's own search SHALL always be offered, even when the list omits it.
- **Preselection** SHALL be the site's `searchDefault` when it is among the chips, else the app default when it is among them, else the first chip.
- **App default.** The `webSearchDefaultSite` app pref SHALL hold the siteId of a web search site outside every archive, empty by default, so no build ships a preferred service. It SHALL be registered in `kExportedAppPrefs` and set from the App Settings row "Default search", whose explanation sits behind its hint (HINT-001) and whose subtitle is the site's name or "Not configured".
- **Telling sites apart.** Two sites can share a name (a work and a personal DuckDuckGo), never a siteId. Every list that picks a search site (the Default search dialog, and the Behaviour screen's Default search from this site and Search sites offered, BEHAV-005) SHALL show each site's siteId beneath its name, led by a dot in its container colour (TAB-018) on the container engine and by nothing on the legacy engine. The id stays in the muted text colour: the palette holds 3:1, a graphic's contrast, not the 4.5:1 a label needs (A11Y-010). Each chip in the sheet SHALL lead with the same dot.
- **Empty state.** When no chip exists, the sheet SHALL say so and offer the known web engines (DuckDuckGo, Brave Search, Kagi, Perplexity, Google, restricted to those that take `site:` in the site scope) as chips that add that engine as a new site at its home page, not activated, and run the search there. An engine one of the candidates already is SHALL NOT be offered, so a search never makes a second site for an engine the user has, even one the site's own list leaves out. Inside an archive the sheet SHALL offer no engine to add: the new site would be app-tier, and the search would leave the archive with it.

Submitting SHALL pop the sheet with the query, the scope and the chosen chip; a blank query SHALL do nothing and leave the sheet open. The sheet SHALL NOT load anything itself; LIR-030 decides where the search runs.

#### Scenario: GitHub opens on its own search (S1)

- **GIVEN** GitHub is on screen and the user has DuckDuckGo and Kagi sites
- **WHEN** the user chooses Web search
- **THEN** the scope is GitHub and the GitHub chip is selected
- **AND** the field reads "Search with GitHub"

#### Scenario: The web scope starts on the app default (S2)

- **GIVEN** the app default is Kagi
- **WHEN** the user switches the scope to The web
- **THEN** the chips are DuckDuckGo and Kagi, with Kagi selected

#### Scenario: A site without search is searched through an engine (S3)

- **GIVEN** a blog with no search address is on screen, and the user has DuckDuckGo, Kagi and MetaGer sites
- **WHEN** the user switches the scope to the blog
- **THEN** the chips are DuckDuckGo and Kagi, and MetaGer is not offered
- **AND** searching `webview` with Kagi searches `site:blog.example webview`

#### Scenario: A web engine on screen has no site scope (S5)

- **GIVEN** DuckDuckGo is on screen
- **WHEN** the user chooses Web search
- **THEN** no scope choice is shown and the DuckDuckGo chip is offered

#### Scenario: A site limits and picks its search sites (S11)

- **GIVEN** Work GitHub declares Work Kagi and DuckDuckGo, with Work Kagi as its default, and the user also has Perplexity and Personal Kagi
- **WHEN** the user searches the web from Work GitHub
- **THEN** the chips are Work Kagi, selected, and DuckDuckGo
- **AND** in the GitHub scope, GitHub's own search is still offered first

#### Scenario: A site with no declaration uses the app default (S12)

- **GIVEN** a site declares nothing and the app default is DuckDuckGo
- **WHEN** the user searches the web from it
- **THEN** every candidate web search site is offered, with DuckDuckGo selected

#### Scenario: The first search adds an engine (S10)

- **GIVEN** none of the user's sites is a web search site
- **WHEN** the user searches the web from a blog
- **THEN** the sheet offers DuckDuckGo, Brave Search, Kagi, Perplexity and Google to add
- **AND** picking Brave Search creates a site at `https://search.brave.com/` without switching to it, and the search runs there

#### Scenario: An engine the user has is not added again

- **GIVEN** the user has a DuckDuckGo site, and a blog whose search sites list names only a site since deleted
- **WHEN** the user searches the web from the blog
- **THEN** the sheet offers Brave Search, Kagi, Perplexity and Google to add, and not DuckDuckGo

#### Scenario: Two sites with one name

- **GIVEN** the container engine, and two DuckDuckGo sites, `ddg-work` in blue and `ddg-home` in pink
- **WHEN** the user opens Default search in App Settings
- **THEN** both are listed as DuckDuckGo, one with `ddg-work` beneath it after a blue dot and one with `ddg-home` after a pink dot

#### Scenario: Searching from an archived site (S15)

- **GIVEN** the site on screen lives in an open archive
- **WHEN** the user chooses Web search
- **THEN** only search sites in the same archive are offered
- **AND** the app default, which names no archive site, preselects nothing
- **AND** with no search site in the archive, no engine is offered to add

#### Scenario: Web search sits beside New tab

- **GIVEN** Site tabs are on and GitHub is on screen
- **WHEN** the user opens the Tabs sheet
- **THEN** its header offers Web search beside New tab
- **AND** neither page menu offers Web search

#### Scenario: With Site tabs off the menu offers it

- **GIVEN** Site tabs are off
- **THEN** both page menus offer Web search below Find

#### Scenario: A long label gives way to its icon

- **GIVEN** a locale whose Web search and New tab labels leave the title too little room on a phone
- **WHEN** the user opens the Tabs sheet
- **THEN** Web search shows as its icon, with the label as its tooltip, and the header does not overflow

#### Scenario: A locked kiosk shell has no web search

- **GIVEN** the app was launched from a kiosk site's shortcut
- **THEN** neither page menu offers Web search and the Tabs sheet cannot be opened

---

### Requirement: LIR-030 - Where Search Results Land

A search SHALL run in the search site the user chose, with that site's identity, and SHALL land as follows. "Can host" is LIR-019 for the chosen site in the owner's tree: the container engine, a host that is not effectively incognito, and neither site archive-tier. The owner is the site whose slot is on screen; the identity is what that slot runs as (LIR-018).

| The chosen search site is | The owner has tabs (TAB-012, TAB-013) | It has none |
|---|---|---|
| the identity | a child tab of the active tab, run as the identity | loaded in the active tab |
| the owner, while a hosted tab is on screen | a child tab of the active tab, run as the owner | the fallback below |
| another site that can host, with the search URL in its navigation domain | a **hosted child tab** of the active tab, owned by the owner and run as the search site | the fallback below |
| anything else | the fallback below | the fallback below |

The **fallback** SHALL be LIR-010's "open in this site" for the search site with `InboundOrigin.search`: when the URL is in the search site's navigation domain, `DispatchOpenInMain` with none of LIR-011's reset flags, opening a new tab of that site (TAB-005) while it has tabs and loading in its active tab while it has none; otherwise a nested screen with the search site's posture. A search typed in the app is the user's own navigation, as a query typed into the engine's own search box is, so an incognito or Always open Home search site keeps its session.

A results tab SHALL be a tab like any other: it parks with its back stack, reopens as the site it runs as, and is backed out of into the tab it was opened from (TAB-007).

Inside a hosted results tab, a link the host's rules would not load in place (LIR-018: nested, routed, or sent to the browser) whose normalized domain is the owner's navigation domain SHALL instead open as a child tab of the hosted tab, run as the owner, and take the slot. This is the owner's own content coming back to it, so the host's external-link mode and routing do not apply to it. A redirect without a gesture that the host blocks stays blocked.

#### Scenario: Search is gated with tabs

- **GIVEN** developer mode is on and the Site tabs switch is off
- **WHEN** the user opens the page menu, the URL bar and App Settings
- **THEN** there is no Web search item, no magnifier and no Default search row
- **AND** typing `flutter hot reload` in the URL bar and submitting loads it as an address
- **AND** turning the Site tabs switch on brings all three back with the search sites chosen before

#### Scenario: Own search opens a child tab (S1)

- **GIVEN** Site tabs are on and GitHub is on its repo page
- **WHEN** the user searches `flutter tabs` with GitHub
- **THEN** a child tab of the repo tab shows `https://github.com/search?q=flutter+tabs`, run as GitHub
- **AND** back at its start closes it and returns to the repo tab

#### Scenario: Another site's search opens a hosted child tab (S2)

- **GIVEN** Site tabs are on, the container engine is active and GitHub is on its repo page
- **WHEN** the user searches the web from GitHub with DuckDuckGo
- **THEN** a child tab of the repo tab shows the results, running as DuckDuckGo with its container, proxy and blockers
- **AND** GitHub's one webview is rebuilt as DuckDuckGo, with no second webview
- **AND** the tab list labels the row with DuckDuckGo

#### Scenario: A signed-in engine searches a site (S4)

- **GIVEN** the user is signed in to Kagi in their Kagi site
- **WHEN** the user searches GitHub through Kagi
- **THEN** the hosted tab searches `site:github.com flutter tabs` signed in as Kagi
- **AND** Kagi's cookies never reach GitHub's container, nor GitHub's Kagi's

#### Scenario: A search from the engine's own site is a plain child tab (S5)

- **GIVEN** DuckDuckGo is on screen
- **WHEN** the user searches with DuckDuckGo
- **THEN** the results open in a child tab run as DuckDuckGo, with no host

#### Scenario: A result on the owner's domain returns to the owner (S6)

- **GIVEN** S2's hosted results are on screen and DuckDuckGo would open `github.com` nested
- **WHEN** the user taps a `github.com` result
- **THEN** it opens as a child tab of the results tab, run as GitHub and signed in
- **AND** back closes it and returns to the results, and back again to the repo tab

#### Scenario: Links on the search site's domain load in place (S7)

- **GIVEN** S2's hosted results are on screen
- **WHEN** the user taps page 2 on `duckduckgo.com`
- **THEN** it loads in the same hosted tab and back steps through its history

#### Scenario: A result on a third site follows the search site's rules (S8)

- **GIVEN** S2's hosted results are on screen
- **WHEN** the user taps a `medium.com` result
- **THEN** it opens as DuckDuckGo's own settings say: its external link mode and, in the app, its routing to the user's sites or a nested screen with DuckDuckGo's posture

#### Scenario: Results survive a restart (S9)

- **GIVEN** S2's results tab is GitHub's active tab
- **WHEN** the app restarts
- **THEN** GitHub reopens on the results tab, running as DuckDuckGo, with its back stack

#### Scenario: With Site tabs off the search site takes over (S13)

- **GIVEN** Site tabs are off
- **WHEN** the user searches the web from GitHub with DuckDuckGo
- **THEN** the app switches to DuckDuckGo and loads the results in its page
- **AND** a search with GitHub's own search loads in GitHub's page

#### Scenario: A search site that cannot host takes over (S14)

- **GIVEN** Site tabs are on and the DuckDuckGo site is incognito, or the legacy cookie engine is active
- **WHEN** the user searches the web from GitHub with DuckDuckGo
- **THEN** the app switches to DuckDuckGo and opens the results as a new tab there
- **AND** an incognito DuckDuckGo's webview is not disposed, its container is not wiped and its cookies are not cleared

#### Scenario: Different proxies on a process-global proxy (S16)

- **GIVEN** Android without the proxy router, GitHub on proxy P1 and DuckDuckGo on P2
- **WHEN** S2's hosted results open
- **THEN** P2 is applied before the webview is rebuilt and other sites on P1 unload (LIR-024)
- **AND** going back to the repo tab applies P1 before rebuilding

---

### Requirement: LIR-031 - Search References Follow Their Sites

A site's `searchDefault` and `searchSites`, and the `webSearchDefaultSite` app pref, name other sites by siteId. They SHALL be pruned wherever LIR-017 prunes outbound preferences (startup, import, delete, a move across the archive boundary): a reference to a site that is gone or is no longer a candidate of the declaring site SHALL be dropped, and the app pref SHALL be cleared when it names a site that is missing or archive-tier, so plaintext app state never names an archive site (ARCH-001).

Every tab a search site hosts SHALL follow LIR-023: it closes when the site is deleted, moved into an archive or turned incognito, and its owner's slot is disposed and rebuilt when the site's data is cleared.

Backups SHALL carry all four per-site fields and the app pref. A site's QR share (QR-002) SHALL carry `searchAddress` and `searchesWeb`, which describe how to search the site, and SHALL NOT carry `searchSites` or `searchDefault`, which name sites on this device only, like `enabledGlobalScriptIds` (QR-003).

#### Scenario: Deleting a search site drops every reference to it (S17)

- **GIVEN** DuckDuckGo is the app default, GitHub's default and in Mastodon's list, and GitHub owns a tab it hosts
- **WHEN** the user deletes DuckDuckGo
- **THEN** GitHub's hosted tab closes before DuckDuckGo's container is deleted
- **AND** GitHub's default, Mastodon's list entry and the app default no longer name it

#### Scenario: Moving the app default into an archive clears it

- **GIVEN** Kagi is the app default
- **WHEN** the user moves Kagi into an archive
- **THEN** the app default is cleared

#### Scenario: The QR share carries how to search, not whom

- **GIVEN** a blog with a search address, a default search site and a list
- **WHEN** its QR payload is built
- **THEN** it holds `searchAddress` and `searchesWeb`
- **AND** it holds neither `searchDefault` nor `searchSites`

---

### Requirement: LIR-032 - A Link Into One Of The User's Sites Opens As Its Tab

While the site on screen has tabs (TAB-012, TAB-013), a link that would open a nested screen (`blockOpenNested`) SHALL open as a tab instead when one of the user's sites can run it: a site whose navigation domain is the link's normalized domain and that may host in the tree of the site on screen (LIR-019), or that site itself. It SHALL open as a child of the tab it came from and take the slot. A nested page of one of the user's own sites is exactly what tabs replace, so the source's routing switch (LIR-013) SHALL NOT decide whether the tab opens; it decides which site the tab runs as (LIR-034), and with it the container and every per-site setting that comes with a site (LIR-018): on, that site; off, the source, inside the link's domain. Off, the source SHALL itself be able to run in the tree of the site on screen (LIR-019), or be that site. The switch still decides alone for a link no site of the user's can run as a tab (a site that cannot host, a claim outside a navigation domain) and for a site without tabs.

The same gates as routing SHALL hold (LIR-014): the container engine, an effective user gesture, and no locked kiosk shell. With the switch on, the site SHALL be chosen as LIR-014 chooses: the source's outbound preferences first, then claim specificity. When several sites remain, the LIR-016 picker SHALL ask, and a pick opens the tab; its remember checkbox writes the preference as for routing. With the switch off nothing is asked. The source is the site the page on screen runs as (LIR-018), and a link to a site on the other side of an archive boundary is never a candidate.

A link tapped inside a nested screen that was opened from a tab SHALL go the same way: the nested screen closes and the tab opens under the tab it was opened from, once the screen is gone and before whatever its opener runs on close (the proxy return of LIR-015). A nested screen a share opened (LIR-011) came from no tab and SHALL keep loading such links in place.

A routed nested screen (LIR-015) SHALL open over, and on close bring back, the slot on screen, whatever that slot runs as.

#### Scenario: A GitHub result opens as GitHub's tab

- **GIVEN** Site tabs are on, the user has DuckDuckGo and GitHub sites, and DuckDuckGo's routing switch is on
- **WHEN** the user taps a `github.com` result in DuckDuckGo
- **THEN** a child tab of DuckDuckGo's current tab opens, running as GitHub and signed in
- **AND** no nested screen opens

#### Scenario: With routing off it opens as DuckDuckGo's tab

- **GIVEN** the same sites, and DuckDuckGo's routing switch is off
- **WHEN** the user taps a `github.com` result in DuckDuckGo
- **THEN** a child tab of DuckDuckGo's current tab opens at the result, running as DuckDuckGo in DuckDuckGo's container, not signed in to GitHub
- **AND** no nested screen opens, and nothing is asked even when two sites could run it

#### Scenario: A site the user does not have stays nested

- **GIVEN** Site tabs are on
- **WHEN** the user taps a `medium.com` result in DuckDuckGo
- **THEN** it opens as DuckDuckGo's settings decide, in a nested screen with DuckDuckGo's posture or routed

#### Scenario: A link inside a nested page comes back as a tab

- **GIVEN** a `medium.com` nested screen opened from DuckDuckGo's current tab
- **WHEN** the user taps a `github.com` link on it
- **THEN** the nested screen closes
- **AND** a child tab of that DuckDuckGo tab opens running as GitHub

#### Scenario: Two sites that can run it ask

- **GIVEN** Work GitHub and Personal GitHub both at `github.com`, DuckDuckGo's routing switch on, and no preference in DuckDuckGo
- **WHEN** the user taps a `github.com` link in DuckDuckGo
- **THEN** the picker offers both, and the one picked runs the new tab

#### Scenario: Tabs off keeps today's behaviour

- **GIVEN** Site tabs are off
- **WHEN** the user taps a `github.com` link in DuckDuckGo
- **THEN** it opens nested, with GitHub's posture when DuckDuckGo routes and its own otherwise

#### Scenario: A kiosk site opens no tab

- **GIVEN** Site tabs are on, and DuckDuckGo has Kiosk mode on (TAB-013)
- **WHEN** the user taps a `github.com` link in DuckDuckGo
- **THEN** it opens as DuckDuckGo's routing decides, as with tabs off, and DuckDuckGo's tab list is unchanged

#### Scenario: A routed screen from a hosted tab brings back its slot

- **GIVEN** DuckDuckGo's slot runs a GitHub tab on Android without the proxy router, and GitHub routes `codeberg.page` to a Codeberg site on another proxy, which cannot run it as a tab because its navigation domain is `codeberg.org`
- **WHEN** the user taps a `codeberg.page` link and later closes the Codeberg screen
- **THEN** DuckDuckGo's slot is re-activated, running as GitHub, under GitHub's proxy

---

### Requirement: LIR-033 - Search From The URL Bar

The URL bar of the site on screen SHALL search as well as open addresses, with the search sites, landing and archive boundary of a search from the sheet (LIR-029, LIR-030).

- **Magnifier.** Beside the site info button the bar SHALL show a magnifier. Tapping it SHALL empty the field and turn it into a search field whose placeholder names the search site, "Search with {site}", with the keyboard's search action.
- **Search sites.** The bar SHALL offer the search sites the sheet offers for The web, then the site on screen's own search when it has one, none of them scoped with `site:`. It SHALL start on the sheet's web preselection (the site's `searchDefault`, else the app default, else the first), or on the site's own search when no site searches the web. With more than one, a control at the start of the search field SHALL list them to pick from, and picking SHALL keep the field and what is typed in it.
- **Words typed as an address.** Text submitted in the address field that does not look like an address SHALL be searched with the bar's default search site; while such text is typed, the submit button SHALL be a magnifier whose tooltip names that site. An address is anything with a scheme, or one token that is `localhost`, an IP address, a `host:port`, or a dotted host whose last label is letters; text with a space, a single bare word and an email address are searched. Text in the search field SHALL always be searched, even when it looks like an address.
- **No search site.** A search with no search site SHALL open the sheet with the query filled in, whose empty state offers a known engine to add.
- **Leaving.** Leaving the field without submitting SHALL end search mode and show the page's URL again. A blank search SHALL do nothing.
- The nested screen's URL bar SHALL stay an address field, and a locked kiosk shell SHALL offer no search (KIOSK-002).

#### Scenario: The magnifier searches with the default

- **GIVEN** the app default is Kagi and GitHub is on screen with Site tabs on
- **WHEN** the user taps the magnifier in the URL bar, types `webview` and submits
- **THEN** the field read "Search with Kagi" before anything was typed
- **AND** the Kagi search opens as GitHub's hosted child tab labelled "as Kagi" (LIR-030)

#### Scenario: Another search site from the bar

- **GIVEN** the user has DuckDuckGo and Kagi sites and DuckDuckGo is the default
- **WHEN** the user taps the magnifier, picks Kagi and searches `webview`
- **THEN** Kagi runs the search

#### Scenario: Words in the address field search

- **GIVEN** DuckDuckGo is the default search site
- **WHEN** the user types `flutter hot reload` in the URL bar and submits
- **THEN** DuckDuckGo searches `flutter hot reload`
- **AND** typing `codeberg.org/theoden8` instead opens that address as before

#### Scenario: No search site yet

- **GIVEN** none of the user's sites searches
- **WHEN** the user types `webview` in the URL bar and submits
- **THEN** the web search sheet opens with `webview` in its field, offering search engines to add

---

### Requirement: LIR-034 - What A Link Tab Runs As Follows Its Opener

A tab opened by LIR-032 SHALL record the site whose page opened it, its **opener** (the source: the site the page on screen ran as), and the link it was opened at, its **home**. For as long as the tab exists, the opener's routing switch (LIR-013) SHALL decide which site it runs as, and so its whole posture as LIR-018 lists it: the container with its sign-in, the proxy, user agent, language, blockers, Tracking Protection, location, WebRTC policy, user scripts and every other per-site setting. What belongs to the slot (pause, retention, background audio, the kiosk and fullscreen shell) stays the owner's, as for any hosted tab.

- **on:** the site the link leads to, chosen as LIR-032 chooses (a preference of the opener's, then claims). When several sites remain, the tab SHALL keep the one it runs as when that is one of them, and run as the opener otherwise: a move asks nothing.
- **off:** the opener.

A tab that runs as its opener in the home's domain is a **foreign tab**. It loads the link's pages with the opener's posture, user scripts included, as a nested screen of the opener's does (LIR-015). It SHALL navigate by the home's domain alone: Home (NAV-004), the URL bar's in-site check and the web search scope use the home, a link out of that domain leaves the tab as any cross-domain link does (a link back into the opener's own domain opening as the opener's child tab, S6), and it SHALL borrow none of the opener's claims (LIR-005). An owner URL (LIR-018) SHALL never load into a foreign tab: it moves to a tab the owner runs in its own domain, or to a new root tab at home.

When an opener's switch changes, every tab it opened SHALL move to the site the switch now names, in every site's list, once the opener's settings close, and at startup and after an import for a list stored under the other setting. A moved tab's stored back stack (TAB-003) SHALL be deleted rather than restored as the other site; the tab on screen SHALL reload as its new site at once, under that site's proxy (LIR-024), a live slot in the background SHALL drop its webview, and a stored tab SHALL load as its new site when next opened. A move SHALL hold the hosted-tab rules: a tab that can no longer run as the site it moved to closes (LIR-023).

A tab whose opener is deleted SHALL keep the site it runs as and follow nothing. Tabs nothing routes SHALL keep the site they were opened as: a search's results (LIR-030), a tab opened by hand, and "Open in new tab" on a link inside the page's own domain. A duplicate (TAB-010) and "Open in new tab" on a link inside a link tab's domain SHALL keep its opener and home.

The move SHALL NOT race a tab change: it SHALL wait for an open, close, switch or move of tabs that is running, run once after it however often it was asked for, and rewrite every list in one step. Bytes a capture took across a move SHALL be dropped rather than saved under the tab's new site.

#### Scenario: Turning routing off moves GitHub tabs to DuckDuckGo

- **GIVEN** DuckDuckGo's routing switch is on, and a `github.com` link from DuckDuckGo opened as a tab running as GitHub, now on screen
- **WHEN** the user turns DuckDuckGo's routing switch off and closes its settings
- **THEN** the tab reloads at its page running as DuckDuckGo, not signed in to GitHub, through DuckDuckGo's proxy and with DuckDuckGo's user agent and blockers
- **AND** the back stack it had as GitHub is deleted

#### Scenario: Turning it back on moves it back

- **GIVEN** that tab running as DuckDuckGo, stored
- **WHEN** the user turns DuckDuckGo's routing switch on again and later opens the tab
- **THEN** it loads running as GitHub, signed in

#### Scenario: A foreign tab stays in its link's domain

- **GIVEN** DuckDuckGo's routing switch is off, and a tab running as DuckDuckGo opened at `github.com/flutter`
- **WHEN** the user taps Home
- **THEN** the tab goes to `github.com/flutter`, not `duckduckgo.com`
- **AND** a `duckduckgo.com` link tapped on it opens as a child tab DuckDuckGo runs in its own domain

#### Scenario: A search keeps the site it runs as

- **GIVEN** a search GitHub ran in DuckDuckGo, open as GitHub's hosted tab (LIR-030)
- **WHEN** the user turns GitHub's routing switch off
- **THEN** the search tab still runs as DuckDuckGo

#### Scenario: A pick survives only while it is still a choice

- **GIVEN** Work GitHub and Personal GitHub both at `github.com`, DuckDuckGo's routing switch on, and a link tab the user picked Personal GitHub for
- **WHEN** DuckDuckGo's settings close with the switch still on
- **THEN** the tab still runs as Personal GitHub, and nothing is asked

#### Scenario: A move waits for a tab switch

- **GIVEN** a tab switch in DuckDuckGo is capturing its outgoing tab
- **WHEN** DuckDuckGo's settings close with its routing switch flipped
- **THEN** the move runs once the switch has finished, once
- **AND** no back stack is saved under the site a tab has just left

---

### Requirement: LIR-035 - A Site Learns Its Search From Its Own Pages

A site with no `searchAddress` and a host LIR-028 does not know SHALL learn its search address from its own pages, the way browsers add search engines: OpenSearch autodiscovery. Every SearXNG instance declares itself this way, and so do many sites with their own search.

- **What is read.** After the load event of the site's top document, a watcher SHALL report the document's `<link rel="search" type="application/opensearchdescription+xml">` links (`href` resolved by the page, at most four) and its `<meta name="generator">`. It SHALL run in the site's root webview only, main frame only: never in a popup, a nested screen or a subframe, whose search is not the site's. It SHALL NOT fetch anything.
- **What is fetched.** The app SHALL read a reported description only when the document and the link are both inside the site's navigation domain (LIR-018), through the site's proxy and its DNS and content blockers, with the private-range guard and redirect rules of page icon fetches (ICON-013), at most 64 KiB, and once per webview per description.
- **What is taken.** The address SHALL be the description's first `text/html` results URL with `{searchTerms}` as `%s`. Parameters OpenSearch 1.1 gives a value for are filled (`inputEncoding`, `outputEncoding`, `language`, `startIndex`, `startPage`); optional ones are dropped; a URL with any other required parameter is not used. A `POST` URL is used only for a SearXNG or searx instance, which answers the same query by `GET`. The address SHALL be taken only when it is valid under LIR-028 and inside the site's navigation domain, so no page can hand its site's searches to another host.
- **What kind.** A page whose generator names SearXNG or searx (`searxng/2026.7.20`, `searx/1.1.0`) SHALL make the site a web search that takes `site:`. Any other page SHALL make it a site search, offered only for searching itself: a page cannot promote itself into the chips every other site offers.
- **Precedence.** A `searchAddress` the user set, then the known host table, SHALL win over a discovered address. A discovered address outside the current `initUrl`'s domain SHALL be ignored, so editing a site's home drops what its old home declared.
- **Storage.** The address and its kind SHALL be stored on the site as `discoveredSearchAddress` and `discoveredSearchesWeb`, omitted until something is found and read as absent when of the wrong type. An incognito site SHALL keep them in memory only. They SHALL ride a backup like any site field and SHALL NOT ride the QR share (QR-003): the receiver learns them from the same pages. For an archive-tier site they live only in the archive (ARCH-006).
- **Gate.** Discovery SHALL run only while web search is reachable (LIR-029), read when each report arrives.
- The Behaviour screen's Search address row (BEHAV-005) SHALL show a discovered address as the site's effective one, with Searches the whole web reflecting its kind; saving it unchanged SHALL store nothing, as for a known address.

#### Scenario: A SearXNG instance is a web search once opened

- **GIVEN** the user adds `https://searx.lan/`, a SearXNG instance whose pages carry `<meta name="generator" content="searxng/2026.7.20">` and link `/opensearch.xml?method=POST`
- **WHEN** the site's page has loaded once with web search on
- **THEN** it is a web search site with the address `https://searx.lan/search?q=%s` that takes `site:`
- **AND** it is offered in Default search and as a chip for The web

#### Scenario: A site's own search is offered for itself only

- **GIVEN** a site at `https://blog.example/` whose pages link an OpenSearch description with `https://blog.example/search?q={searchTerms}`
- **THEN** after a load it is a site search with the address `https://blog.example/search?q=%s`
- **AND** it is not offered as a chip for The web on any other site

#### Scenario: A description pointing elsewhere is ignored

- **GIVEN** a page of `https://blog.example/` links a description on `tracker.example.net`, or one whose results URL is on `tracker.example.net`
- **THEN** the first is never fetched and the second is never taken

#### Scenario: The user's address wins

- **GIVEN** a SearXNG site that has a discovered address
- **WHEN** the user sets its search address to `https://searx.lan/search?categories=it&q=%s`
- **THEN** searches use the user's address
