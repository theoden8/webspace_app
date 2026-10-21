# Webspaces Feature Specification

## Purpose

The Webspaces feature allows users to organize their saved sites into separate workspaces, enabling better organization and context switching between different browsing contexts (e.g., Work, Personal, Research).

## Status

- **Implementation Date**: 2026-01-12
- **Status**: Completed

---

## Requirements

The grouped site launcher is an optional experiment (DEVTOOLS-011). Group grids, their menus, library tabs, and search below apply only when developer mode and **Alternative design** are both on. With either off, the existing webspace list, inline edit/delete actions, create button, app bar, add-site button, and drawer navigation remain the default. Switching interfaces SHALL preserve sites, webspaces, membership, and the selected webspace.

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

#### Scenario: Select a webspace

**Given** the user is viewing the webspaces list
**When** the user taps a webspace
**Then** that webspace becomes selected
**And** with the experiment enabled, its sites open in a full-screen grid within the Webspaces library tab without opening the drawer
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

The workspace site grid and the browser drawer SHALL only show sites belonging to the currently selected webspace. The Sites library tab SHALL select All and show every saved site in an embedded tab tree. Sites with tabs enabled SHALL expose their parent/child tab hierarchy and the existing open, close, collapse, and reorder controls. Sites with tabs disabled SHALL remain single launchable entries. Tree searches SHALL retain the ancestors of matching tabs. Actions in the embedded tree SHALL NOT dismiss the library route. Library searches SHALL filter the current view without changing membership or persisted order.

#### Scenario: Filter drawer by webspace

**Given** the user has selected the "Work" webspace
**And** "Work" contains sites A and B
**And** "Personal" contains site C
**When** the user opens the drawer
**Then** only sites A and B are displayed
**And** site C is not visible

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

Users SHALL be able to return to the group grid from a workspace site grid using its Back control, the system back action, or a horizontal back swipe across the site grid. The swipe SHALL follow the reading direction (rightwards for left-to-right interfaces, leftwards for right-to-left interfaces) and work in empty groups. Vertical scrolling, short incidental drags, and long-press site reordering SHALL remain available without navigating back. Returning SHALL clear the library search and dismiss its keyboard without changing the selected webspace or its membership. The browser drawer SHALL also retain its Back to Webspaces action.

With the group library enabled, opening and closing a group SHALL use continuous expand/collapse transitions without a blank frame between views, including the first group opened. Search and bottom navigation SHALL remain stationary. Departing grids SHALL stop accepting input immediately, Back SHALL remain usable during the transition, and the system's reduced-motion preference SHALL switch views without animation.

With Alternative design enabled, the site browser SHALL use a grid button to return directly to the previous library view, retaining its selected group or Sites tab. It SHALL NOT create a navigation drawer or show a hamburger button. The return SHALL preserve the site's loaded state and tab selection. A locked kiosk session SHALL expose neither navigation affordance.

#### Scenario: Return from browsing a site

**Given** Alternative design is enabled and the user opened a site from a group's grid or the Sites tab tree
**When** the user taps the browser's grid button
**Then** the previous library view is shown with its selection retained
**And** no drawer opens
**And** opening the site again retains its tab selection

#### Scenario: Navigate back to webspaces list

**Given** the user is viewing sites in a selected webspace
**When** the user opens the drawer
**And** taps "Back to Webspaces"
**Then** the webspaces list is displayed

#### Scenario: Swipe back from a site group

**Given** Alternative design is enabled and the user is viewing a group's sites
**When** the user swipes horizontally in the back direction
**Then** the groups menu appears with the existing closing transition
**And** the search and keyboard are cleared
**And** the selected group and its sites are unchanged

#### Scenario: Scroll or reorder sites in a group

**Given** the user is viewing a group's sites
**When** the user scrolls vertically or long-presses and drags a site
**Then** the group stays open

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
the library site grid in edit mode, the bottom tab strip and the drawer grid. The new order SHALL persist
across app restarts. This reorders the sites *within* the selected view; it
does not move the webspace cards themselves (WEBSPACE-009 still holds — the
"All" webspace card cannot be moved in the webspaces list).

#### Scenario: Reorder sites within a named webspace

**Given** the "Work" webspace is selected with sites [A, B, C] in that order
**When** the user long-presses site C in the tab strip, the drawer grid, or the library site grid in edit mode and drops it onto site A's position
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
**When** the user long-presses that site
**Then** no drag begins (there is nothing to reorder)

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

### Requirement: WEBSPACE-014 - Individual Launcher Item Sizes

With Alternative design enabled, each group and site SHALL offer Small, Medium, and Large icon sizes from its item menu, defaulting to Medium. A size choice SHALL affect only that item, persist with it across restarts, and survive settings export/import. Opening, editing, sizing, and reordering items SHALL NOT require a global edit mode.

#### Scenario: Resize one item

**Given** two groups and two sites use Medium icons
**When** the user chooses Large from one group's Item size menu and Small from one site's Item size menu
**Then** only those two icons change size
**And** their choices survive saving and restoring the items

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
