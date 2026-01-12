# Webspace Implementation - Edge Cases Testing

## Test Coverage

### 1. Serialization Tests ✓
- [x] Empty webspace serialization
- [x] Webspace with sites serialization
- [x] JSON round-trip (serialize → deserialize)
- [x] Multiple webspaces serialization
- [x] Special characters in names
- [x] Unicode characters in names
- [x] Large site indices list (100+ items)
- [x] Duplicate indices preservation
- [x] Negative indices preservation

### 2. Empty State Tests
- [x] No webspaces created yet
  - Shows "No webspaces yet. Create one to organize your sites."
  - "Create Webspace" button available

- [x] Webspace with no sites
  - Can be created and saved
  - Shows "No sites in this webspace" in drawer
  - Selecting it shows empty drawer with message

- [x] No sites at all in app
  - Can still create webspaces
  - Webspace detail screen shows "No sites available. Add sites first."

### 3. Deletion Edge Cases
- [x] Delete currently selected webspace
  - `_selectedWebspaceId` set to null
  - `_currentIndex` set to null
  - Returns to webspaces list screen
  - Saves state properly

- [x] Delete site that's in multiple webspaces
  - Updates all affected webspaces
  - Removes the site index from all webspaces
  - Adjusts higher indices downward
  - Saves updated webspaces

- [x] Delete site that's in currently selected webspace
  - Index cleanup happens automatically
  - Webspace remains selected
  - Filtered indices updated

### 4. State Management Tests
- [x] Selected webspace visualization
  - Green highlight on selected card
  - Check icon shown
  - Bold text for selected name
  - Higher elevation

- [x] Saving and loading webspace selection
  - Selected webspace ID persisted
  - Restored on app restart
  - Validated against available webspaces

- [x] Invalid saved state handling
  - If saved webspace ID doesn't exist: deselect
  - If saved site index out of bounds: set to null
  - Cleanup invalid indices automatically

### 5. UI/UX Edge Cases
- [x] Back to webspaces button
  - Clears selection
  - Returns to webspaces list
  - Closes drawer
  - Saves state

- [x] Drawer shows filtered sites only
  - Only sites in selected webspace visible
  - Out-of-bounds indices filtered
  - Empty webspace shows message

- [x] Webspace with all sites deleted
  - Webspace remains valid
  - Shows "No sites in this webspace"
  - Can add sites later via detail screen

### 6. Data Consistency Tests
- [x] Site indices cleanup after deletion
  - Removes deleted index
  - Shifts down higher indices
  - Updates all webspaces
  - Saves changes

- [x] Webspace indices validation
  - `_getFilteredSiteIndices()` filters invalid indices
  - Out-of-bounds indices ignored
  - Negative indices ignored

- [x] Multiple webspace operations
  - Can create multiple webspaces
  - Each has unique UUID
  - All persist independently
  - Selection state maintained

### 7. Navigation Edge Cases
- [x] Selecting webspace when none selected
  - Sets `_selectedWebspaceId`
  - Clears `_currentIndex`
  - Shows drawer with filtered sites

- [x] Selecting same webspace again
  - No error
  - Remains selected
  - UI consistent

- [x] Edit webspace while selected
  - Changes reflected immediately
  - Selection maintained
  - Filtered sites update if changed

### 8. Concurrent Operations
- [x] Add site while webspace selected
  - New site not automatically added to webspace
  - Must explicitly add via detail screen
  - Prevents accidental associations

- [x] Reorder sites (disabled in webspace view)
  - Complex index mapping avoided
  - Prevents data corruption
  - Can reorder when no webspace selected

### 9. Theme and Display
- [x] "No webspace selected" shown
  - Clear messaging on main screen
  - "Select Webspace" title
  - Workspace icon used

- [x] Drawer icon changed
  - Icons.workspaces instead of menu_book
  - Consistent branding

### 10. Persistence Edge Cases
- [x] Fresh app start (no saved data)
  - Empty webspaces list loads
  - No selected webspace
  - Shows webspaces screen

- [x] App restart with saved data
  - Webspaces restored from SharedPreferences
  - Selected webspace restored
  - Site indices validated

- [x] Corrupted save data handling
  - JSON decode errors caught (implicit)
  - Invalid webspace IDs handled
  - App doesn't crash

## Code Review - Key Safety Features

### `_cleanupWebspaceIndices()`
Ensures all webspace indices are valid after changes.

### `_getFilteredSiteIndices()`
Returns only valid indices for current webspace:
```dart
return webspace.siteIndices
    .where((index) => index >= 0 && index < _webViewModels.length)
    .toList();
```

### Site Deletion Handler
Updates all webspaces when a site is deleted:
```dart
for (var webspace in _webspaces) {
  webspace.siteIndices = webspace.siteIndices
      .where((i) => i != index)
      .map((i) => i > index ? i - 1 : i)
      .toList();
}
```

### Webspace Deletion Handler
Properly clears selection if deleted webspace was selected:
```dart
if (_selectedWebspaceId == webspace.id) {
  _selectedWebspaceId = null;
  _currentIndex = null;
}
```

### State Restoration
Validates indices on app start:
```dart
if (_selectedWebspaceId != null) {
  final filteredIndices = _getFilteredSiteIndices();
  if (filteredIndices.contains(savedIndex)) {
    _currentIndex = savedIndex;
  } else {
    _currentIndex = null;
  }
}
```

## All Edge Cases Handled ✓

The implementation properly handles:
- Empty states at all levels
- Invalid data scenarios
- Concurrent operations
- State persistence and restoration
- UI consistency
- Data integrity

## 11. Webspace Reordering Tests (webspace_ordering_test.dart)

### Order Preservation
- [x] Webspace order preserved after JSON serialization
  - Serialize webspaces in specific order
  - Deserialize and verify order matches
  - Simulates SharedPreferences save/load cycle

### Reordering Logic
- [x] Reordering correctly applies Flutter's ReorderableList logic
  - Move webspace from one position to another
  - Handle newIndex adjustment when moving down
  - Verify all webspaces end up in correct positions

### "All" Webspace Protection
- [x] Cannot reorder "All" webspace from position 0
  - Guard condition blocks oldIndex == 0
  - "All" always stays at top

- [x] Cannot reorder other webspaces to position 0
  - Guard condition blocks newIndex == 0
  - Prevents any webspace from taking "All"'s position

### Multiple Operations
- [x] Multiple reorder operations maintain consistency
  - Perform several reorder operations in sequence
  - Verify final order is correct
  - Verify "All" never moves

### Round-Trip Testing
- [x] Reordering + serialization preserves new order
  - Reorder webspaces
  - Serialize to JSON
  - Deserialize from JSON
  - Verify order persists through full cycle

## 12. UI/UX Edge Cases (Recent Fixes)

### AppBar Title Display
- [x] Shows webspace name when no site selected
  - AppBar title displays selected webspace name
  - Falls back to "No Webspace Selected" if null
  - Previously showed "No Site Selected" incorrectly

### Card Width with Reordering
- [x] Cards properly sized with reorder handle
  - Compact icon buttons (40x40 with zero padding)
  - Fixed width: 40px for "All", 80px for others
  - ReorderableListView drag handle doesn't overlap content

### Drawer Header Consistency
- [x] Always shows current webspace name
  - No longer conditionally hidden
  - Shows "No webspace" if null (shouldn't happen)
  - "Back to Webspaces" selects "All" instead of clearing

No known edge cases remain unhandled.
