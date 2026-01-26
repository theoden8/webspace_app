# Lazy Webview Loading Specification

## Purpose

Implements lazy loading for webviews to prevent all sites from loading simultaneously when any single site is selected. This improves performance, reduces network usage, and prevents unwanted nested webview dialogs from appearing during normal app usage and screenshot tests.

## Status

- **Branch**: `claude/fix-screenshot-test-webviews-RIAXN`
- **Date**: 2026-01-26
- **Status**: Completed

---

## Problem Statement

The app used an `IndexedStack` widget to manage webviews, which creates ALL child widgets upfront (even though only one is displayed). With 8 demo sites:

1. When selecting DuckDuckGo (index 0), all 8 webviews were created simultaneously
2. All 8 sites would start loading their URLs in the background
3. Background webviews could trigger cross-domain navigations (ads, OAuth redirects, tracking)
4. These navigations would open unexpected nested webview dialogs
5. During screenshot tests, Reddit and Weights & Biases webviews would appear on top of DuckDuckGo

---

## Requirements

### Requirement: LAZY-001 - Track Visited Webviews

The system SHALL track which webview indices have been visited by the user.

#### Scenario: Initialize tracking set

**Given** the app starts fresh
**When** no sites have been selected
**Then** the loaded indices set is empty
**And** no webviews are created

---

### Requirement: LAZY-002 - Create Webviews On-Demand

The system SHALL only create webviews for sites that the user has actually visited.

#### Scenario: First visit to a site

**Given** the user has not visited DuckDuckGo yet
**When** the user taps on DuckDuckGo in the drawer
**Then** the DuckDuckGo index is added to loaded indices
**And** only the DuckDuckGo webview is created
**And** other sites remain as empty placeholders

#### Scenario: Subsequent visits

**Given** the user has previously visited DuckDuckGo and GitHub
**When** the user switches between DuckDuckGo and GitHub
**Then** both webviews exist and preserve their state
**And** other unvisited sites remain as placeholders

---

### Requirement: LAZY-003 - Placeholder Widgets

The system SHALL use lightweight placeholder widgets for unvisited sites.

#### Scenario: Unvisited site in IndexedStack

**Given** the IndexedStack contains 8 sites
**When** only site 0 has been visited
**Then** sites 1-7 render as `SizedBox.shrink()` placeholders
**And** no network requests are made for sites 1-7

---

### Requirement: LAZY-004 - Preserve State on Revisit

The system SHALL preserve webview state (scroll position, form data, cookies) when switching between visited sites.

#### Scenario: Return to previously visited site

**Given** the user visited DuckDuckGo and scrolled down
**When** the user visits GitHub and returns to DuckDuckGo
**Then** DuckDuckGo's scroll position is preserved
**And** no page reload occurs

---

### Requirement: LAZY-005 - Handle Site Deletion

The system SHALL update loaded indices correctly when a site is deleted.

#### Scenario: Delete a site and shift indices

**Given** sites 0, 2, and 5 have been visited
**When** site 1 is deleted
**Then** loaded indices are shifted down (0, 1, 4)
**And** indices >= deleted index are decremented

---

### Requirement: LAZY-006 - Clear State on Import

The system SHALL clear loaded indices when importing settings.

#### Scenario: Import new settings

**Given** the user has visited several sites
**When** settings are imported from a backup
**Then** loaded indices are cleared
**And** new sites start fresh without preloading

---

## Implementation

### Loaded Indices Set

```dart
// Track which webview indices have been loaded (for lazy loading)
// Only webviews in this set will be created - others remain as placeholders
final Set<int> _loadedIndices = {};
```

### Set Current Index Helper

```dart
/// Set the current index and mark it as loaded for lazy webview creation.
/// This ensures only visited webviews are created, not all webviews at once.
void _setCurrentIndex(int? index) {
  _currentIndex = index;
  if (index != null && index >= 0 && index < _webViewModels.length) {
    _loadedIndices.add(index);
  }
}
```

### Lazy IndexedStack

```dart
IndexedStack(
  index: _currentIndex!,
  children: _webViewModels.asMap().entries.map<Widget>((entry) {
    final index = entry.key;
    final webViewModel = entry.value;

    // Only create actual webview if this index has been loaded
    if (!_loadedIndices.contains(index)) {
      return const SizedBox.shrink(); // Placeholder for unvisited sites
    }

    return Column(
      children: [
        // ... FindToolbar, UrlBar (only for current index)
        Expanded(
          child: webViewModel.getWebView(...)
        ),
      ],
    );
  }).toList(),
)
```

### Handle Site Deletion

```dart
// Update _loadedIndices after deletion (shift indices down)
_loadedIndices.remove(index);
_loadedIndices.removeWhere((i) => i >= _webViewModels.length);
final updatedIndices = _loadedIndices
    .map((i) => i > index ? i - 1 : i)
    .toSet();
_loadedIndices.clear();
_loadedIndices.addAll(updatedIndices);
```

---

## Benefits

### Performance
- Only visited sites load their URLs
- Reduced memory usage (fewer active webviews)
- Faster initial site display

### Network
- No background network requests for unvisited sites
- Reduced bandwidth usage
- No unnecessary cookies/tracking from background pages

### User Experience
- No unexpected nested webview popups
- Cleaner screenshot generation
- Sites only load when explicitly selected

### Testing
- Screenshot tests capture intended content
- No interference from background webviews
- Deterministic test behavior

---

## Files

### Modified
- `lib/main.dart`
  - Added `_loadedIndices` Set to `_WebSpacePageState`
  - Added `_setCurrentIndex()` helper method
  - Updated all `_currentIndex` assignments to use helper
  - Modified `IndexedStack` to check `_loadedIndices` before creating widgets
  - Added index shifting logic in site deletion handler
  - Clear `_loadedIndices` on settings import
