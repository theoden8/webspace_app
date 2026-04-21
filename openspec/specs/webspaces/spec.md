# Webspaces Feature Specification

## Purpose

The Webspaces feature allows users to organize their saved sites into separate workspaces, enabling better organization and context switching between different browsing contexts (e.g., Work, Personal, Research).

## Status

- **Implementation Date**: 2026-01-12
- **Status**: Completed

---

## Requirements

### Requirement: WEBSPACE-001 - Create Multiple Webspaces

Users SHALL be able to create multiple webspaces to organize sites into logical groups.

#### Scenario: Create a new webspace

**Given** the user is on the webspaces list screen
**When** the user taps "Create Webspace"
**And** enters a name (e.g., "Work")
**And** selects sites to include
**And** taps the checkmark icon
**Then** a new webspace is created with the specified name and sites

---

### Requirement: WEBSPACE-002 - Select Active Webspace

Users SHALL be able to select and switch between webspaces to view filtered sites.

#### Scenario: Select a webspace

**Given** the user is viewing the webspaces list
**When** the user taps on a webspace card
**Then** that webspace becomes selected
**And** the drawer shows only sites belonging to that webspace

---

### Requirement: WEBSPACE-003 - Visual Selection Indicator

The system SHALL provide clear visual indication of which webspace is currently active.

#### Scenario: Display selected webspace indicator

**Given** a webspace is selected
**When** the user views the webspaces list
**Then** the selected webspace displays:
- Green highlighted background
- Check icon next to the name
- Bold text
- Higher card elevation

---

### Requirement: WEBSPACE-004 - Filtered Drawer Navigation

The drawer SHALL only show sites belonging to the currently selected webspace.

#### Scenario: Filter drawer by webspace

**Given** the user has selected the "Work" webspace
**And** "Work" contains sites A and B
**And** "Personal" contains site C
**When** the user opens the drawer
**Then** only sites A and B are displayed
**And** site C is not visible

---

### Requirement: WEBSPACE-005 - Persistent State

Webspaces and selection state SHALL persist across app restarts.

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
**When** the user taps the edit icon on the webspace card
**And** adds site C and removes site A
**And** saves changes
**Then** "Work" now contains sites B and C

---

### Requirement: WEBSPACE-007 - Delete Webspace

Users SHALL be able to delete webspaces.

#### Scenario: Delete a webspace

**Given** webspaces "Work" and "Personal" exist
**And** "Work" is currently selected
**When** the user taps delete on "Work"
**And** confirms the deletion
**Then** "Work" is removed
**And** selection is cleared
**And** user returns to webspaces list

---

### Requirement: WEBSPACE-008 - Back to Webspaces Navigation

Users SHALL be able to return to the webspaces list from the drawer.

#### Scenario: Navigate back to webspaces list

**Given** the user is viewing sites in a selected webspace
**When** the user opens the drawer
**And** taps "Back to Webspaces"
**Then** the webspaces list is displayed

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
  - `indicesToUnloadOnWebspaceSwitch({loadedIndices, previousWebspaceIndices,
    newWebspaceIndices})` — returns the loaded sites that leave the
    visible set on a webspace switch. The offline short-circuit
    (preserve-all-loaded when disconnected) is a policy decision owned
    by the caller, not the engine.
  - `cleanupWebspaceIndices({webspaces, siteCount})` — strips
    out-of-bounds entries in place.
- [`SiteLifecycleEngine.computeDeletionPatch`](../../../lib/services/site_lifecycle_engine.dart)
  — returns the rewritten `siteIndices` for every affected webspace
  when a site is removed from `_webViewModels`, implementing
  WEBSPACE-010. The rewrite drops the deleted index and shifts every
  `i > deletedIndex` down by one.

Tests live in [test/webspace_selection_engine_test.dart](../../../test/webspace_selection_engine_test.dart)
and [test/site_lifecycle_engine_test.dart](../../../test/site_lifecycle_engine_test.dart).

---

## Files

### Created
- `lib/webspace_model.dart` - Webspace data model
- `lib/screens/webspaces_list.dart` - Main webspaces screen
- `lib/screens/webspace_detail.dart` - Edit webspace screen
- `lib/services/webspace_selection_engine.dart` - Filter + unload-on-switch logic
- `lib/services/site_lifecycle_engine.dart` - Deletion-patch index rewrite
- `test/webspace_model_test.dart` - Unit tests
- `test/webspace_selection_engine_test.dart` - Selection/unload/cleanup tests
- `test/site_lifecycle_engine_test.dart` - Deletion patch tests

### Modified
- `lib/main.dart` - Webspace state management and UI integration
- `pubspec.yaml` - Added `uuid: ^4.5.1` dependency
