## ADDED Requirements

### Requirement: LIR-018 - A Hosted Tab Is Owned By One Site And Runs As Another

A tab (`SiteTab`, TAB-001) SHALL carry an optional `hostSiteId`. `null` means the tab runs as its owner; a value names the site it runs as, and a value equal to the owner's `siteId` SHALL be stored as `null`. The tab's running identity is its host when it has one, else its owner.

A hosted tab is **owned** by the site whose tab list holds it: it is listed, activated, closed and backed out of (TAB-007) in that site's tree, and its record is persisted with that site (LIR-022). It **runs as** its host: while it is the owner's active tab, the owner's one webview SHALL be rebuilt (TAB-003) with the host's identity, which is:

- the host's container, as the host's own webview would bind it;
- every per-site field NESTED-010's `LaunchUrlFunc` chain carries, read through the host's `effective*` getters;
- the host's identity plumbing: the cookie reader and the cookie mirror (`cookieSiteId`, and the model `onCookiesChanged` writes, which is the host's, never the owner's), the `blockedCookies` sweep, the anti-fingerprinting seed, block-statistics attribution and notification attribution;
- the host's navigation rules: `initUrl` and domain claims for the same-domain test, `blockAutoRedirects`, `externalLinksInBrowser`, and outbound routing (LIR-014) with the host as source. Home (NAV-004) goes to the host's `initUrl`.

What belongs to the webview slot stays with the owner: the `IndexedStack` slot and its key, membership of the loaded set, pause and retention tier, auto-load, the background-audio exemption, the kiosk and fullscreen shell, and the tab list with its url and title writes. The HTML cache, a per-site snapshot of the owner's own page, SHALL be neither read nor written while a hosted tab is active.

A hosted tab's `url` SHALL stay inside its host's navigation domain (`getNormalizedDomain(url) == getNormalizedDomain(host.initUrl)`), which is TAB-001's rule with the host in place of the owner. TAB-001 and TAB-002 make the same exception: such a tab is in its host's domain and shares its host's container and posture, not its owner's. Hosted tabs SHALL NOT add a webview: the host may be loaded in its own slot at the same time, and both webviews bind the host's container, as a nested screen already does.

A path that loads an owner URL into the owner's webview (a home-shortcut launch, the Always open Home reset, an inbound LIR-011 open-in-main) SHALL first bind the owner's slot to a tab the owner runs itself: the active tab when it has no host, else its nearest ancestor that has none, else a new root tab at the owner's `initUrl`. It SHALL NOT load an owner URL into a slot running as another site.

The tab list SHALL mark a hosted tab with its host's name, since two rows with the same URL can run as different identities.

#### Scenario: A hosted tab runs with the host's cookies and posture

- **GIVEN** a DuckDuckGo site owning a tab hosted by a signed-in GitHub site with proxy P2 and language `de`
- **WHEN** the user activates that tab
- **THEN** DuckDuckGo's webview slot is rebuilt bound to GitHub's container
- **AND** the page is signed in, loads through P2, and sends `Accept-Language: de`
- **AND** the fingerprint seed is GitHub's
- **AND** no second webview is created for DuckDuckGo

#### Scenario: The cookie mirror writes the host

- **GIVEN** the hosted GitHub tab is active in DuckDuckGo's slot
- **WHEN** the page sets a cookie
- **THEN** GitHub's cookie mirror is updated
- **AND** DuckDuckGo's `cookies` and its entry in cookie secure storage are unchanged

#### Scenario: The host's navigation rules apply

- **GIVEN** the hosted GitHub tab is active in DuckDuckGo's slot
- **WHEN** the user taps a link to `https://docs.github.com/`
- **THEN** it loads in place, because it is inside GitHub's navigation domain
- **AND** a tap on `https://duckduckgo.com/` is treated as cross-domain for GitHub, so it opens nested or routed as GitHub's settings decide

#### Scenario: The HTML cache is left alone

- **GIVEN** DuckDuckGo has HTML caching on
- **WHEN** a hosted GitHub tab is active in its slot and a page finishes loading
- **THEN** nothing is written to DuckDuckGo's HTML cache
- **AND** switching back to a DuckDuckGo tab paints nothing from GitHub's page

#### Scenario: The host is loaded at the same time

