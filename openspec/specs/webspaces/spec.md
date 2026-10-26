# Webspaces Feature Specification

## Purpose

The Webspaces feature allows users to organize their saved sites into separate workspaces, enabling better organization and context switching between different browsing contexts (e.g., Work, Personal, Research).

## Status

- **Implementation Date**: 2026-01-12
- **Status**: Completed

---

## Requirements

The grouped site launcher is an optional experiment (DEVTOOLS-011). Group grids, their menus, and search below apply only when developer mode and **Alternative design** are both on. With either off, the existing webspace list, inline edit/delete actions, create button, app bar, add-site button, and drawer navigation remain the default. Switching interfaces SHALL preserve sites, webspaces, membership, and the selected webspace.

### Requirement: WEBSPACE-001 - Create Multiple Webspaces

Users SHALL be able to create multiple webspaces to organize sites into logical groups.

#### Scenario: Create a new webspace

**Given** the user is on the webspaces list screen
**When** the user taps the create-webspace action (the library toolbar when the experiment is enabled, otherwise the Create Webspace button)
**And** enters a name (e.g., "Work")
**And** selects sites to include
**And** taps the checkmark icon
**Then** a new webspace is created with the specified name and sites

---

### Requirement: WEBSPACE-002 - Select Active Webspace

Users SHALL be able to select and switch between webspaces to view filtered sites.

With the experiment enabled, the library SHALL be a home screen of groups, as a phone's is of folders: a group opens as a folder over the group grid (WEBSPACE-008), and there is no bottom navigation. The home header SHALL lead its title with
the app's logo in the chosen accent, SHALL open App Settings, and its add button SHALL offer adding a site or creating a webspace (EDIT-012). On a wide screen the library and an open folder SHALL widen with the window, up to a fixed number of columns. Every tab of every site stays reachable from the tabs sheet of any site on screen (TAB-017).

#### Scenario: Select a webspace

**Given** the user is viewing the webspaces list
**When** the user taps a webspace
**Then** that webspace becomes selected
**And** with the experiment enabled, its sites open in a folder over the group grid without opening the drawer
**And** with the experiment disabled, its filtered sites open in the existing drawer

---

### Requirement: WEBSPACE-003 - Visual Selection Indicator

The system SHALL provide clear visual indication of which webspace is currently active. In Alternative design, a group's background color SHALL be stable for its persisted identity across revisiting, filtering, renaming, reordering, adding or removing other groups, and settings restore. Selecting a group SHALL show an accent outline and check without recoloring its background. Light and dark themes SHALL use paired shades for the same identity.

#### Scenario: Display selected webspace indicator

**Given** a webspace is selected
**When** the user views the webspaces list
**Then** the selected webspace has an accent highlight and a check
**And** with the experiment enabled, it appears as a group
**And** each group previews up to four site favicons from its actual membership order
**And** a group with more than four sites previews three favicons and the remaining count
**And** its site count reflects the current filtered membership, including all sites for the synthetic All group

#### Scenario: A group's color stays familiar

**Given** the user has seen the Work and Personal groups in Alternative design
**When** they open a group and return, reorder or rename it, filter the list, or restore their settings
**Then** each group's background color stays the same within the current theme
**And** the selected group is identified by its outline and check

---

### Requirement: WEBSPACE-004 - Filtered Site Navigation

The workspace site grid and the browser drawer SHALL only show sites belonging to the currently selected webspace. Library searches SHALL filter the current view without changing membership or persisted order.

Searching the Webspaces group grid SHALL show matching workspace names and a separate Sites section matching saved site names or homepage addresses, case-insensitively with surrounding whitespace ignored. Site results SHALL include every saved site, regardless of the selected workspace, and appear once even when a site belongs to multiple groups. A site result SHALL open directly without changing the selected workspace. Clearing the search SHALL restore the group grid. Each site result SHALL take its container color where WEBSPACE-014 shows one and show up to two named workspace memberships in their stable workspace colors, excluding the synthetic All group. Additional memberships SHALL be indicated by a count, with all membership names available to accessibility services. Site colors SHALL match the tabs sheet and remain stable when selection changes.

