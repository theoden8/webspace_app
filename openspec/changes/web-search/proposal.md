## Why

Issue #422 asks for a search in the page menu: type a query and it opens with a
default search engine, which the user can set in App Settings.

In WebSpace a search engine is not a neutral service. It has a sign-in (Kagi),
a proxy, blockers and cookies, and the user already keeps it as a site with its
own container. A bare engine address setting would run searches outside all of
that, in whichever site happened to be on screen. So a search engine is one of
the user's sites, and the question is which site runs a search and where its
results land.

The design, with 18 scenarios, was reviewed as the "Web Search Flows" page
before implementation; the scenario ids (S1 to S18) are carried into the
requirements.

## What Changes

- **Search sites** (LIR-028). A site searches when it has a search address, a
  URL with `%s`. Known hosts fill it in: DuckDuckGo, Brave Search, Kagi,
  Perplexity, Google, Startpage, Bing, Mojeek, Ecosia as web searches; GitHub,
  Wikipedia in any language, YouTube, Reddit and Stack Overflow as site
  searches. Any other site can be given an address on its Behaviour screen,
  and says whether it searches the whole web. Web searches other than
  Perplexity can search inside another site with `site:`.
- **The sheet** (LIR-029). "Web search" in the Tabs sheet header, beside New
  tab (in both page menus, below Find, only for a site without tabs), opens a
  sheet with a query, a scope (The web, or the site on screen) and a chip per
  search site. A site may declare which search sites it offers and which it
  starts with; the app has a Default search in App Settings. With no search
  site at all, the sheet offers to add a known engine as a site.
- **Where results land** (LIR-030). Where the site on screen has tabs, its own search
  opens a child tab; another site's search opens a **hosted child tab**, a tab
  in the current site's tree that runs as the search site (LIR-018). Tabs off,
  a search site that cannot host, or an address off the search site's domain
  fall back to opening in the search site itself, as LIR-010's "open in this
  site" does, with no LIR-011 reset. A link back to the owner's domain from a
  hosted results tab returns to the owner as its child tab (S6).
- **References** (LIR-031). The per-site declarations and the app default name
  sites by id, so they are pruned where LIR-017 prunes, including on import,
  and the app default never names an archived site.
- **Behaviour screen** (BEHAV-005). A Search group: the search address, the
  default search from this site, and the search sites it offers.
- **Hosted tabs core** from the `inactive-tabs` change, since results from
  another site's search have nowhere else to go: LIR-018 (running as another
  site), LIR-019 (who may host), LIR-022 (state keyed by the host), LIR-023
  (host deleted, archived, turned incognito or cleared) and LIR-024 (the
  process-global proxy follows what a slot runs as). LIR-018 gains the
  return-to-owner rule.
- **Links into the user's sites** (LIR-032). Where the site on screen has tabs, a link that
  would open a nested screen opens as a tab of the site on screen, running as
  the user's site that can take it, whatever the routing switch says; inside
  a nested screen opened from a tab, the screen closes and the tab opens under
  that tab. The long-press "Open in new tab" row offers the same, as "as
  {site}". A routed nested screen from a hosted tab brings back the slot, not
  the host's own.
- **Site info** (NAV-011) names the site whose container it is, and adds "Tab
  of" for a hosted tab and "Opened from" for a nested screen that runs as
  another site.

Find, the URL bar and shared links are unchanged.

### Explicitly out of scope

- Searching from the URL bar.
- Searching shared text that carries no URL (LIR-005). The Android share
  handler and the iOS share extension drop such text before it reaches Dart,
  so it needs native changes on both.
- ChatGPT as a known host: its `?q=` address could not be checked on a device.
- Other ways into hosted tabs: "Open in new tab as {site}" (LIR-020), "Keep as
  tab" (LIR-021) and the reattach instruments (LIR-025 to LIR-027) stay
  specified and unbuilt in `inactive-tabs`.

## Capabilities

### Modified Capabilities

- `link-intent-routing`: adds LIR-028 (search sites), LIR-029 (web search from
  the page menu), LIR-030 (where results land), LIR-031 (search references
  follow their sites) and LIR-032 (a link into one of the user's sites opens
  as its tab). LIR-011 names a search as not an inbound share.
- `navigation`: NAV-011 (in `site-info-sheet`) names the site in the Container
  row and adds the Tab of and Opened from rows.
- `site-behaviour`: adds BEHAV-005 (the Search group).
- `inactive-tabs`: TAB-004 lists a web search among the ways to create a tab,
  TAB-005 opens it the way New tab does, as a child of the tab searched from,
  and TAB-006 enables "Open in new tab" for a link one of the user's sites can
  run.