- **GIVEN** GitHub's own slot is loaded
- **WHEN** a hosted GitHub tab becomes active in DuckDuckGo's slot
- **THEN** both webviews are live and bound to GitHub's container
- **AND** GitHub's own slot is not disposed

#### Scenario: A shortcut launch does not load the owner's home into a hosted slot

- **GIVEN** DuckDuckGo's active tab is hosted by GitHub and its parent is DuckDuckGo's own
- **WHEN** the user launches DuckDuckGo from its home-screen shortcut
- **THEN** the parent tab becomes active before the home URL loads
- **AND** DuckDuckGo's home loads with DuckDuckGo's identity

#### Scenario: The tab list names the host

- **GIVEN** a DuckDuckGo tab hosted by Work GitHub and another hosted by Personal GitHub, both on `github.com`
- **WHEN** the user opens DuckDuckGo's tab list
- **THEN** each row names the site it runs as

---

### Requirement: LIR-019 - Who May Host A Tab

Hosted tabs SHALL exist only on the container engine. On the legacy engine every creation path SHALL fall back to its behaviour without this change: the long-press row stays disabled (TAB-006) and a tap opens the nested screen.

Neither the owner nor the host SHALL be an archive-tier site (ARCH-006): an archive session must not run inside an app-tier container, and an app-tier record must not name an archive site (ARCH-001). A host SHALL own a persistent named container, so it SHALL NOT be effectively incognito: on iOS, macOS and Linux an incognito site binds no named container (`siteOwnsContainerProfile`), and its hosted tab would get a fresh ephemeral store on every rebuild, which is neither the host's session nor a persistent one. Archive-tier sites are effectively incognito, so they can host on no platform.

A site MAY host a URL only when its navigation domain equals the URL's normalized domain (LIR-018). `hostCandidates(url, owner)` SHALL return the eligible sites for a URL, other than the tab's current running identity, ordered by LIR: the owner's outbound preferences first (LIR-014 step 1), then claim specificity (LIR-014 step 2), then site order. The navigation-domain test filters; it does not rank.

#### Scenario: The legacy engine has no hosted tabs

- **GIVEN** the device runs the legacy cookie engine and the user has a GitHub site
- **WHEN** the user long-presses a `github.com` link in DuckDuckGo
- **THEN** "Open in new tab" is disabled with its TAB-006 reason and no "as GitHub" row is offered

#### Scenario: An incognito site cannot host

- **GIVEN** the only GitHub site is incognito
- **WHEN** the user long-presses a `github.com` link in DuckDuckGo
- **THEN** no "Open in new tab as" row is offered

#### Scenario: A claim outside the navigation domain does not make a host

- **GIVEN** a Codeberg site at `https://codeberg.org/` that claims `exactHost:codeberg.page`
- **WHEN** `hostCandidates` runs for `https://codeberg.page/docs`
- **THEN** the Codeberg site is not a candidate, because `codeberg.page` is outside its navigation domain

#### Scenario: Archive-tier sites neither own nor host

- **GIVEN** an open archive holds a GitHub site
- **WHEN** the user long-presses a `github.com` link in an app-tier site
- **THEN** the archive-tier GitHub site is not offered
- **AND** a long-press inside an archive-tier site offers no "as" row at all

---

### Requirement: LIR-020 - Open A Link In A New Tab As Another Site

A long-press on a link whose URL is outside the active tab's running identity's navigation domain SHALL, when `hostCandidates(url, owner)` is non-empty, replace TAB-006's disabled "Open in new tab" row with one "Open in new tab as {site}" row per candidate. Choosing a row SHALL create a parked child tab (`parentId` = the active tab) hosted by that site, without navigating, building a webview or writing state bytes, and SHALL show a snackbar offering "Switch", as TAB-006 does for an in-domain link. The routing toggle (LIR-013) SHALL NOT gate these rows: each names the site it opens as, so nothing is silent.

A link inside the active tab's running identity's navigation domain SHALL keep TAB-006's "Open in new tab", and the child SHALL run as the same identity as the active tab. With no candidate, the row SHALL stay disabled as TAB-006 specifies. A plain tap SHALL keep LIR-015's behaviour.

#### Scenario: A GitHub link from DuckDuckGo opens as a GitHub tab