The library's home header, beside App Settings, and an open folder's header, at its end, SHALL each carry a tab count button while what they show holds a site with tabs: the home's counts and lists the tabs of every site, a folder's those of its sites. It opens the tabs sheet with no site on screen, titled by that scope and listing each site's tree, and a tab picked there opens its site on that tab.

#### Scenario: Filter drawer by webspace

**Given** the user has selected the "Work" webspace
**And** "Work" contains sites A and B
**And** "Personal" contains site C
**When** the user opens the drawer
**Then** only sites A and B are displayed
**And** site C is not visible

#### Scenario: Find a site from the webspaces grid

**Given** Work is selected and contains Alpha, while Beta belongs to another workspace
**When** the user searches the Webspaces grid for Beta's name or homepage address
**Then** Beta appears in the Sites section and can be opened directly
**And** Work remains selected and workspace membership and saved order remain unchanged
**And** a site shared by multiple groups appears only once
**And** a query matching both a workspace and a site shows both sections
**And** a query matching neither shows No matches
**And** clearing the query restores the workspace grid
**And** each site result uses its tab-tree color and labels up to two named workspaces it belongs to
**And** a site in more than two named workspaces shows the remaining count and exposes all memberships to accessibility services

#### Scenario: Tab tree of a library level

**Given** All holds eight sites with one tab each, one of them with tabs off, and Work holds one site with tabs
**When** the user looks at the home header, then at the open Work folder's
**Then** the tab button shows 7, then 1, and opens the tabs of all sites, then of Work's
**And** a webspace whose sites have no tabs shows no tab button
**And** picking a nested tab there opens its site on that tab

Regression: `test/webspace_library_test.dart` and `test/webspace_library_app_test.dart`.

---

### Requirement: WEBSPACE-005 - Persistent State

Webspaces and selection state SHALL persist across app restarts. The group library navigation and search are transient UI state.

#### Scenario: Restore webspace selection on restart

**Given** the user has selected "Work" webspace
**When** the app is closed and reopened
**Then** "Work" webspace remains selected
**And** the drawer shows Work sites

---

### Requirement: WEBSPACE-006 - Edit Webspace

Users SHALL be able to edit existing webspaces.

#### Scenario: Modify webspace contents

**Given** a webspace "Work" exists with sites A and B
**When** the user chooses Edit (from the group menu when the experiment is enabled, otherwise the inline edit action)
**And** adds site C and removes site A
**And** saves changes
**Then** "Work" now contains sites B and C

---

### Requirement: WEBSPACE-007 - Delete Webspace

Users SHALL be able to delete webspaces.

#### Scenario: Delete a webspace

**Given** webspaces "Work" and "Personal" exist
**And** "Work" is currently selected
**When** the user chooses Delete for "Work" (from the group menu when the experiment is enabled, otherwise the inline delete action)
**And** confirms the deletion
**Then** "Work" is removed
**And** selection is cleared
**And** user returns to webspaces list

---

### Requirement: WEBSPACE-008 - Back to Webspaces Navigation

Users SHALL be able to return to the group grid from a workspace site grid. The browser drawer SHALL retain its Back to Webspaces action.

With the group library enabled, a group SHALL open as a folder: a panel that grows out of the group's tile over the dimmed and blurred group grid, and shrinks back into the tile when it closes. A tap beside the panel, the system back action and Escape SHALL close it; Back closes an open folder before it does anything else. Closing SHALL keep the library search, the selected webspace and its membership. Scrolling, stray drags and taps inside the panel, and reordering its sites, SHALL keep it open. The grid under an open folder SHALL take no input, a closing panel SHALL take none, Back SHALL work while the panel moves, and search and the home header SHALL stay put. The system's reduced-motion preference SHALL open and close it without animation.

