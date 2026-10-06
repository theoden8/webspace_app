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
tab and activate its parent, unless the Tabs sheet jumped to it and Back goes
back where the jump came from (TAB-019). On a root tab at history start the gesture SHALL
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

---

### Requirement: TAB-015 - Drag to reorder and nest

A long press on a row of the Tabs sheet SHALL lift that tab with its whole
subtree, and a drop SHALL move them within the same site's tree through the
pure engine operation `TabLifecycleEngine.drop(tabs, tabId, drop)`:

- in the top quarter of another row, the tab SHALL become that row's sibling
  just before it;
- in the middle half, the tab SHALL become that row's last child;
- in the bottom quarter, the tab SHALL become the row's first child when the
  row's children are showing, and otherwise its sibling just after its whole
  subtree;
- past a site's last row, the tab SHALL become that site's last root.

While a drag is over a row the sheet SHALL show where the tab would land: a
line at the landing depth for a sibling or first child, an outline for a last
child. A drop on the dragged tab, inside its own subtree, or on another site's
row SHALL be refused and change nothing; moving a tab to another site is
LIR-025's. A drop into a collapsed row SHALL expand it so the moved tab stays
in view. Holding a drag near the list's top or bottom edge SHALL scroll it.

A move SHALL change only `parentId` and list positions, as LIR-026's
`reparent` does: no webview is rebuilt, and no host, URL, state key or active
tab changes. The new tree SHALL be persisted. A tap on a row SHALL still open
the tab.

#### Scenario: Nest a tab

- **GIVEN** GitHub tabs A, B and C, each a root
- **WHEN** the user long-presses C and drops it on the middle of A's row
- **THEN** C is A's child, listed under A and indented
- **AND** no webview is rebuilt and the tab on screen is unchanged

#### Scenario: Reorder siblings

- **GIVEN** GitHub tabs A, B and C, each a root
- **WHEN** the user drops C on the top edge of A's row
- **THEN** the order is C, A, B, all still roots

#### Scenario: A tab cannot land in its own subtree

- **GIVEN** GitHub tab A with child B
- **WHEN** the user drags A over B's row
- **THEN** no landing is shown and the drop changes nothing

### Requirement: TAB-016 - Drag a site heading to reorder sites

In the Tabs sheet's All sites view, a long press on a site's heading SHALL
lift the site, and a drop on another site's heading SHALL put the site in that
one's place: above it when dragged up, below it when dragged down, the rule the
drawer grid and the tab strip follow. The move SHALL be the same reorder those
make (`_reorderSite`), so all three show one order: a named webspace's
`siteIds` order, or the global site order in "All". It SHALL be offered only
where they offer it, and SHALL be refused while a tab is being opened,
created or closed.

While a drag is over a heading the sheet SHALL draw a line on the side the site
would land. Reordering "All" renumbers sites, so the host SHALL hand the sheet
its sites afresh, and every row SHALL then open, close and move tabs of the
site it shows. A site's tabs SHALL move with its heading, and no tab, webview
or active site SHALL change.

#### Scenario: Move a site up

- **GIVEN** the All sites view lists GitHub, Mastodon and Wikipedia
- **WHEN** the user long-presses Wikipedia's heading and drops it on GitHub's
- **THEN** the sites are listed Wikipedia, GitHub, Mastodon, each with its tabs
- **AND** the drawer and the tab strip show the same order

#### Scenario: The rows follow the new numbering

- **GIVEN** the "All" webspace, GitHub on screen, and Wikipedia moved above it
- **WHEN** the user taps one of GitHub's tabs
- **THEN** that tab of GitHub opens, not a tab of the site now in GitHub's old
  position

---

### Requirement: TAB-017 - A site's tabs in other sites' trees

The Tabs sheet's This site view SHALL be the list of the site the tab on
screen runs as: the slot's own site, or the site a hosted tab runs as
(LIR-018), unless that site has no tabs, when it is the slot's. Its header,
count and New tab SHALL be that site's.

After that site's own tree, the view SHALL list the trees of other sites
that hold the containers of the current branch: the sites that the tab on
screen, the tabs above it up to its root, and every tab opened below it run
as. A tab in another tree runs as another site when a link or a search opened
it there (LIR-030, LIR-032, LIR-034). It SHALL look in the tree of every site
with tabs, whether or not the current webspace shows that site; the All sites
view SHALL still head only the sites the webspace shows. Each other tree
SHALL come under a heading naming its site ("In GitHub"), marked with that
site's colour (TAB-018), ordered by the first container of the branch it
holds, from the root down, then in the order the drawer lists sites.

