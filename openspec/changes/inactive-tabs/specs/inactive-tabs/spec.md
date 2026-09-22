## ADDED Requirements

### Requirement: TAB-001 - A site owns its tabs

Each site SHALL carry an ordered list of tabs. A tab has a path-safe `id`, a
`url` inside the site's own domain, a `title`, an optional `parentId` naming
the tab it was opened from (always a tab of the same site), `createdAt` and
`lastActiveAt`. Exactly one tab per site SHALL be active at any time;
`WebViewModel.currentUrl` and `pageTitle` SHALL resolve to the active tab's
fields. JSON without a `tabs` list SHALL synthesise one active root tab from
the legacy `currentUrl` (or `initUrl`), and serialisation SHALL omit `tabs`
while the list holds exactly that synthesised tab.

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

Every tab of a site SHALL share the site's container and per-site posture. A
site SHALL have at most one live webview, bound to its active tab. A parked
tab SHALL hold no controller, no renderer and no native object; it SHALL
consist of its `SiteTab` record and, when it has navigation state worth
keeping and `persistsNavState` is true, one file under
`webview_state/<siteId>/<tabId>.enc`. Tabs SHALL NOT change the number of live
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
order: capture the active tab's navigation state to `<siteId>/<activeTabId>`
when `persistsNavState` is true; park it; dispose the site's webview; queue
the target's saved bytes for `onControllerCreated` when they exist; rebuild
the webview. At no point SHALL two webviews exist for the site. Switching sites
SHALL NOT change any site's active tab.

#### Scenario: Switching tabs inside a site

- **GIVEN** GitHub's active tab T1 with history and parked tab T2 with saved state
- **WHEN** the user picks T2 in the Tabs sheet
- **THEN** T1's state is captured under `gh/T1` and T1 is parked
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
A tab SHALL be created only by "New tab" (TAB-005) and "Open in new tab"
(TAB-006). Home (NAV-004) SHALL act on the active tab: `initUrl` with history
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
reachable from the Tabs sheet header, the overflow menu, a long-press on the
active site's chip in the strip, and each site row in the drawer.

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
outside the site's domain the row SHALL be shown disabled with the reason, and
a tap on such a link SHALL keep opening the nested screen as today.

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
tab count and by tapping the active site's chip in the strip, SHALL offer "This
site" and "All sites" scopes, "New tab" and "Close N parked", and SHALL list
tabs as a tree in creation order, indented by depth, with a collapse chevron on
nodes that have children, the active tab highlighted, and close and
close-subtree actions. Each drawer site row SHALL expand to the same tree.
Strip chips and drawer tiles SHALL show a count pill when a site has more than
one tab. A locked kiosk shell (KIOSK-002) SHALL hide all of these.

#### Scenario: Count pill

- **GIVEN** GitHub has four tabs and Mastodon one
- **THEN** GitHub's chip shows "4" and Mastodon's shows no pill

#### Scenario: Collapse a subtree

- **GIVEN** tab A has three children
- **WHEN** the user taps A's chevron
- **THEN** the children are hidden and A's row notes "3 hidden"
- **AND** the tabs themselves are unchanged

---

### Requirement: TAB-009 - Tabs under per-site features

Tabs SHALL follow the owning site's feature posture: an incognito site's tabs
never reach disk and only a home tab survives relaunch (INC-002/003); an
Always open Home site reverts its active tab to `initUrl` in place on cold
start and shortcut tap and keeps parked tabs (AOH-001); an archive-tier site's
tabs ride the archive's encrypted state with no state bytes on disk, and
app-tier persistence is byte-identical whether or not archives hold tabs
(ARCH-001/006); the site QR share never carries tabs; settings backup carries
`tabs` but never state bytes; deleting a site removes `webview_state/<siteId>/`.

#### Scenario: Incognito relaunch

- **GIVEN** an incognito Wikipedia site with two parked tabs
- **WHEN** the app is killed and relaunched
- **THEN** Wikipedia has one tab, at `initUrl`
- **AND** no file exists under `webview_state/<siteId>/`

#### Scenario: Always open Home relaunch

- **GIVEN** a Mastodon site with Always open Home, active on a post, with one parked tab
- **WHEN** the app is cold-started
- **THEN** Mastodon's active tab shows `initUrl` with no history
- **AND** the parked tab is still listed