An open folder SHALL hold every group as a page, in the group grid's order, as a phone's home screen holds pages: a sideways swipe SHALL go to the next or previous group, and the group whose page a swipe comes to rest on SHALL become the selected one, as a tap on its tile would make it; a swipe that has not come to rest SHALL select nothing. During a swipe the panel SHALL keep the size of the page it leaves until late in the swipe, then take the next page's. Dots under the pages SHALL show which page is on screen, and a tap on one SHALL go to its group. A mouse drag SHALL turn a page as a swipe does, and while the panel itself has focus the Left and Right arrow keys SHALL go to the previous and next group, each press one further than the last. A folder closes into the tile of the group it is on.

The open panel's top bar SHALL pull it down: the panel follows the finger, shrinking a little as the grid behind it brightens. Let go past a quarter of its height, or flung down, it SHALL close into its tile; let go short of that, it SHALL spring back.

A site opened from the library SHALL open as a phone opens an app: a card in the site's colour, holding its icon, grows out of the site's icon until it covers the screen, the site is shown under it, and the card fades off it. A site or tab picked where no icon is (a tabs sheet, the tab strip) SHALL open through the same card faded in over the screen. Returning to the library SHALL fade that card in over the site, bring the library back under it, and shrink the card into the site's icon, or fade it where no icon is in view. The card SHALL wait for the switch under it no longer than a fixed cap, SHALL take no input while it moves, and reduced motion SHALL show no card.

A site's top bar, held, SHALL fade the site's card in over it and bring the library back under the card, which SHALL then come off the screen by the point held, so the site is never seen around it, and follow the finger, smaller the further down it is pulled, even once the bar itself has left the screen. Let go past a quarter of the screen's height, or flung down, the card SHALL shrink into the site's icon as a return to the library does; let go short of that, or flung back up, it SHALL go back over the screen and the site SHALL be shown again once the library has been, or once the card's cap has passed. A pull on the bar with no hold first SHALL leave the site on screen, so a pull on the page still refreshes it. A locked kiosk session SHALL lift nothing, and with reduced motion no card SHALL lift: a let-go that would close returns to the library at once.

Icons SHALL move as a phone's do: one the grid moves (a drop, a menu's Move, a search narrowing the grid) slides from its old place to its new one without first appearing at the new one, one let go after a drag lands from where it was let go, scrolling slides none, and going between browsing, search results and no results crossfades. These motions share one set of durations and curves.

With Alternative design enabled, the site browser SHALL use a grid button to return directly to the previous library view, retaining its selected group. It SHALL NOT create a navigation drawer or show a hamburger button. The return SHALL preserve the site's loaded state and tab selection. A locked kiosk session SHALL expose neither navigation affordance.

#### Scenario: Return from browsing a site

**Given** Alternative design is enabled and the user opened a site from a group's grid
**When** the user taps the browser's grid button
**Then** the previous library view is shown with its selection retained
**And** no drawer opens
**And** opening the site again retains its tab selection

#### Scenario: Navigate back to webspaces list

**Given** the user is viewing sites in a selected webspace
**When** the user opens the drawer
**And** taps "Back to Webspaces"
**Then** the webspaces list is displayed

#### Scenario: Close a folder

**Given** Alternative design is enabled and the Work folder is open
**When** the user taps beside its panel, presses Back, or presses Escape
**Then** the panel shrinks back into Work's tile and the group grid takes input again
**And** the search text, the selected group and its sites are unchanged

#### Scenario: Swipe to another group in an open folder

**Given** Alternative design is enabled and the Work folder is open, with Privacy after it
**When** the user swipes the panel sideways towards Privacy and lets go
**Then** Privacy's sites show in the panel, which takes their size, and Privacy is the selected group
**When** the user closes the folder
**Then** the panel shrinks into Privacy's tile

#### Scenario: Scroll or reorder sites in a folder

**Given** the user is viewing a folder's sites
**When** the user scrolls, drags stray, taps the panel, or long-presses and drags a site
**Then** the folder stays open

