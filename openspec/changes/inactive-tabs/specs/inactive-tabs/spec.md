## ADDED Requirements

### Requirement: TAB-001 - A site owns its pages

Each site SHALL carry an ordered list of pages. A page has a path-safe `id`, a
`url`, a `title`, an optional `parentId` naming the page it was opened from
(always a page of the same site), `createdAt`, `lastActiveAt` and `pinned`.
Exactly one page per site SHALL be active at any time; `WebViewModel.currentUrl`
and `pageTitle` SHALL resolve to the active page's fields. JSON without a
`pages` list SHALL synthesise one active root page from the legacy
`currentUrl` (or `initUrl`), and serialisation SHALL omit `pages` while the list
holds exactly that synthesised page.

#### Scenario: Legacy site migrates to one page

- **GIVEN** a `WebViewModel` JSON with `currentUrl: "https://github.com/notifications"` and no `pages`
- **WHEN** it is deserialised
- **THEN** the site has one root page whose `url` is `https://github.com/notifications`
- **AND** that page is active
- **AND** serialising the site again omits `pages`

#### Scenario: Two pages persist

- **GIVEN** a site with an active page and one parked page
- **WHEN** the app is restarted
- **THEN** both pages are restored with their urls, titles, parent links and pin state
- **AND** the same page is active

---

### Requirement: TAB-002 - One resident webview per site; parked pages are state

A site SHALL have at most one live webview, bound to its active page. A parked
page SHALL hold no controller. Activating a parked page while another page is
active SHALL capture the active page's navigation state to
`WebViewStateStorage` under `<siteId>/<pageId>` (subject to
`persistsNavState`), then bind the target page to the site's webview via
`restoreState` when bytes exist and `loadUrl` otherwise. Switching sites SHALL
NOT change any site's active page.

#### Scenario: Switching pages inside a site

- **GIVEN** GitHub's active page P1 and parked page P2 with saved state
- **WHEN** the user picks P2 in the Pages sheet
- **THEN** P1's state is captured under `gh/P1` and P1 is parked
- **AND** P2 becomes active and its saved state is restored into GitHub's webview
- **AND** no second webview is created

#### Scenario: Switching sites leaves pages alone

- **GIVEN** GitHub is active on page P2 and Mastodon's active page is M1
- **WHEN** the user taps Mastodon in the tab strip
- **THEN** GitHub's active page remains P2
- **AND** Mastodon's webview shows M1 exactly as it did

---

### Requirement: TAB-003 - Sideways exits park, backwards exits close

A page the user leaves by switching to another page or site, by opening a link
in the background, by a share arrival, or by backgrounding the app SHALL be
parked. The system back gesture at the start of a child page's history (a page
with a `parentId`, or one opened from another site's page) SHALL close the page
and activate its parent (or return to the origin site's page). On a root page at
history start the gesture SHALL remain a no-op (NAV-001). Closing a page SHALL
re-parent its children to its parent.

#### Scenario: Backing out of a hop closes it

- **GIVEN** the user tapped "Why Pocket failed" on Hacker News, which opened as a child page
- **WHEN** they press system back with no history inside the child
- **THEN** the child page is closed
- **AND** the Hacker News page that opened it is active again
- **AND** the Pages sheet does not list the closed page

#### Scenario: Switching away from a hop keeps it

- **GIVEN** the same child page is open
- **WHEN** the user opens the Pages sheet and picks the Hacker News home page
- **THEN** the child page is parked and listed under its parent
- **AND** picking it later restores it

#### Scenario: Closing a parent keeps its children

- **GIVEN** pages A -> B -> C (each opened from the previous)
- **WHEN** the user closes B
- **THEN** C's parent becomes A
- **AND** C is still listed

---

### Requirement: TAB-004 - Four ways a page accumulates

The system SHALL create a parked page from: (1) a long-press on a link and
"Open in new page", as a child of the current page; (2) "Park this page" from
the overflow menu, after which the parent, or a new home page, takes the
webview; (3) an inbound share that resolves to a single site, added to that
site's list with a snackbar offering to open it, without touching that site's
webview; (4) a child page kept by a sideways exit (TAB-003). "New page at home"
SHALL park the current page and activate a fresh root page at the site's
`initUrl`.

#### Scenario: Open in new page

- **GIVEN** the user is on GitHub's pull request list
- **WHEN** they long-press "#601" and choose "Open in new page"
- **THEN** a parked child page for #601 appears under the pull request list
- **AND** the pull request list stays on screen

#### Scenario: Share lands in the list

- **GIVEN** a GitHub site whose active page is a pull request
- **WHEN** `https://github.com/theoden8/webspace_app/issues/612` arrives via the share sheet
- **THEN** a parked root page for the issue is added to GitHub
- **AND** the pull request stays on screen
- **AND** a snackbar "Added to GitHub" offers "Open"

---

### Requirement: TAB-005 - Cross-site link picker

When a gesture cross-domain tap would open a nested page (`blockOpenNested`) and
`LinkRoutingService.resolve` returns a single site other than the current one,
the system SHALL offer: open in that site (switching sites; back returns to the
page that opened it), add to that site (parked), or open here in the current
site's container (today's nested behaviour). Gesture-less navigations
(`blockSilent`, `blockSuppressed`) SHALL never reach the picker. A page opened in
another site SHALL be a root page there carrying an `origin` reference, never a
child across sites.