- **GIVEN** DuckDuckGo is on a results page and the user has a signed-in GitHub site
- **WHEN** they long-press a `github.com` result and choose "Open in new tab as GitHub"
- **THEN** a parked child tab for that URL, hosted by GitHub, appears under the results tab
- **AND** the results page stays on screen
- **AND** no capture, dispose or rebuild runs

#### Scenario: Two candidates, two rows

- **GIVEN** Work GitHub and Personal GitHub both host `github.com`, and DuckDuckGo prefers Work GitHub for `github.com`
- **WHEN** the user long-presses a `github.com` link in DuckDuckGo
- **THEN** the menu shows "Open in new tab as Work GitHub" above "Open in new tab as Personal GitHub"

#### Scenario: Inside a hosted tab, an in-domain link stays with the host

- **GIVEN** DuckDuckGo's active tab is hosted by GitHub
- **WHEN** the user long-presses a link to another `github.com` page and chooses "Open in new tab"
- **THEN** the child tab is owned by DuckDuckGo and hosted by GitHub

#### Scenario: No candidate keeps the row disabled

- **GIVEN** no site can host `wpewebkit.org`
- **WHEN** the user long-presses a `wpewebkit.org` link
- **THEN** "Open in new tab" is disabled with its reason, as TAB-006 specifies

---

### Requirement: LIR-021 - Keep A Nested Screen As A Tab

A nested screen opened by an in-app navigation from a site's active tab (a `blockOpenNested` decision, including an LIR-015 routed open) SHALL offer "Keep as tab" in its menu. A nested screen opened by an inbound share (LIR-011) has no tab to attach to and SHALL NOT offer it; nor SHALL a locked kiosk shell (KIOSK-002).

The kept tab's host SHALL be the site the nested screen is bound to when that site may host the screen's current URL under LIR-019, or when it is the owner and the URL is inside the owner's navigation domain. Otherwise the action SHALL offer "Keep as tab as {site}" for each of `hostCandidates(currentUrl, owner)`, and SHALL be disabled with its reason when there is none.

Keeping SHALL pop the nested screen, create a child of the tab the screen was opened from (a root tab when that tab has closed meanwhile) with the screen's current URL and title and the chosen host, and make it the owner's active tab through TAB-003. No state from the nested webview SHALL be carried: the tab loads its URL with an empty history.

#### Scenario: A routed screen becomes a GitHub tab

- **GIVEN** DuckDuckGo routed a `github.com` tap to a nested screen bound to GitHub
- **WHEN** the user chooses "Keep as tab"
- **THEN** the screen closes
- **AND** DuckDuckGo gains a child tab under the results tab, hosted by GitHub, and it is active
- **AND** its history starts at the kept URL

#### Scenario: An unrouted screen can still be kept as the right site

- **GIVEN** routing is off and a `github.com` tap opened a nested screen with DuckDuckGo's posture
- **AND** the user has a GitHub site
- **WHEN** the user opens the nested screen's menu
- **THEN** it offers "Keep as tab as GitHub"
- **AND** choosing it creates a DuckDuckGo tab hosted by GitHub, loaded fresh with GitHub's session

#### Scenario: Nothing can host the current page

- **GIVEN** the nested screen has navigated in place to `https://blog.example/` and no site can host it
- **THEN** "Keep as tab" is disabled with its reason

#### Scenario: A shared link's screen has no Keep as tab

- **GIVEN** a nested screen opened by an inbound share (LIR-011)
- **THEN** its menu has no "Keep as tab"

---

### Requirement: LIR-022 - Hosted Tab Persistence And State Keys

A hosted tab's record SHALL be persisted only when its owner persists its tab list (TAB-009) and its host would persist its own navigation URL (the host has neither `incognito` nor `alwaysOpenHome`). Otherwise the tab SHALL live for the session only, so a host's Always open Home keeps that host's deep URLs off disk even when another site owns the tab.

A tab's navigation-state key SHALL be `webViewStateKey(hostSiteId ?? ownerSiteId, tabId)`: bytes are keyed by the identity that produced them. Bytes SHALL be written only for a tab whose record is persisted and whose running identity has `persistsNavState`. Consequently:

