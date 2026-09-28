## ADDED Requirements

### Requirement: TAB-001 - A site owns its tabs

Each site SHALL carry an ordered list of tabs. A tab has a path-safe `id`, a
`url` inside the site's own domain (a hosted tab's is inside its host's,
LIR-018), a `title`, an optional `parentId` naming
the tab it was opened from (always a tab of the same site), `createdAt` and
`lastActiveAt`. Exactly one tab per site SHALL be active at any time;
`WebViewModel.currentUrl` and `pageTitle` SHALL resolve to the active tab's
fields. JSON without a `tabs` list SHALL synthesise one active root tab from
the legacy `currentUrl` (or `initUrl`), and serialisation SHALL omit `tabs`
while the list holds exactly that synthesised tab. The active tab SHALL be
marked inside the list (`"active": true` on its entry) rather than in a key
beside it, and a list that is present SHALL be authoritative over the
site-level `currentUrl` and `pageTitle`, which are written only for builds that
predate tabs. So one field of the wrong type drops that field alone
(BACKUP-014): an odd `pageTitle` does not retitle a tab, and an odd `tabs`
leaves the site on one tab at its `currentUrl`.

#### Scenario: Legacy site migrates to one tab

- **GIVEN** a `WebViewModel` JSON with `currentUrl: "https://github.com/notifications"` and no `tabs`
- **WHEN** it is deserialised
- **THEN** the site has one root tab whose `url` is `https://github.com/notifications`
- **AND** that tab is active
- **AND** serialising the site again omits `tabs`

#### Scenario: Two tabs persist

- **GIVEN** a site with an active tab and one parked tab
- **WHEN** the app is restarted
- **THEN** both tabs are restored with their urls, titles and parent links
- **AND** the same tab is active

---

### Requirement: TAB-002 - One container and one webview per site

Every tab of a site SHALL share the site's container and per-site posture,
except a hosted tab, which runs as its host (LIR-018). A
site SHALL have at most one live webview, bound to its active tab. A parked
tab SHALL hold no controller, no renderer and no native object; it SHALL
consist of its `SiteTab` record and, when it has navigation state worth
keeping and `persistsNavState` is true, one file
`webview_state/<siteId>.<tabId>.enc`. Tabs SHALL NOT change the number of live
webviews, and `SiteUnloadEngine` and `SiteLifecyclePromotionEngine` SHALL keep
the site as their unit.

#### Scenario: Memory pressure with many tabs

- **GIVEN** GitHub has one active tab and six parked tabs, and Mastodon's webview is the least recently used
- **WHEN** the OS signals memory pressure
- **THEN** Mastodon's webview is disposed after capturing its active tab's bytes
- **AND** GitHub's seven tabs are untouched
- **AND** the number of live webviews drops by exactly one

#### Scenario: Parked tab costs nothing in memory

