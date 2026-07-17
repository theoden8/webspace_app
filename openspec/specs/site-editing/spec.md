# Site Editing & Page Title Display Specification

## Purpose

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

### Requirement: EDIT-008 - Custom Site Icon

Users SHALL be able to override a site's automatically fetched favicon with an
image of their own from the edit dialog, and revert to the automatic icon later.

The chosen image is normalized to PNG with a longest side of at most 256px and
stored inline on the site model (`WebViewModel.customIconPng`, base64 in JSON).
Because it lives in the model JSON it automatically rides settings backups, and
for archive-tier sites it is persisted only inside the encrypted archive slice —
no per-`siteId` plaintext file is written (ARCH-006 audit: no disk, background
scheduling, or OS-UI surface beyond the existing home-shortcut path). The field
is excluded from the QR share payload (`SiteSettingsQrCodec.excludedKeys`):
image bytes would blow QR capacity and an icon is device-local cosmetics.

#### Scenario: Set a custom icon

**Given** a site whose URL yields no favicon (or an unwanted one)
**When** the user opens the edit dialog, taps "Change icon", and picks a raster
image (PNG/JPEG/WebP/GIF/BMP/ICO)
**And** saves
**Then** the chosen image is shown for that site everywhere the site icon
renders (drawer list/grid, tab strip, webspace detail, site dispatch)
**And** no favicon fetch is performed for those renders
**And** the icon persists across app restarts

#### Scenario: Custom icon feeds home shortcuts

**Given** a site with a custom icon
**When** the user pins the site to the Android home screen
**Then** the pinned shortcut uses the custom icon bytes instead of the fetched
favicon

#### Scenario: Revert to the automatic icon

**Given** a site with a custom icon
**When** the user opens the edit dialog and taps the reset button
**And** saves
**Then** the custom icon is removed
**And** the automatically fetched favicon (icon-fetching spec) is displayed again

#### Scenario: Undecodable image is rejected

**Given** the user picks a file that is not a decodable raster image
**When** processing runs
**Then** the site's icon is left unchanged
**And** a snackbar explains the file could not be read

---

### Requirement: EDIT-009 - Unsaved Site Settings Warn Before Discard

The per-site settings screen SHALL NOT silently discard unsaved edits. It
SHALL compare the live form against a snapshot captured when the screen
opened (and re-captured after each successful save), and when any field
differs it SHALL intercept every route-leaving affordance (system back,
app-bar back, iOS edge swipe) with a confirmation dialog offering "Keep
editing" and "Discard".

Every form field assigned in `_loadFromModel` MUST be registered in the
`_currentSnapshot` map, except fields fully derived from an
already-registered field. This registration is enforced structurally by
`test/js/site_settings_dirty_snapshot.test.js` (runs in CI via
`npm run test:js`); a derived-field exemption lives in that test's
allowlist with a written justification.

History: [docs/bugs/006-settings-silent-discard.md](../../../docs/bugs/006-settings-silent-discard.md).

#### Scenario: Leaving with an unsaved change prompts

**Given** the site settings screen is open
**When** the user changes any setting (e.g. flips the Kiosk Mode toggle)
**And** triggers back without saving
**Then** a "Discard changes?" dialog appears
**And** "Keep editing" returns to the form with the edit intact
**And** "Discard" leaves the screen without applying the edit

#### Scenario: Leaving with no changes does not prompt

**Given** the site settings screen is open
**When** the user triggers back without editing anything (or after a save)
**Then** the screen pops immediately with no dialog

#### Scenario: New form field is dirty-tracked (regression BUG-006)

**Given** a developer adds a new per-site setting to the settings form,
loading it in `_loadFromModel`
**When** the field is not registered in `_currentSnapshot` (and not
allowlisted as derived)
**Then** `test/js/site_settings_dirty_snapshot.test.js` fails CI naming the
field

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
