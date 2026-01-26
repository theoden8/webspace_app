# Site Editing & Page Title Display Specification

## Overview

Users can edit site details and see automatic page title extraction instead of just URLs/domains.

## Status

- **Status**: Completed

---

## Requirements

### Requirement: EDIT-001 - Automatic Page Title Display

The system SHALL display page titles with the following priority:

1. Page title (from HTML `<title>` tag)
2. Custom name (user-edited)
3. Domain (extracted from URL)

#### Scenario: Display page title from HTML

**Given** a site is loaded with HTML `<title>Example Portal</title>`
**When** the page finishes loading
**Then** "Example Portal" is displayed in the app bar
**And** "Example Portal" is displayed in the drawer

---

### Requirement: EDIT-002 - Title Display Locations

Page titles SHALL be displayed in:
- App bar (top of screen)
- Drawer list items
- Settings screen

#### Scenario: Show title in multiple locations

**Given** a site has page title "My Dashboard"
**When** the user views the app
**Then** "My Dashboard" appears in the app bar
**And** "My Dashboard" appears in the drawer list

---

### Requirement: EDIT-003 - Site Name Editing

Users SHALL be able to edit the site name (custom display name).

#### Scenario: Set custom site name

**Given** a site shows page title "Example Portal"
**When** the user opens the edit dialog
**And** changes the name to "Work Portal"
**And** saves
**Then** "Work Portal" is displayed instead of "Example Portal"

---

### Requirement: EDIT-004 - URL Editing

Users SHALL be able to edit the site URL.

#### Scenario: Change site URL

**Given** a site is configured with "https://example.com"
**When** the user opens the edit dialog
**And** changes the URL to "https://newsite.com"
**And** saves
**Then** the webview reloads with the new URL

---

### Requirement: EDIT-005 - Protocol Inference

The system SHALL infer HTTPS protocol when not explicitly specified.

#### Scenario: Infer HTTPS for URL without protocol

**Given** the user enters "example.com:8080" in the URL field
**When** the user saves the edit
**Then** the URL is interpreted as "https://example.com:8080"

#### Scenario: Preserve explicit HTTP protocol

**Given** the user enters "http://example.com"
**When** the user saves the edit
**Then** the URL remains "http://example.com"

---

### Requirement: EDIT-006 - Edit Access Points

Users SHALL be able to access the edit dialog from:
1. Clicking the title in the app bar
2. Clicking the edit icon in the drawer

#### Scenario: Open edit from app bar

**Given** a site is displayed
**When** the user taps the title in the app bar
**Then** the edit dialog opens

---

### Requirement: EDIT-007 - Title Persistence

Page titles SHALL persist across app restarts.

#### Scenario: Restore page title on restart

**Given** a site has page title "My Dashboard"
**When** the app is closed and reopened
**Then** "My Dashboard" is still displayed for that site

---

## Data Model

```dart
class WebViewModel {
  String name;         // Display name (auto-updated from title)
  String? pageTitle;   // Cached page title
  String initUrl;      // Site URL (now editable)

  String getDisplayName() {
    return name; // Returns page title if available
  }
}
```

---

## Platform Support

| Feature | Android | Linux |
|---------|---------|-------|
| Page Title Display | Native API | HTML parsing |
| URL Editing | Yes | Yes |
| Protocol Inference | Yes | Yes |
| Title Persistence | Yes | Yes |
| Click-to-Edit | Yes | Yes |

---

## Files

### Modified
- `lib/web_view_model.dart` - Added pageTitle field, made initUrl editable
- `lib/platform/webview_factory.dart` - Added getTitle() to controller
- `lib/main.dart` - Edit dialog, app bar click handling
