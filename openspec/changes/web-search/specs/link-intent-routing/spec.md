## ADDED Requirements

### Requirement: LIR-028 - Search Sites

A search engine SHALL be one of the user's sites, never a bare address setting: a search runs in that site's container, with its sign-in, proxy, blockers and every other per-site setting.

A site SHALL be a **search site** when it has a search address, an http(s) URL with a host and at least one `%s` where the query goes. The address SHALL be the site's `searchAddress` when set and valid, else the one its host is known for, else none. A `searchAddress` that is not a valid address SHALL make the site search nothing rather than fall back to the known one, so a user who typed an address never gets a different engine silently.

A search site SHALL be of one of two kinds:

- a **web search**, which searches everything;
- a **site search**, which searches only its own site.

A web search MAY take `site:<host>` to search inside another site. A site search never does.

Known hosts SHALL be recognised by the host of the site's `initUrl`:

| Host | Address | Kind | `site:` |
|------|---------|------|---------|
| `duckduckgo.com` and under | `https://duckduckgo.com/?q=%s` | web | yes |
| `search.brave.com` only (not `brave.com`) | `https://search.brave.com/search?q=%s` | web | yes |
| `kagi.com` and under | `https://kagi.com/search?q=%s` | web | yes |
| `perplexity.ai` and under | `https://www.perplexity.ai/search/new?q=%s` | web | no |
| `google.com`, `www.google.com` | `https://www.google.com/search?q=%s` | web | yes |
| `startpage.com` and under | `https://www.startpage.com/do/search?q=%s` | web | yes |
| `bing.com`, `www.bing.com` | `https://www.bing.com/search?q=%s` | web | yes |
| `mojeek.com` and under | `https://www.mojeek.com/search?q=%s` | web | yes |
| `ecosia.org` and under | `https://www.ecosia.org/search?q=%s` | web | yes |
| `github.com`, `www.github.com` | `https://github.com/search?q=%s` | site | n/a |
| `<lang>.wikipedia.org` | `https://<lang>.wikipedia.org/w/index.php?search=%s` | site | n/a |
| `youtube.com` and under | `https://www.youtube.com/results?search_query=%s` | site | n/a |
| `reddit.com` and under | `https://www.reddit.com/search/?q=%s` | site | n/a |
| `stackoverflow.com` and under | `https://stackoverflow.com/search?q=%s` | site | n/a |

Perplexity is a web search without `site:`: it answers a question rather than filtering an index, so it is not offered for searching another site.

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

Both page overflow menus (the app bar's, and the bottom bar's when the tab strip is shown) SHALL offer "Web search", below Find, except while the kiosk shell is locked (KIOSK-002). Find, the URL bar and shared links SHALL NOT change: text typed in the URL bar is still a URL, never a search.

"Web search" SHALL open a sheet for the site on screen. The site on screen is the slot's running identity (LIR-018): the host when a hosted tab is active, else the site. The sheet SHALL hold a query field, a scope and a row of search-site chips.

- **Scope** SHALL be "The web" or the site on screen, by name. The site scope SHALL be offered only when the site on screen is not itself a web search, and the sheet SHALL start on it when the site has its own search, else on The web.
- **Chips for The web** SHALL be the web search sites.
- **Chips for the site** SHALL be its own search first, when it has one, then the web search sites that take `site:`, other than the site itself.
- **Candidates** SHALL be the site's LIR-014 candidates, which keeps a search on its own side of an archive boundary: from an app-tier site the app-tier sites, from an archive-tier site the sites of its archive.
- **Per-site list.** A site MAY declare `searchSites`, a list of siteIds. When non-empty, it limits the web search chips to the sites it names; the site's own search SHALL always be offered, even when the list omits it.
- **Preselection** SHALL be the site's `searchDefault` when it is among the chips, else the app default when it is among them, else the first chip.
- **App default.** The `webSearchDefaultSite` app pref SHALL hold the siteId of a web search site outside every archive, empty by default, so no build ships a preferred service. It SHALL be registered in `kExportedAppPrefs` and set from the App Settings row "Default search", whose explanation sits behind its hint (HINT-001) and whose subtitle is the site's name or "Not configured".
- **Empty state.** When no chip exists, the sheet SHALL say so and offer the known web engines (DuckDuckGo, Brave Search, Kagi, Perplexity, Google, restricted to those that take `site:` in the site scope) as chips that add that engine as a new site at its home page, not activated, and run the search there. Inside an archive the sheet SHALL offer no engine to add: the new site would be app-tier, and the search would leave the archive with it.

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

- **GIVEN** a blog with no search address is on screen, and the user has DuckDuckGo, Kagi and Perplexity sites
- **WHEN** the user switches the scope to the blog
- **THEN** the chips are DuckDuckGo and Kagi, and Perplexity is not offered
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

#### Scenario: Searching from an archived site (S15)

- **GIVEN** the site on screen lives in an open archive
- **WHEN** the user chooses Web search
- **THEN** only search sites in the same archive are offered
- **AND** the app default, which names no archive site, preselects nothing
- **AND** with no search site in the archive, no engine is offered to add

#### Scenario: A locked kiosk shell has no web search

- **GIVEN** the app was launched from a kiosk site's shortcut
- **THEN** neither page menu offers Web search

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

While the site on screen has tabs (TAB-012, TAB-013), a link that would open a nested screen (`blockOpenNested`) SHALL open as a tab instead when one of the user's sites can run it: a site whose navigation domain is the link's normalized domain and that may host in the tree of the site on screen (LIR-019), or that site itself. It SHALL open as a child of the tab it came from, run as that site, and take the slot. A nested page of one of the user's own sites is exactly what tabs replace, so the source's routing switch (LIR-013) SHALL NOT gate this; it still decides for a link no site of the user's can run as a tab (a site that cannot host, a claim outside a navigation domain) and for a site without tabs.

The same gates as routing SHALL hold (LIR-014): the container engine, an effective user gesture, and no locked kiosk shell. The site SHALL be chosen as LIR-014 chooses: the source's outbound preferences first, then claim specificity. When several sites remain, the LIR-016 picker SHALL ask, and a pick opens the tab; its remember checkbox writes the preference as for routing. The source is the site the page on screen runs as (LIR-018), and a link to a site on the other side of an archive boundary is never a candidate.

A link tapped inside a nested screen that was opened from a tab SHALL go the same way: the nested screen closes and the tab opens under the tab it was opened from, once the screen is gone and before whatever its opener runs on close (the proxy return of LIR-015). A nested screen a share opened (LIR-011) came from no tab and SHALL keep loading such links in place.

A routed nested screen (LIR-015) SHALL open over, and on close bring back, the slot on screen, whatever that slot runs as.

#### Scenario: A GitHub result opens as GitHub's tab

- **GIVEN** Site tabs are on, the user has DuckDuckGo and GitHub sites, and DuckDuckGo's routing switch is off
- **WHEN** the user taps a `github.com` result in DuckDuckGo
- **THEN** a child tab of DuckDuckGo's current tab opens, running as GitHub and signed in
- **AND** no nested screen opens

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

- **GIVEN** Work GitHub and Personal GitHub both at `github.com`, and no preference in DuckDuckGo
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