- `removeStatesForSite(siteId)`, run by site delete, the per-site data wipe and archive close, SHALL drop every byte produced under that site's identity, including hosted tabs in other sites' trees.
- The startup orphan sweep SHALL build its live-key set with the same key function.
- Deleting an owner SHALL remove the bytes of its hosted tabs, which live under their hosts' keys, explicitly; the orphan sweep is the backstop.
- Moving a tab between owners with its host unchanged SHALL NOT change its key (LIR-025).

Settings backup SHALL carry `hostSiteId` in the tab record and never state bytes; the site QR share never carries tabs (TAB-009).

#### Scenario: Bytes are keyed by the host

- **GIVEN** DuckDuckGo owns tab `t1` hosted by GitHub, and both persist
- **WHEN** `t1` is parked after browsing
- **THEN** its bytes are stored under `webViewStateKey(<github siteId>, t1)`

#### Scenario: Wiping the host drops its hosted tabs' bytes

- **GIVEN** DuckDuckGo owns a parked tab hosted by GitHub with saved bytes
- **WHEN** the user clears GitHub's site data
- **THEN** that tab's bytes are gone
- **AND** the tab itself stays in DuckDuckGo's tree with its URL

#### Scenario: An Always open Home host keeps its URLs off disk

- **GIVEN** a banking site with Always open Home that hosts a tab owned by DuckDuckGo
- **WHEN** the app is killed and relaunched
- **THEN** DuckDuckGo's persisted tab list does not contain that tab or its URL
- **AND** no state file exists for it

#### Scenario: Deleting the owner leaves no hosted bytes behind

- **GIVEN** DuckDuckGo owns a tab hosted by GitHub with saved bytes
- **WHEN** DuckDuckGo is deleted
- **THEN** the bytes under GitHub's key for that tab are removed
- **AND** GitHub's own tabs' bytes are untouched

---

### Requirement: LIR-023 - Host Deleted, Cleared, Archived Or No Longer Eligible

When a host is deleted, is moved into an archive, or stops being eligible under LIR-019 (incognito turned on), every tab it hosts in another site's tree SHALL close with TAB-007's re-parenting, and an owner whose active tab closed SHALL be re-bound to the tab that takes over (TAB-003, with no capture of the closing tab). For a delete this SHALL complete before the host's container is deleted: `deleteContainer` is a no-op on iOS and macOS while a webview still binds the store, and a surviving store would keep the deleted site's login.

The tab SHALL NOT fall back to its owner as host. Its page, login and back stack belonged to the host's identity; running its URL as the owner would switch identity without asking, which is the surprise the feature exists to avoid, and the URL is usually outside the owner's domain anyway (LIR-018).

Clearing a host's site data SHALL dispose every webview bound to its container, its own and any owner slot whose active tab it hosts, so no live page writes into the cleared container (ETP-022), and SHALL drop every state key under it (LIR-022). An owner moved into an archive SHALL first close the hosted tabs it owns.

The same rule SHALL run as orphan cleanup at startup, after an import and after a delete: a tab whose `hostSiteId` names no eligible host is closed.

#### Scenario: Deleting the host closes its tabs first

- **GIVEN** DuckDuckGo's active tab is hosted by GitHub, under a DuckDuckGo-run parent
- **WHEN** the user deletes GitHub
- **THEN** the hosted tab closes and DuckDuckGo's slot is re-bound to the parent
- **AND** only then is GitHub's container deleted

#### Scenario: Clearing the host disposes the owner's slot

- **GIVEN** DuckDuckGo's active tab is hosted by GitHub
- **WHEN** the user clears GitHub's site data
- **THEN** DuckDuckGo's webview is disposed and rebuilt against the cleared container
- **AND** GitHub's own webview is disposed and rebuilt too

#### Scenario: Turning incognito on for the host closes its hosted tabs

- **GIVEN** Mastodon owns a parked tab hosted by GitHub
- **WHEN** the user turns incognito on for GitHub and saves
- **THEN** Mastodon's tab hosted by GitHub is closed

#### Scenario: Import drops tabs whose host is missing

- **GIVEN** a backup whose DuckDuckGo site owns a tab hosted by a `siteId` absent from the backup
- **WHEN** the user imports it
- **THEN** that tab is not in DuckDuckGo's restored tree and its children are re-parented

---

### Requirement: LIR-024 - The Process-Global Proxy Follows The Identity A Slot Runs As