#### Scenario: Pull a site down by its top bar

**Given** Alternative design is enabled and Alpha, opened from the Work folder, is on screen
**When** the user drags Alpha's top bar down without holding it first
**Then** Alpha stays on screen
**When** the user holds Alpha's top bar, drags it down a third of the screen and lets go
**Then** Alpha's card follows the finger, smaller, over the library, and shrinks into Alpha's icon in the still open folder
**When** the user opens Alpha again, holds its top bar, drags it down a little and lets go
**Then** the card goes back over the screen and Alpha is shown again

#### Scenario: Open a site and return

**Given** the Work folder is open and holds Alpha
**When** the user taps Alpha
**Then** Alpha's card grows out of its icon while the folder stays on screen, and Alpha shows once the card covers the screen
**When** the user returns to the library
**Then** a full card covers the switch and shrinks back into Alpha's icon in the still open folder

---

### Requirement: WEBSPACE-009 - "All" Webspace

The system SHALL provide a special "All" webspace that shows all sites.

#### Scenario: View all sites via All webspace

**Given** the user has multiple webspaces with various sites
**When** the user selects the "All" webspace
**Then** all sites are displayed in the drawer
**And** the "All" webspace cannot be deleted or moved

---

### Requirement: WEBSPACE-010 - Automatic Index Updates on Site Deletion

When a site is deleted, all webspace indices SHALL be automatically updated.

#### Scenario: Delete site updates webspace indices

**Given** site at index 2 is in webspaces "Work" (indices [0,2]) and "Personal" (indices [2,3])
**When** site at index 2 is deleted
**Then** "Work" indices become [0]
**And** "Personal" indices become [2] (shifted from [3])

#### Scenario: Deleting an earlier site keeps the active and loaded sites

**Given** sites [A, B, C, D] with A and C loaded and C active
**When** A is deleted from the drawer
**Then** C stays loaded and active at index 1 (`_sites.loaded` and `_sites.current` follow it)
**And** neither D nor an empty slot is shown in C's place

---

### Requirement: WEBSPACE-011 - Reorder Sites by Dragging

Users SHALL be able to change the display order of sites by dragging, in
a library folder, the bottom tab strip and the drawer grid. The new order SHALL persist
across app restarts. In the library and the drawer grid a long press lifts a site, as a
phone lifts an icon: let go where it was without wandering off, it opens the site's menu;
moved, it drags, the other icons make room wherever it hovers, and let go anywhere it keeps
the place it was shown in. A group on the library's home screen lifts and moves the same
way among the groups; "All" never moves and nothing takes its place. In Alternative design
the menus offer no Move Up or Move Down; a screen reader's reorder actions on each icon
move it instead. Where a TV remote drives the device, which cannot drag, an icon's menu
and a group's offer the same moves the screen reader's actions make (NAV-016). This reorders the sites *within* the selected view; it
does not move the webspace cards themselves (WEBSPACE-009 still holds — the
"All" webspace card cannot be moved in the webspaces list).

#### Scenario: Reorder sites within a named webspace

**Given** the "Work" webspace is selected with sites [A, B, C] in that order
**When** the user long-presses site C in the tab strip, the drawer grid, or a library folder and drops it onto site A's position
**Then** "Work"'s membership order becomes [C, A, B]
**And** the change is written to the webspace's persisted `siteIds`
**And** the global order of other webspaces is unaffected

#### Scenario: Reorder sites within the "All" webspace

**Given** the "All" webspace is selected showing every site in `_sites.models` order
**When** the user drags a site to a new position in the tab strip or drawer grid
**Then** `_sites.models` is reordered to match
**And** the active site stays active (its `_sites.current` follows it to its new position)
**And** any loaded webviews keep their in-memory state (each webview is keyed by its site, not its position: ISO-009)
**And** the new order is persisted

#### Scenario: Single site is not draggable

**Given** the selected view contains only one site
**When** the user long-presses that site and lets go
**Then** nothing moves (there is nothing to reorder), and in the library or the drawer grid its menu opens