Each other tree SHALL show, at their depth in the whole tree, its tabs that
run as one of those containers with their subtrees whole, whatever their own
descendants run as, and the tabs above them; together these are its
branches. When the other trees hold more than five branches in all, only the
container of the tab on screen SHALL be followed. The rest of each tree SHALL
be folded into one line saying how many tabs it holds ("3 more GitHub tabs"),
which shows the whole tree when tapped. A branch whose containers no other
tree holds SHALL bring no such heading.

The tab on screen SHALL be highlighted wherever it is listed, so a list opened
on a tab of another site's tree is the same list, with the highlight moved.

Every row of another tree SHALL open on a tap, whatever site it runs as.
Those rows SHALL stay in the tree that holds them: a tap SHALL open that site
on the tab, switching to All first when the current webspace does not show it
(WEBSPACE-012), close and close-subtree SHALL close it there, collapsing it SHALL
collapse it there too, and they SHALL NOT be dragged from this view. Tab ids
repeat across sites, so what is collapsed SHALL be kept per site and tab.

#### Scenario: The same subtree in both sites

- **GIVEN** a `duckduckgo.com` link from GitHub opened as a tab running as DuckDuckGo, with a GitHub page opened below it
- **WHEN** the user opens the Tabs sheet on DuckDuckGo
- **THEN** after DuckDuckGo's own tabs, "In GitHub" lists GitHub's home tab, that tab under it, and the GitHub page below that
- **AND** GitHub's own tree in the All sites view lists the same three

#### Scenario: Every container on the branch

- **GIVEN** DuckDuckGo's tree holds a GitHub tab opened from its search tab, with a Hugging Face tab opened below that, and GitHub is on screen on that tab
- **WHEN** the user opens the Tabs sheet
- **THEN** after GitHub's own tabs it lists the other trees holding DuckDuckGo tabs, then those holding GitHub tabs, then those holding Hugging Face tabs

#### Scenario: Too many branches

- **GIVEN** the same branch, and other trees holding six branches of DuckDuckGo, GitHub and Hugging Face tabs between them
- **WHEN** the user opens the Tabs sheet
- **THEN** only the other trees holding GitHub tabs are listed, folded around those

#### Scenario: The rest of the other tree is folded

- **GIVEN** the sheet on DuckDuckGo, whose own tabs all run as DuckDuckGo, listing GitHub's tree, where GitHub also holds a pull request tab opened from its home tab
- **THEN** the pull request is not listed and "1 more GitHub tab" is
- **WHEN** the user taps that line
- **THEN** GitHub's whole tree is listed

#### Scenario: A tab run as its opener is not the other site's

- **GIVEN** GitHub's routing switch is off, and a `duckduckgo.com` link from GitHub opened as a tab running as GitHub
- **WHEN** the user opens the Tabs sheet on DuckDuckGo
- **THEN** that tab is not listed

#### Scenario: A tap opens the tree that holds the tab

- **GIVEN** the sheet on DuckDuckGo listing a tab "In GitHub"
- **WHEN** the user taps it
- **THEN** GitHub comes on screen on that tab, running as DuckDuckGo

#### Scenario: The other site's own tabs open too

- **GIVEN** the sheet on DuckDuckGo listing GitHub's tree, with GitHub's home tab above the tab that runs as DuckDuckGo
- **WHEN** the user taps GitHub's home tab
- **THEN** GitHub comes on screen on it, running as GitHub
- **AND** GitHub's Tabs sheet lists DuckDuckGo's tab as where the user was (TAB-019)

#### Scenario: The list follows the site the tab runs as

- **GIVEN** GitHub on screen on a tab running as DuckDuckGo
- **WHEN** the user opens the Tabs sheet
- **THEN** it is headed "DuckDuckGo" and lists DuckDuckGo's own tabs first, then "In GitHub" with that tab highlighted
- **AND** New tab opens a tab of DuckDuckGo

#### Scenario: The other site is in another webspace

- **GIVEN** a `duckduckgo.com` link from GitHub opened as a tab running as DuckDuckGo, and a webspace "Search" holding DuckDuckGo but not GitHub
- **WHEN** the user opens the Tabs sheet on DuckDuckGo in "Search"
- **THEN** "In GitHub" lists that tab
- **AND** the sheet offers no All sites view, since "Search" shows one site with tabs
- **AND** a tap on the tab switches to All and brings GitHub on screen on it

---

### Requirement: TAB-018 - Container colours

Each site SHALL have a container colour, and every tab row SHALL begin with a
mark in the colour of the site the tab runs as, whichever tree holds it. A
site has one container and one posture (LIR-018), so the mark names both: the
sign-in the tab has and the settings it loads with. The All sites view SHALL mark each site's heading with
its own colour, and site info SHALL show the colour beside the container it
names (NAV-011), on the container engine only. The mark SHALL be decorative:
the row names the site it runs as in words ("as {site}") whenever that is not
the site whose tree holds it, or the tab runs outside that site's domain
(LIR-034), so colour is never the only signal.