Every engine that reads a loaded slot's proxy or Tor pin (`SiteUnloadEngine.indicesToUnloadForProxyMismatch`, `indicesToUnloadForTorExitMismatch`, `torExitNodesFor`, and router mode's `sharesDefaultSession`) SHALL read the slot's running identity: the host of its active tab, or the owner when that tab has no host.

On Android without router mode, and on Linux:

- A rebind of the visible slot (tab switch, a back-at-start close, Keep as tab, a move, Run as) to a tab whose running identity's effective proxy is not equivalent to the applied one SHALL run the PROXY-008 sequence for that identity before the rebuild: unload the mismatched slots, apply the proxy, and fail closed, with no rebuild, when it cannot be applied.
- A rebind of a slot that is not visible SHALL leave the slot disposed and out of the loaded set when its new identity's proxy is not equivalent to the applied one; its next activation rebuilds it.

Under router mode (PROXY-013) no slot is evicted for a mismatch, and a slot running a hosted tab presents its host's credential because it runs in its host's profile.

#### Scenario: Activating a hosted tab applies the host's proxy

- **GIVEN** Android without router mode, DuckDuckGo on proxy P1 and GitHub on P2, with GitHub's own slot not loaded
- **WHEN** the user activates a DuckDuckGo tab hosted by GitHub
- **THEN** every loaded slot whose running identity's proxy differs from P2 is disposed before P2 is applied
- **AND** DuckDuckGo's slot is rebuilt as GitHub under P2

#### Scenario: A background rebind does not load under the wrong proxy

- **GIVEN** Android without router mode, the visible site on P1, and a background Mastodon slot on P1
- **WHEN** the tab list closes Mastodon's active tab and the tab taking over is hosted by a site on P2
- **THEN** Mastodon's slot is left disposed and out of the loaded set
- **AND** it is rebuilt, under the PROXY-008 sequence, when the user next opens Mastodon

#### Scenario: The host's own slot is not evicted for itself

- **GIVEN** GitHub's own slot is loaded on P2
- **WHEN** a DuckDuckGo tab hosted by GitHub becomes active
- **THEN** GitHub's own slot stays loaded, since both run under P2

---

### Requirement: LIR-025 - Move A Tab And Its Subtree To Another Site

The tab list SHALL offer "Move to site..." on a tab row. It SHALL move the tab and its whole subtree from owner A's tree into owner C's tree, under a tab of C the user picks or as a root. The decision SHALL be a pure engine operation, `TabLifecycleEngine.moveSubtree(...)`, returning A's new tab list and the tab that takes over its slot (or none, meaning a new home tab), whether A's slot must be re-bound, C's new tab list, the state keys to rename, and the state keys to drop.

- Each moved tab SHALL keep the identity it ran as (`hostSiteId ?? A`), re-normalised against C: a tab A ran itself becomes hosted by A, and a tab hosted by C becomes C's own.
- State bytes SHALL follow the tab. Keys are host-keyed (LIR-022), so a move with the host unchanged needs no rename, except that a moved tab whose id is already used in C's tree (always so for the primary tab id) SHALL get a fresh id and have its bytes renamed with a new storage operation, `WebViewStateStorage.renameState(oldKey, newKey)`. When C does not persist the moved tab's record (LIR-022), its bytes SHALL be dropped instead.
- When A's active tab is in the moved subtree, its bytes SHALL be captured first, so they move with it, and A's slot SHALL be re-bound through TAB-003 to the tab the close rule of TAB-007 would pick, or to a new home tab when A's tree empties. The moved tabs SHALL arrive parked; C's active tab SHALL NOT change; a snackbar SHALL offer "Switch".
- The move SHALL be refused on the legacy engine, when A or C is archive-tier, when any moved tab would end up hosted by a site that may not host it under LIR-019 (for example an incognito A moving its own tabs, which would make A their host), and when the chosen parent is not a tab of C.

#### Scenario: A subtree keeps its identities

- **GIVEN** DuckDuckGo tab R (run by DuckDuckGo) with child K hosted by GitHub
- **WHEN** the user moves R to Mastodon as a root
- **THEN** Mastodon's tree gains R hosted by DuckDuckGo with child K hosted by GitHub
- **AND** neither tab's state key changes

#### Scenario: A tab hosted by the destination becomes its own