---

### Requirement: WEBSPACE-013 - A Switch Supersedes an Opening Site, Keeps It Loading and Spares the Screen

Choosing a webspace on the list SHALL supersede an activation still in
flight, as a return to the list does, so the list stays on screen. The site
that activation was opening SHALL go on loading behind the list, as a
preload does, once the switch knows whether the device is online, unless
an input has superseded the switch meanwhile or what a preload waits for
holds it back (another preload in flight, a loaded site on its base domain
on the shared jar, another route). Once the device answers that it is
online, the switch SHALL unload, on the shared cookie jar only, the loaded
sites the new webspace stops showing, except the site on screen, the target
of the live activation and the site it keeps loading. An unload the switch
planned SHALL back off if its site becomes one of those before it is
disposed (PAUSE-006). Offline, every webview stays, so a cached page can
still be read.

#### Scenario: A switch while a tapped site is opening

**Given** site A is loaded behind the list and the user has just tapped it
**And** A's activation has not committed yet
**When** the user chooses a webspace that does not show A
**Then** A's activation is superseded and the list stays on screen
**And** A stays loaded behind the list, never disposed under a screen showing it

#### Scenario: A tapped site not loaded yet goes on loading

**Given** the user has just tapped site A, which is not loaded
**And** A's activation has not committed yet
**When** the user chooses a webspace that does not show A
**Then** the list stays on screen
**And** A loads behind it, as a preload does

#### Scenario: A site opened while a switch unloads it

**Given** a webspace switch is unloading site A, which it left behind
**When** A is opened (a shortcut, a link) before its webview is disposed
**Then** the switch's unload backs off and A stays loaded

#### Scenario: Containers keep every site across a switch

**Given** sites run in per-site containers
**When** the user switches webspaces
**Then** no site is unloaded for the switch (CONT-003)

---

### Requirement: WEBSPACE-014 - Colour Only Tells Look-Alike Sites Apart

With Alternative design enabled, a site's icon in the library SHALL carry its
container colour, as a tinted well and a frame, only where the icon alone does
not tell the site apart: when another saved site shows the same icon (the same
picked icon, or no picked icon and the same host, whose favicon both fetch),
in any webspace, or when the site has no icon of its own and a generic globe
stands in for it. Any other site's icon SHALL sit in a neutral well with no
frame. The card a site opens and closes through SHALL start in the same colour
its icon has, from its first frame.

#### Scenario: Two accounts of one mail service

**Given** "Mail" and "Mail (work)" both open pages on mail.example.com, and "News" has an icon of its own
**When** the user opens a folder holding them
**Then** both mail icons are framed and tinted, each in its own container's colour
**And** the News icon has no frame and no tint

#### Scenario: A site with no icon

**Given** a site imported from a file, which has no icon
**When** the user sees it in the library
**Then** its globe is framed and tinted in its container's colour

---

### Requirement: WEBSPACE-015 - A Folder's Sites as Rows

With Alternative design enabled, an open folder's top bar SHALL hold a switch
between three layouts of its sites: Automatic, the default; Grid; and List.
Automatic SHALL pack the sites as the drawer does: as few columns as hold
every site without scrolling, each site a row while its column is at least
as wide as a row's narrowest and an icon past that, smaller and named on one
line where its column is narrower than the grid's; past four columns, or the
grid's own where it holds more, the sites SHALL scroll. So a phone's folder
shows one column of rows, then two, then four smaller icons across. Each
folder SHALL take the layout its own count calls for, and the choice SHALL be
made again as the window resizes. A row is the site's icon at its start, its name over its web address, and its grants and
tab count at its end. A site imported from a file SHALL show "Imported file"
where the address would be, there and wherever else a site or tab shows its
address under its name, never its file handle. The choice SHALL apply to every folder, persist across
launches and ride a settings backup. Switching SHALL move each icon from its
place in one layout to its place in the other while it shrinks or grows, the
names under the icons fading early and the rows' text fading in late, and the
panel SHALL take the new layout's height as the icons move. In either layout
the panel SHALL be as tall as its sites need up to most of the screen,
resizing late in a swipe to another folder (WEBSPACE-008), and rows SHALL
reorder by dragging as icons do (WEBSPACE-011). Where the window is wide
enough, rows SHALL flow into columns rather than run its whole width. A site
SHALL open from its
row's icon and close back into it, its card starting at that icon's size and
colour. Reduced motion SHALL switch at once.