The palette SHALL hold the same hues for light and dark themes, each reading
at 3:1 against the surfaces of its brightness and distinct from the others. A
site SHALL be given a colour the first time it is loaded or saved without one,
the least used among the user's sites, lowest first on a tie, and SHALL keep it:
adding, removing or reordering sites changes no other site's colour. The
colour SHALL be stored with the site and carried by a backup, never by a QR
share: a scanned site is a new container and gets a colour of its own.

A site that comes back with a colour chosen elsewhere SHALL keep it unless
another site already holds it while some colour is still free; then it SHALL
be given the least used one. Two cases bring one back: a backup restore, where
the sites before it in the backup hold their colours (a duplicate the import
re-mints, or a hand-edited backup, would otherwise share one), and a site moved
out of an archive, where the app-tier sites hold theirs. Once every colour is
held, a site keeps its own, since a new one would be shared too.

Only app-tier sites SHALL be counted or given a colour, so nothing the app tier
stores depends on an archive (ARCH-001). A site moved into an archive SHALL keep
its colour inside the archive's own state, so it comes back with it; a site
created inside an archive has none and SHALL draw a colour derived from its id
while its archive is open.

#### Scenario: Two containers, one page

- **GIVEN** two tabs at the same `github.com` page, one running as Work GitHub and one as Personal GitHub
- **THEN** their rows carry different marks, and each names the site it runs as

#### Scenario: A flip changes the mark

- **GIVEN** a link tab running as GitHub, marked in GitHub's colour (LIR-034)
- **WHEN** its opener's routing switch is turned off
- **THEN** its row is marked in the opener's colour and says it runs as the opener

#### Scenario: A restored backup does not share colours

- **GIVEN** a backup in which two sites are both stored as blue, and a third as green
- **WHEN** it is imported
- **THEN** the first keeps blue, the third keeps green, and the second gets the least used colour

#### Scenario: A site back from an archive keeps its colour unless taken

- **GIVEN** a red site moved into an archive, and a new app-tier site given red meanwhile
- **WHEN** the archived site is moved out
- **THEN** it gets the least used colour, and the new site stays red
- **AND** had nobody taken red, it would have come back red

#### Scenario: A new site does not repaint the others

- **GIVEN** five sites with their colours
- **WHEN** the user adds a sixth and deletes the second
- **THEN** the sixth gets the least used colour and the other four keep theirs

---

### Requirement: TAB-019 - The way back from a jump

A tap in the Tabs sheet that brings another site's slot on screen is a jump,
and the system SHALL remember where it came from: the site and tab on screen
before, and the webspace selected. Jumps SHALL chain, so a jump from where
another landed adds to the trail, at most twenty kept.

While the screen is where the last jump landed, on the tab it opened:

- The tab the jump came from SHALL be listed in the This site view, with its
  tree if no other rule lists it (TAB-017), and marked "where you were".
- Back at the start of the tab's history SHALL go back where the jump came
  from instead of closing the tab (TAB-007), and so SHALL a tap on the marked
  tab. Going back SHALL take that jump off the trail and put back the webspace
  it left, when that webspace shows the site; neither tab SHALL close.

Leaving that tab any other way SHALL drop the trail: another site from the
drawer, the tab strip, a shortcut or a link, another tab of the same site, or
a jump from somewhere else, which starts a new trail. The trail SHALL NOT be
stored.

#### Scenario: Back goes back

- **GIVEN** DuckDuckGo on screen in a webspace "Search", and its Tabs sheet listing a tab "In GitHub"
- **WHEN** the user taps that tab, then presses Back at the start of its history
- **THEN** DuckDuckGo is on screen on the tab it was on, in "Search"
- **AND** the GitHub tab is still listed

#### Scenario: The list leads back

- **GIVEN** the user jumped from DuckDuckGo's Tabs sheet to a tab in GitHub's tree
- **WHEN** they open the Tabs sheet again
- **THEN** DuckDuckGo's tab they came from says "where you were"
- **WHEN** they tap it
- **THEN** DuckDuckGo is on screen on it, and no tab says "where you were"

#### Scenario: Another way out drops the trail

- **GIVEN** the user jumped from DuckDuckGo's Tabs sheet to a child tab in GitHub's tree
- **WHEN** they go to another site from the drawer, come back to GitHub on that tab, and press Back at the start of its history
- **THEN** the tab closes as TAB-007 says
