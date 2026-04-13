# Magnet Link Support

## ADDED Requirements

### Requirement: MAGNET-001 - Intercept Magnet Links in Navigation

The `shouldOverrideUrlLoading` callback SHALL detect `magnet:` URIs, prevent them from loading in the webview, and dispatch them to an external handler via the platform's URL launcher.

#### Scenario: Click magnet link on a page

**Given** a page is loaded that contains a `magnet:` link
**When** the user clicks the magnet link
**Then** the webview does NOT navigate to the `magnet:` URI
**And** the URI is passed to the platform's URL launcher
**And** the user's torrent client opens with the magnet link

---

### Requirement: MAGNET-002 - Handle Missing External Handler

If no external app is registered to handle `magnet:` URIs, the system SHALL show a user-friendly error message.

#### Scenario: No torrent client installed

**Given** no app on the device handles `magnet:` URIs
**When** the user clicks a magnet link
**Then** a snackbar is shown: "No app found to handle magnet links"
**And** navigation is cancelled

---

### Requirement: MAGNET-003 - Confirmation for Script-Initiated Navigation

The system SHALL show a confirmation dialog before launching an external app for script-initiated `magnet:` navigations (no user gesture), but SHALL open directly for user-gesture links.

#### Scenario: Script-initiated magnet navigation

**Given** a page script triggers a `magnet:` URI navigation without user gesture
**When** the navigation is intercepted
**Then** a confirmation dialog is shown: "Open magnet link in external app?"
**And** the user can confirm or cancel

#### Scenario: User-gesture magnet link

**Given** the user directly taps a visible magnet link
**When** the link is intercepted
**Then** the link is opened directly without a confirmation dialog

---

### Requirement: MAGNET-004 - Nested Webview Support

Magnet links clicked inside nested InAppBrowser webviews SHALL also be intercepted and handed off to external apps.

#### Scenario: Magnet link in nested webview

**Given** a nested InAppBrowser webview is open
**When** the user clicks a magnet link within it
**Then** the magnet link is dispatched to the external handler
**And** the nested webview remains open

---

### Requirement: MAGNET-005 - Reject Magnet as Site URL

The system SHALL NOT allow `magnet:` URIs as site URLs in Add Site, URL bar, or site editing.

#### Scenario: Attempt to add magnet as site

**Given** the user is on the Add Site screen
**When** the user pastes a `magnet:?xt=urn:btih:...` URI
**Then** an error is shown explaining magnet links cannot be added as sites
**And** the site is not created