The library's home SHALL hold a switch of its own beside its search, with
the same three layouts for the webspaces, browsed or found by a search;
Automatic packs them into the room under the search as it packs a folder's
sites.
Shown as rows, the webspaces read in the same way:
each its cluster of site icons at the start, its name over its site count,
and a mark while selected. It SHALL be set app-wide apart from the folders'
switch, persist and ride a backup the same way, and leave how the folders
show their sites as it was. A folder SHALL open out of its row's cluster and
close back into it, and rows SHALL reorder by dragging as the grid does.

#### Scenario: Automatic packs as the drawer does

**Given** Alternative design is enabled, both switches are on Automatic, and a phone's window
**When** the user opens All, which holds eight sites
**Then** the home shows its webspaces as rows and All shows its sites in one column of rows
**When** All holds twelve sites
**Then** it shows them in two columns of rows
**When** All holds more than two columns of rows hold
**Then** it shows them as smaller icons four across, named on one line, and scrolls only once those are full
**And** Work, which holds two, still shows one column of rows
**When** the window is made short enough that the webspaces overflow a column of rows
**Then** the home shows them in two columns of rows, and as icons once those overflow too

#### Scenario: Turn the webspaces into rows

**Given** Alternative design is enabled and the home shows its webspaces as a grid
**When** the user taps the list view switch beside the search
**Then** each webspace's cluster moves to the start of its row, beside its name and site count
**When** the user opens Work
**Then** its folder grows out of Work's row and shows its sites as the folders' switch has them

#### Scenario: Turn a folder into rows

**Given** Alternative design is enabled and the All folder is open as a grid
**When** the user taps the folder's list view switch
**Then** each icon moves to the start of its row as the panel takes the rows' height
**And** every row shows its site's web address
**When** the user swipes to another folder
**Then** its sites are rows too

#### Scenario: Open a site from a row

**Given** a folder is open as rows
**When** the user taps a row
**Then** the site's card grows out of that row's icon

---

### Requirement: WEBSPACE-016 - A Webspace's Icon

A webspace's edit screen SHALL offer a symbol to stand beside its name,
picked from a fixed set of the app's own icons, each read out by its name,
or none, which is how every webspace starts. The symbol SHALL lead the
webspace's name wherever the name is shown: the library's tiles and rows,
an open folder's top bar, the labels on search results, the add-site
picker's chips, the drawer's heading, the app bar and the classic list,
where it replaces the generic webspace icon. It SHALL be saved with the
webspace and ride a settings backup; a stored symbol the app does not know,
or one of the wrong type, SHALL read as none.

#### Scenario: Give Work an icon

**Given** the webspace Work has no icon
**When** the user edits Work and picks the code symbol
**Then** Work's name is led by that symbol on the home and in its folder
**When** the user edits Work again and picks No icon
**Then** its name shows alone and nothing is saved for its icon

---

## Data Model

### Webspace

```dart
class Webspace {
  String id;              // UUID - unique identifier
  String name;            // Display name (user-defined)
  List<int> siteIndices;  // Indices of WebViewModels in this webspace
}
```

## Persistence

Stored in SharedPreferences:
- `webspaces`: JSON array of all webspaces
- `selectedWebspaceId`: ID of currently selected webspace

---

## Logic Engines

Selection and index-update logic is extracted into pure-Dart engines so
the rules can be exercised without a widget tree (same code runs in
production):