- **GIVEN** DuckDuckGo owns tab K hosted by GitHub
- **WHEN** the user moves K to GitHub under GitHub's tab G
- **THEN** K is a child of G with no `hostSiteId`
- **AND** its state key is unchanged

#### Scenario: The primary tab gets a fresh id

- **GIVEN** DuckDuckGo's primary tab has saved bytes
- **WHEN** the user moves it to Mastodon, whose own primary tab uses the same id
- **THEN** the moved tab gets a fresh id and its bytes are renamed to the new key
- **AND** DuckDuckGo gets a new home tab in its place

#### Scenario: Moving the active tab re-binds the owner

- **GIVEN** DuckDuckGo's active tab A2 is a child of A1
- **WHEN** the user moves A2 to Mastodon
- **THEN** A2's bytes are captured before anything else
- **AND** DuckDuckGo's slot is re-bound to A1 through the tab-switch path
- **AND** Mastodon's active tab is unchanged

#### Scenario: A move that would make an incognito site a host is refused

- **GIVEN** an incognito Wikipedia site
- **WHEN** the user tries to move one of its own tabs to Mastodon
- **THEN** the move is refused with its reason and both trees are unchanged

---

### Requirement: LIR-026 - Move A Tab Under Another Tab Of The Same Site

The tab list SHALL offer "Move under..." on a tab row. It SHALL re-parent the tab and its subtree under another tab of the same site, or to the top level, through the pure engine operation `TabLifecycleEngine.reparent(tabs, tabId, newParentId)`. The operation SHALL refuse a new parent inside the moved subtree, SHALL change only `parentId` and the moved subtree's position in the list (directly after the new parent's last descendant), and SHALL NOT touch state bytes, hosts or the active tab. It SHALL be available on both cookie engines.

#### Scenario: Re-parent within a site

- **GIVEN** GitHub tabs A, B and C, each a root
- **WHEN** the user moves C under A
- **THEN** C is A's child, listed directly under A's subtree
- **AND** no webview is rebuilt and no state key changes

#### Scenario: A tab cannot move under its own descendant

- **GIVEN** GitHub tab A with child B
- **WHEN** the user tries to move A under B
- **THEN** B is not offered as a parent and the tree is unchanged

---

### Requirement: LIR-027 - Run A Tab As Another Site

The tab list SHALL offer "Run as..." on a tab row, listing the sites that may host the tab's URL under LIR-019 plus the owner when the URL is inside the owner's navigation domain, with the current identity marked. Choosing another SHALL change the tab's host through the pure engine operation `TabLifecycleEngine.changeHost(...)`, which returns the updated tab list and the state key to drop.

Changing the host SHALL drop the tab's state bytes and keep only its URL and title. Restored state carries the identity it was captured under: iOS and macOS `interactionState` holds form contents typed as the old identity, and Android's saved state holds its back stack and history, so restoring either into the new host's container would move one identity's data into another's. When the tab is active, the owner's slot SHALL be re-bound with the new host's identity, with no restore queued, under LIR-024's proxy rule. The tab's children SHALL keep their own hosts.

#### Scenario: Switching a tab from personal to work GitHub

- **GIVEN** DuckDuckGo owns a parked tab hosted by Personal GitHub with saved bytes
- **WHEN** the user runs it as Work GitHub
- **THEN** its bytes under Personal GitHub's key are dropped
- **AND** the tab keeps its URL and title with `hostSiteId` = Work GitHub
- **AND** activating it loads the URL fresh with Work GitHub's session and no back history

#### Scenario: Run as re-binds an active tab

- **GIVEN** the tab is DuckDuckGo's active tab
- **WHEN** the user runs it as Work GitHub
- **THEN** DuckDuckGo's slot is rebuilt as Work GitHub with no restore queued

#### Scenario: Only sites that may host the URL are offered

- **GIVEN** a tab on `github.com` and sites Work GitHub, Personal GitHub and Mastodon
- **WHEN** the user opens "Run as..."
- **THEN** only the two GitHub sites are listed

#### Scenario: Children keep their own hosts

- **GIVEN** a tab hosted by Personal GitHub with a child hosted by Personal GitHub
- **WHEN** the user runs the parent as Work GitHub
- **THEN** the child is still hosted by Personal GitHub