#### Scenario: GitHub link on Mastodon

- **GIVEN** a Mastodon post links to a GitHub pull request and a GitHub site exists
- **WHEN** the user taps the link
- **THEN** the picker offers "Open in GitHub", "Add to GitHub", "Open here"
- **AND** choosing "Open in GitHub" activates a new GitHub root page on the PR with GitHub's container
- **AND** system back at that page's history start returns to the Mastodon post

---

### Requirement: TAB-006 - Pages sheet and drawer tree

The Pages sheet SHALL be reachable from the app bar and by tapping the active
site's chip in the tab strip, SHALL offer "This site" and "All sites" scopes,
and SHALL list pages as a tree (indented by depth) with title, host, age, pin
and close. Tab-strip chips and drawer tiles SHALL show a count pill when a site
has more than one page. Each drawer site row SHALL expand to the same tree. A
locked kiosk shell (KIOSK-002) SHALL hide all of these.

#### Scenario: Count pill

- **GIVEN** GitHub has four pages and Mastodon one
- **THEN** GitHub's chip shows "4" and Mastodon's shows no pill

---

### Requirement: TAB-007 - Keep limit

A per-site `keepParkedPages` setting on the Behaviour screen SHALL be one of
never (default), one day, one week, one month. On launch and on foreground
resume the system SHALL close parked, unpinned pages whose `lastActiveAt` is
older than the limit. Active and pinned pages SHALL never be swept.

#### Scenario: Sweep after a week

- **GIVEN** GitHub keeps parked pages for one week, with a parked page last active eight days ago and a pinned one last active nine days ago
- **WHEN** the app launches
- **THEN** the unpinned page is closed and its state bytes removed
- **AND** the pinned page remains

---

### Requirement: TAB-008 - Pages under per-site features

Pages SHALL follow the owning site's feature posture: an incognito site's pages
never reach disk and every parked page is dropped on relaunch (INC-002/003);
an Always open Home site reverts only its active page to `initUrl` on cold
start and shortcut tap, parking the page it was on, and keeps parked pages
(AOH-001); an archive-tier site's pages ride the archive's encrypted state with
no state bytes on disk, and app-tier persistence is byte-identical whether or
not archives hold pages (ARCH-001/006); the site QR share never carries pages;
settings backup carries `pages` but never state bytes; deleting a site removes
every state file under `<siteId>/`.

#### Scenario: Incognito relaunch

- **GIVEN** an incognito Wikipedia site with two parked pages
- **WHEN** the app is killed and relaunched
- **THEN** Wikipedia has one page, at `initUrl`
- **AND** no file exists under `webview_state/<siteId>/`

#### Scenario: Always open Home relaunch

- **GIVEN** a Mastodon site with Always open Home, active on a post, with one parked page
- **WHEN** the app is cold-started
- **THEN** Mastodon's active page is a home page
- **AND** both the post and the previously parked page are listed as parked