- [`WebspaceSelectionEngine`](../../../lib/services/webspace_selection_engine.dart):
  - `filteredSiteIndices({selectedWebspaceId, webspaces, siteCount})` —
    implements WEBSPACE-004 (filtered drawer) including the `All`
    special-case and out-of-bounds filtering.
  - `cleanupWebspaceIndices({webspaces, siteCount})` — strips
    out-of-bounds entries in place.
- [`SiteUnloadEngine`](../../../lib/services/site_unload_engine.dart):
  - `plan(host, ResidencyEvent)` — every rule that unloads a loaded site,
    one `ResidencyEvent` case each (`Activating`, `MemoryPressure`,
    `WebspaceSwitched`, `TorExitSettled`, `NestedOpening`,
    `SlotIdentityChanged`); the rules below are its parts. `apply` runs
    the plan through the one unload, following each site by identity.
  - `indicesToUnloadOnWebspaceSwitch({useContainers, loadedIndices,
    leaving})` — returns `{}` under container mode (sites are isolated
    and stay loaded), else the loaded sites the switch stops showing;
    `plan` keeps those that may go (WEBSPACE-013).
- [`SiteActivationController.switchWebspace`](../../../lib/controllers/site_activation_controller.dart)
  runs the switch as a flow of the activation table (`space`, `sOnline`,
  then the unload's places), printed into `formal/activation.tla`
  (WEBSPACE-013).
  - `indicesToUnloadForProxyMismatch({targetIndex, models, loadedIndices,
    topology})` — on Android (process-global proxy), returns the
    loaded sites whose effective proxy differs from the activating
    site's. Their next request would silently route through the new
    proxy (last-write-wins on `inapp.ProxyController`), so they are
    force-unloaded on activation. Per-site DEFAULT resolves through the
    app-global outbound proxy via `resolveEffectiveProxy`, so two
    DEFAULT sites are equivalent regardless of the global value. Returns
    `{}` on platforms with true per-site proxy (iOS 17+ / macOS 14+).
  - `indicesToEvictForLruCap({targetIndex, loadedIndices, maxLoadedSites,
    priorityOf})` — bounds the number of concurrently loaded webviews at
    [`kMaxLoadedSites`](../../../lib/services/site_unload_engine.dart)
    (currently 20); treats `loadedIndices` as access-ordered (caller
    bumps to end on activation). Evicts the lowest
    `SiteRetentionPriority` first (oldest first within a priority), and
    never an `active` or `activating` site. The active webspace's sites
    rank `webspace`, above other loaded sites, so context-relevant
    sites are evicted last.
- [`SiteRuntime.apply`](../../../lib/controllers/site_runtime.dart)
  implements WEBSPACE-010 and the "All" branch of WEBSPACE-011. Webspaces
  hold site ids, and the loaded sites and the one on screen are held as
  sites, so a delete or a move rewrites no position: the delete takes its
  site out of every webspace's `siteIds`, and `resolveWebspaceIndices`
  rebuilds the positional view after either. Reordering within a named
  webspace rewrites that webspace's `siteIds` list directly
  (`WebspacesController._reorderSiteInWebspace`).

Tests live in [test/webspace_selection_engine_test.dart](../../../test/webspace_selection_engine_test.dart),
[test/site_unload_engine_test.dart](../../../test/site_unload_engine_test.dart),
and [test/site_runtime_test.dart](../../../test/site_runtime_test.dart).

---

## Files

### Created
- `lib/webspace_model.dart` - Webspace data model
- `lib/screens/webspaces_list.dart` - Main webspaces screen
- `lib/screens/webspace_detail.dart` - Edit webspace screen
- `lib/services/webspace_selection_engine.dart` - Filter + unload-on-switch logic
- `test/webspace_model_test.dart` - Unit tests
- `test/webspace_selection_engine_test.dart` - Selection/unload/cleanup tests

### Modified
- `lib/main.dart` - Webspace state management and UI integration
- `pubspec.yaml` - Added `uuid: ^4.5.1` dependency
