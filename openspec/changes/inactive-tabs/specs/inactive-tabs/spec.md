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
a share arrival SHALL resume the site's active tab and SHALL NOT create a tab.
A tab SHALL be created only by "New tab" (TAB-005), "Open in new tab"
(TAB-006) and "Duplicate tab" (TAB-010). Home (NAV-004) SHALL act on the active tab: `initUrl` with history
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
an empty history, and park the previous active tab per TAB-003. It SHALL be
reachable from the Tabs sheet header and from the overflow menu, meaning both
of them: the app bar's, and the bottom bar's when the tab strip is shown. A
long press on a strip chip is not an entry point: it already starts the drag
that reorders sites.

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
outside the site's domain the row SHALL be shown disabled with the reason
unless LIR-020 offers "Open in new tab as {site}" rows for it, and a tap on
such a link SHALL keep opening the nested screen as today.

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

Tabs SHALL follow the owning site's feature posture. The flag that drops a
site's `currentUrl` from serialisation SHALL drop its tab list with it, for the
same reason: a site whose one navigation URL is not allowed on disk must not
put five of them there instead. So an incognito site's tabs never reach disk
and it relaunches with one tab at `initUrl` (INC-002/003), and an Always open
Home site does the same rather than keeping parked tabs — a deliberate
narrowing of what that toggle preserves, taken because the alternative writes
the deep URLs of a banking-style site into plaintext preferences (AOH-001). An
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

- **GIVEN** a Mastodon site with Always open Home, active on a post, with one parked tab
- **WHEN** the app is cold-started
- **THEN** Mastodon has one tab, showing `initUrl` with no history
- **AND** neither the post nor the parked tab's URL appears in the persisted JSON

---

### Requirement: TAB-010 - Duplicate tab

"Duplicate tab" SHALL copy the site's active tab into a new tab placed directly
after it and its subtree, with the same `url`, `title` and `parentId`, so the
copy is the source's next sibling. When the site persists navigation state,
the copy SHALL receive the source's back/forward state under its own key: the
live webview's capture when the site is loaded, else the source's saved bytes.
The copy SHALL open parked, as "Open in new tab" does (TAB-006): the page on
screen stays, no webview is built or disposed, and a snackbar offers "Switch".
It SHALL be reachable from both overflow menus and from a long press on either
refresh button.

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
the overflow menus SHALL offer neither "New tab" nor "Duplicate tab", a long
press on a refresh button SHALL do nothing, a long press on a link SHALL open no
link menu, system back at the start of a page SHALL keep NAV-001 even in a tab
opened from another, and no chip or tile SHALL show a count pill. Every way into
tabs SHALL return before acting, not only hide its button.

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