- **GIVEN** a site with twenty parked tabs
- **WHEN** the site's webview is evicted
- **THEN** exactly one capture runs (the active tab's)
- **AND** no parked tab is read, written or touched

---

### Requirement: TAB-003 - A tab switch is capture, dispose, rebuild, restore

Activating a parked tab while another tab of the same site is active SHALL, in
order: capture the active tab's navigation state to `<siteId>.<activeTabId>`
when `persistsNavState` is true; park it; dispose the site's webview; queue
the target's saved bytes for `onControllerCreated` when they exist; rebuild
the webview. At no point SHALL two webviews exist for the site. Switching sites
SHALL NOT change any site's active tab.

#### Scenario: Switching tabs inside a site

- **GIVEN** GitHub's active tab T1 with history and parked tab T2 with saved state
- **WHEN** the user picks T2 in the Tabs sheet
- **THEN** T1's state is captured under `gh.T1` and T1 is parked
- **AND** GitHub's webview is disposed and rebuilt with T2's bytes queued
- **AND** the rebuilt webview restores T2's back stack
- **AND** the number of live webviews is unchanged before and after

#### Scenario: Switching sites leaves tabs alone

- **GIVEN** GitHub is active on tab T2 and Mastodon's active tab is M1
- **WHEN** the user taps Mastodon in the strip
- **THEN** GitHub's active tab remains T2 and its webview is not disposed
- **AND** Mastodon's webview shows M1 exactly as it did

---

### Requirement: TAB-004 - Opening a site never creates a tab

Tapping a site in the strip or drawer, a cold start, a home-shortcut tap and
a share arrival SHALL resume the site's active tab and SHALL NOT create a tab,
except that a cold start or a home-shortcut tap lands a site with Always open
Home on a tab at home (TAB-014). A tab SHALL be created only by "New tab"
(TAB-005), "Open in new tab" (TAB-006), "Duplicate tab" (TAB-010), a web search
(LIR-030) and that landing. Home (NAV-004) SHALL act on the active tab: `initUrl` with history
cleared, no new tab.

#### Scenario: Reopening a site resumes

- **GIVEN** GitHub's active tab is a pull request and the user is on Mastodon
- **WHEN** the user taps GitHub in the strip
- **THEN** the pull request is shown
- **AND** GitHub's tab count is unchanged

#### Scenario: Home stays in the tab

- **GIVEN** GitHub's active tab is three pages deep
- **WHEN** the user presses Home
- **THEN** the same tab shows `initUrl` with no back history
- **AND** GitHub's tab count is unchanged

---

### Requirement: TAB-005 - New tab

"New tab" SHALL create a root tab at the site's `initUrl`, make it active with
an empty history, and park the previous active tab per TAB-003. A web search
(LIR-030) SHALL open its tab the same way at the search URL: as a child of the
tab searched from when it lands in the same site's tree, including as a hosted
tab (LIR-018), or as a root tab of the search site when it falls back to it.
"New tab" SHALL be reachable from the Tabs sheet header and from the overflow
menu, meaning both of them: the app bar's, and the bottom bar's when the tab
strip is shown. A long press on a strip chip is not an entry point: it already
starts the drag that reorders sites.

#### Scenario: New tab from a deep page

- **GIVEN** GitHub's active tab is a pull request
- **WHEN** the user presses "New tab" in the Tabs sheet
- **THEN** a new root tab at `https://github.com/` is active
- **AND** the pull request tab is parked with its state captured
- **AND** switching back to it restores its history

---

### Requirement: TAB-006 - Open in new tab

A long-press on a link whose URL is inside the site's domain SHALL offer "Open
in new tab", which creates a parked child tab (`parentId` = the current tab)
without navigating, and shows a snackbar offering "Switch". No webview and no
state bytes SHALL exist for the child until it is first activated. For a link
outside the site's domain that one of the user's sites can run as a tab
(LIR-032), the row SHALL be enabled, name that site ("as {site}"), and create
the parked child running as it; when several can, it SHALL ask with the
LIR-016 picker first. For any other link outside the domain the row SHALL be
shown disabled with the reason, and a tap on such a link SHALL keep opening the
nested screen as today.

The menu's "Open" row SHALL route the link exactly as a tap on it would: in
place when it is inside the site's domain, otherwise in the nested screen, or
the system browser when `externalLinksInBrowser` applies and no domain claim
covers it. Choosing "Open" is a user gesture, so a site with outbound routing
on (LIR-013) SHALL route it first, as it routes a tap (LIR-014). It SHALL NOT load a cross-domain URL into the site's own webview:
Android does not run `shouldOverrideUrlLoading` for a programmatic `loadUrl`,
so a bare load there would put the foreign page inside the site's container.

The long press is delivered by the plugin's `onLongPressHitTestResult`
(`View.setOnLongClickListener` on Android, `UILongPressGestureRecognizer` on
iOS) filtered to `SRC_ANCHOR_TYPE` / `SRC_IMAGE_ANCHOR_TYPE` and to http(s)
targets. The plugin exposes no macOS or Linux equivalent, so on those platforms
a tab is created from the tab list's "New tab" instead; this is a platform
reach gap, not a behaviour difference in the model. The nested screen passes no
handler: it has no tab list of its own to add to.

#### Scenario: Open in new tab

- **GIVEN** the user is on GitHub's pull request list
- **WHEN** they long-press "#601" and choose "Open in new tab"
- **THEN** a parked child tab for #601 appears under the pull request list
- **AND** the pull request list stays on screen
- **AND** no capture, dispose or rebuild runs

#### Scenario: Cross-domain link is not a tab

- **GIVEN** a GitHub page links to `wpewebkit.org`
- **WHEN** the user long-presses that link
- **THEN** "Open in new tab" is disabled and explains the link is outside GitHub's domain
- **AND** tapping the link opens the nested screen

#### Scenario: Open from the menu routes like a tap

- **GIVEN** a GitHub page links to `wpewebkit.org` and GitHub does not send external links to the browser
- **WHEN** the user long-presses that link and chooses "Open"
- **THEN** `wpewebkit.org` opens in the nested screen
- **AND** GitHub's webview stays on the page it was showing

#### Scenario: Open from the menu is routed like a tap

- **GIVEN** a DuckDuckGo site with outbound routing on, and a GitHub site that is the single match for `github.com`
- **WHEN** the user long-presses a `github.com` result and chooses "Open"
- **THEN** the link opens nested with the GitHub site's posture, as a tap on it would (LIR-015)

---

### Requirement: TAB-007 - Back at the start of a child tab

The system back gesture at the start of a child tab's history SHALL close the
tab and activate its parent. On a root tab at history start the gesture SHALL
remain a no-op (NAV-001). Closing a tab SHALL re-parent its children to its
parent.

#### Scenario: Backing out of a child tab

- **GIVEN** T3 was opened in a new tab from T2 and is active with no history of its own
- **WHEN** the user presses system back
- **THEN** T3 is closed and its state file removed
- **AND** T2 is active again

#### Scenario: Closing a parent keeps its children

- **GIVEN** tabs A -> B -> C (each opened from the previous)
- **WHEN** the user closes B
- **THEN** C's parent becomes A
- **AND** C is still listed

---

### Requirement: TAB-008 - The tree

The Tabs sheet SHALL be reachable from the app bar square showing the site's
tab count and by tapping the active site's chip in the strip, SHALL offer "New
tab", and SHALL list tabs as a tree in creation order,
indented by depth, with a collapse chevron on nodes that have children, each
tab's load state shown per TAB-011, and close and close-subtree actions. Collapsing a
tab SHALL hide its whole subtree and SHALL say how many tabs that is.

Where more than one site is shown, the sheet SHALL also offer an "All sites"
scope listing every site's tree under its own heading. That scope is the
whole-app tab view; the drawer, which lays sites out as a grid of tiles rather
than a list of rows, SHALL carry only the count. Strip chips and drawer tiles
SHALL show a count pill when a site has more than one tab, and nothing when it
has one, so a user who never opens a second tab sees no new chrome. A locked
kiosk shell (KIOSK-002) SHALL hide all of these.

#### Scenario: Count pill

- **GIVEN** GitHub has four tabs and Mastodon one
- **THEN** GitHub's chip shows "4" and Mastodon's shows no pill

#### Scenario: Collapse a subtree

- **GIVEN** tab A has one child, which itself has one child
- **WHEN** the user taps A's chevron
- **THEN** both descendants are hidden, not just the direct child
- **AND** A's row says two tabs are hidden
- **AND** the tabs themselves are unchanged

#### Scenario: One loaded tab per loaded site

- **GIVEN** two loaded sites, each with tabs, and the sheet in its "All sites" scope
- **THEN** exactly one row per site is drawn at full strength, its active tab
- **AND** every other row is faded as stored (TAB-011)

---

### Requirement: TAB-009 - Tabs under per-site features

Tabs SHALL follow the owning site's feature posture. Incognito drops a site's
tab list from serialisation with its `currentUrl`: nothing it visited may reach
disk, so it relaunches with one tab at `initUrl` (INC-002/003). Always open
Home drops `currentUrl` but keeps the tab list, so the site lands on a tab at
home without closing the others (TAB-014); its tab URLs reach plaintext
preferences as any other site's do. An
archive-tier site's
tabs ride the archive's encrypted state with no state bytes on disk, and
app-tier persistence is byte-identical whether or not archives hold tabs
(ARCH-001/006); the site QR share never carries tabs; settings backup carries
`tabs` but never state bytes; deleting a site removes every
`webview_state/<siteId>.*.enc`.

#### Scenario: Incognito relaunch

- **GIVEN** an incognito Wikipedia site with two parked tabs
- **WHEN** the app is killed and relaunched
- **THEN** Wikipedia has one tab, at `initUrl`
- **AND** no `webview_state/<siteId>.*.enc` file exists

#### Scenario: Always open Home relaunch

- **GIVEN** a Mastodon site with Always open Home and tabs, active on a post, with one parked tab
- **WHEN** the app is cold-started
- **THEN** Mastodon shows a new tab at `initUrl` with no history
- **AND** the post and the parked tab are still listed
- **AND** the persisted JSON carries the tab list but no site-level `currentUrl`

---

### Requirement: TAB-010 - Duplicate tab

"Duplicate tab" SHALL copy the site's active tab into a new tab placed directly
after it and its subtree, with the same `url`, `title` and `parentId`, so the
copy is the source's next sibling. When the site persists navigation state,
the copy SHALL receive the source's back/forward state under its own key: the
live webview's capture when the site is loaded, else the source's saved bytes.
The copy SHALL open parked, as "Open in new tab" does (TAB-006): the page on
screen stays, no webview is built or disposed, and a snackbar offers "Switch".
It SHALL be reachable from a long press on either refresh button; neither
overflow menu SHALL offer it.

#### Scenario: Branching off a page

- **GIVEN** GitHub's active tab is three pages into a pull request
- **WHEN** the user long-presses refresh
- **THEN** a parked tab for the same page appears right after it in the tree
- **AND** the pull request stays on screen with no reload
- **AND** opening the copy restores the same three-page history, after which the two tabs navigate independently

#### Scenario: Incognito copy has no history

- **GIVEN** an incognito site
- **WHEN** the user duplicates its tab
- **THEN** the copy has the same URL and no state file is written

---

### Requirement: TAB-011 - Tab load state follows the site load policy

Whether a tab is loaded SHALL be decided by the existing site load policy
(lazy loading, the `kMaxLoadedSites` LRU cap, the memory-pressure cascade of
`SiteLifecyclePromotionEngine`, retention priorities), with the site as its
unit per TAB-002: a tab is loaded exactly when it is the active tab of a site
that holds a webview. No rule specific to tabs SHALL load or unload anything.
The tab list SHALL show that state on every row by strength alone, as a browser
fades an unloaded tab: a loaded tab at full strength, whether its site is on
screen or backgrounded (its webview resident but paused), and every other tab
faded, since opening it reloads its page. The tab on screen SHALL also carry the
selected-row highlight. No text label SHALL be drawn for the state; a screen
reader SHALL be told it in words instead. A tab switch on a loaded site SHALL return the
site to the `resident` tier, because the rebuilt webview is fresh.

#### Scenario: The policy unloads, the list shows it

- **GIVEN** Mastodon is loaded in the background and its active tab is drawn at full strength
- **WHEN** memory pressure disposes Mastodon's webview
- **THEN** the next time the tab list opens, every Mastodon tab is faded
- **AND** no tab of any other site changes state

#### Scenario: A switch resets the tier

- **GIVEN** GitHub is on screen at the `cacheCleared` tier
- **WHEN** the user switches to another of its tabs
- **THEN** GitHub is at the `resident` tier with one webview

---

### Requirement: TAB-012 - Tabs are experimental

Tabs SHALL be reachable only while developer mode is on and the Experimental
group's **Site tabs** switch is on (DEVTOOLS-011); the switch SHALL default off.
The gate SHALL be read when it is used, so flipping the switch or developer mode
takes effect without a restart.

While tabs are off, a site SHALL behave as it did before tabs existed: the app
bar SHALL show no tab count, a tap on the active site's chip SHALL do nothing,
the overflow menus SHALL NOT offer "New tab", a long press on a refresh button
SHALL do nothing, a long press on a link SHALL open no link menu, system back at
the start of a page SHALL keep NAV-001 even in a tab opened from another, and no
chip or tile SHALL show a count pill. Every way into tabs SHALL return before
acting, not only hide its button.

Turning tabs off SHALL NOT delete or rewrite a site's tabs. The site keeps
showing its active tab, its other tabs stay stored under TAB-009's rules, and
turning tabs back on shows them again.

#### Scenario: Off by default

- **GIVEN** a fresh install with developer mode on
- **WHEN** the user opens a site
- **THEN** there is no tab count in the app bar and no "New tab" in the menu
- **AND** App settings lists "Site tabs" in the Experimental group, switched off

#### Scenario: The switch applies without a restart

- **GIVEN** developer mode is on and Site tabs is off
- **WHEN** the user turns Site tabs on and returns to a site
- **THEN** the tab count and the tab rows of the menu are there

#### Scenario: Turning tabs off keeps them

- **GIVEN** GitHub has four tabs and its third is active
- **WHEN** the user turns developer mode off
- **THEN** GitHub shows its third tab with no tab count or count pill
- **AND** after developer mode is back on, all four tabs are listed again

---

### Requirement: TAB-013 - A kiosk site has no tabs

Kiosk mode makes a site an app: one page, handed to someone through its
shortcut. Tabs make it a browser. A site SHALL be one or the other. Full screen
mode only hides the shell and SHALL NOT turn tabs off.

Each site SHALL carry a `tabsEnabled` choice, on by default, written to the
site's JSON only when off, and carried by settings backup and the site QR share
like `kioskMode`. Tabs SHALL be in effect for a site only while TAB-012's gate
is open, its `tabsEnabled` is on, and its `kioskMode` is off
(`effectiveTabsEnabled`). While they are not in effect for a site, that site
SHALL behave as TAB-012 describes for tabs off, every way into its tabs SHALL
return before acting, and the tab list's "All sites" scope SHALL leave the site
out. Other sites are unaffected.

The Behaviour screen (BEHAV-005) SHALL show the effective value. Turning Tabs
on SHALL turn Kiosk mode off. Turning Kiosk mode on SHALL show Tabs off without
changing the stored `tabsEnabled`, so turning it back off restores tabs.
Turning Tabs off SHALL leave Kiosk mode as it is. No way of turning a site's
tabs off SHALL delete or rewrite them (TAB-012).

#### Scenario: A new site has tabs

- **GIVEN** developer mode and the Site tabs switch are on
- **WHEN** the user adds a site
- **THEN** its Tabs switch is on and the app bar shows its tab count

#### Scenario: A kiosk site has no tabs

- **GIVEN** developer mode and the Site tabs switch are on
- **AND** GitHub has three tabs and Kiosk mode on, and Mastodon has two tabs
- **WHEN** WebSpace is opened normally and GitHub is shown
- **THEN** GitHub shows no tab count, no "New tab", no count pill, and a long press on a link opens no menu
- **AND** Mastodon's "All sites" tab list does not list GitHub
- **AND** Mastodon's tabs work as before

#### Scenario: Turning tabs on turns kiosk off

- **GIVEN** a site with Kiosk mode and Full screen mode on
- **WHEN** the user turns Tabs on in its Behaviour screen
- **THEN** Kiosk mode is off and Full screen mode is still on

#### Scenario: Leaving kiosk mode gives tabs back

- **GIVEN** a site with four tabs, Tabs on, and Kiosk mode turned on
- **WHEN** the user turns Kiosk mode off
- **THEN** Tabs reads on and all four tabs are listed again

#### Scenario: A full-screen site keeps its tabs

- **GIVEN** developer mode and the Site tabs switch are on
- **AND** a site with two tabs and Full screen mode on
- **THEN** its Tabs switch reads on and its tabs are listed

---

### Requirement: TAB-014 - Where a site with tabs lands

A cold start and a home-shortcut tap, warm or cold, are fresh entries to a
site. For a site whose tabs are in effect (TAB-013), Always open Home SHALL
decide where it lands:

- **Off**: on the tab it was on, with that tab's history. A cold shortcut
  launch SHALL NOT send it home as HS-006 does for a site without tabs.
- **On** (incognito implies it, AOH-005): on a tab at home. When the active tab
  is at `initUrl` the site SHALL stay on it and SHALL NOT open a tab. Otherwise
  it SHALL switch to the most recently used parked tab at `initUrl`, or when
  there is none open a new root tab there. The tab it was on SHALL be parked
  with its state, as for "New tab" (TAB-005), never closed or sent home.

A URL is at `initUrl` when it differs only by an http to https upgrade, host
case, a trailing slash or a fragment. The same rule SHALL apply to every flagged
site AOH-004 resets on a shortcut tap, and an offscreen site landed this way
SHALL NOT change whether the app is in full screen. A cold start lands an Always
open Home site when it is loaded, before any webview exists (AOH-002). A site
whose tabs are not in effect keeps HS-006 and AOH-001 to AOH-004 as written:
its active tab is sent home in place.

#### Scenario: A shortcut resumes the last tab

- **GIVEN** a GitHub site with tabs and Always open Home off, last on a pull request
- **WHEN** the app is cold-launched from GitHub's shortcut
- **THEN** GitHub shows the pull request with its history
- **AND** no tab is created

#### Scenario: Always open Home opens a tab at home

- **GIVEN** a bank site with tabs and Always open Home on, last on an account page
- **WHEN** the user taps its shortcut while the app is running
- **THEN** the bank shows a new tab at `initUrl`
- **AND** the account page is still listed as a parked tab with its history

#### Scenario: Already home

- **GIVEN** a bank site with tabs and Always open Home on, whose active tab is at `https://bank.example` and whose `initUrl` is `https://bank.example/`
- **WHEN** the app is cold-started
- **THEN** the bank stays on that tab and its tab count is unchanged

#### Scenario: A home tab is reused

- **GIVEN** a bank site with Always open Home on, active on an account page, with a parked tab at `initUrl`
- **WHEN** the user taps its shortcut
- **THEN** the parked home tab becomes active and no tab is created

