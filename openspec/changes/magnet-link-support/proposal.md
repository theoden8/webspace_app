# Change: Magnet Link Support

## Summary

Add `magnet:` URI handling so that when a user clicks a magnet link on any page loaded in WebSpace, the link is handed off to an external torrent client (or other registered handler) via the platform's intent/URL launching system. WebSpace does not download torrents itself — it delegates to the user's preferred app.

## Motivation

Magnet links are common on many websites (Linux distro downloads, open-source software, legal file sharing). Currently, clicking a `magnet:` link in WebSpace either does nothing or gets blocked by the navigation interceptor. Proper handling means recognizing the scheme and dispatching it to an external app — a small change with high usability impact.

## Approach: External App Delegation

Intercept `magnet:` URIs in the navigation interceptor and hand them off to the platform's URL launcher (`url_launcher` package, already a dependency). This is the same pattern browsers use — no torrent logic in the app itself.

### Platform Behavior

| Platform | Behavior |
|----------|----------|
| Android | `ACTION_VIEW` intent with `magnet:` URI → opens registered torrent app (e.g., LibreTorrent, Flud, Transmission) |
| iOS | `canLaunchUrl` check → open if handler registered; show error if not |
| macOS | `NSWorkspace.open` → opens registered handler (e.g., Transmission, qBittorrent) |
| Linux | `xdg-open` → opens registered handler |

## Requirements

### REQ-MAGNET-001: Intercept Magnet Links in Navigation

The `shouldOverrideUrlLoading` callback SHALL detect `magnet:` URIs and prevent them from loading in the webview. Instead, the URI SHALL be dispatched to an external handler.

#### Scenario: Click magnet link on a page

**Given** a page is loaded that contains a `magnet:` link
**When** the user clicks the magnet link
**Then** the webview does NOT navigate to the `magnet:` URI
**And** the URI is passed to the platform's URL launcher
**And** the user's torrent client opens with the magnet link

### REQ-MAGNET-002: Handle Missing External Handler

If no external app is registered to handle `magnet:` URIs, the system SHALL show a user-friendly error message.

#### Scenario: No torrent client installed

**Given** no app on the device handles `magnet:` URIs
**When** the user clicks a magnet link
**Then** a snackbar or dialog is shown: "No app found to handle magnet links. Install a torrent client to open this link."
**And** navigation is cancelled

### REQ-MAGNET-003: Confirmation Before Launch (Optional)

The system SHOULD show a brief confirmation before launching the external app, to prevent accidental or malicious magnet link triggers (e.g., from auto-redirect scripts).

#### Scenario: Confirm external launch

**Given** a page triggers a `magnet:` URI navigation
**When** the navigation is intercepted
**Then** a dialog is shown: "Open magnet link in external app?" with the truncated magnet hash
**And** the user can confirm or cancel

#### Scenario: Skip confirmation for user-gesture links

**Given** the user directly taps a visible magnet link (has gesture context)
**When** the link is intercepted
**Then** the link is opened directly without confirmation dialog
**And** the confirmation is only shown for script-initiated navigations

### REQ-MAGNET-004: Nested Webview Magnet Links

Magnet links clicked inside nested InAppBrowser webviews SHALL also be intercepted and handed off to external apps, not just the main webview.

#### Scenario: Magnet link in nested webview

**Given** a nested InAppBrowser webview is open
**When** the user clicks a magnet link within it
**Then** the magnet link is dispatched to the external handler
**And** the nested webview remains open

### REQ-MAGNET-005: Do Not Treat Magnet as a Site URL

The system SHALL NOT allow `magnet:` URIs as site URLs:
- Add Site screen SHALL reject `magnet:` input with a helpful message
- URL bar SHALL not submit `magnet:` URIs as navigation targets
- Site editing SHALL not accept `magnet:` URIs

#### Scenario: Attempt to add magnet as site

**Given** the user is on the Add Site screen
**When** the user pastes a `magnet:?xt=urn:btih:...` URI
**Then** an error is shown: "Magnet links can't be added as sites. They'll be opened in your torrent client when clicked on any page."

## Affected Files

| File | Change |
|------|--------|
| `lib/services/webview.dart` | Intercept `magnet:` in `shouldOverrideUrlLoading`; launch externally |
| `lib/screens/inappbrowser.dart` | Same interception for nested webviews |
| `lib/screens/add_site.dart` | Reject `magnet:` URIs with helpful message |
| `lib/widgets/url_bar.dart` | Reject `magnet:` URIs |

## Complexity Assessment

| Component | Effort | Notes |
|-----------|--------|-------|
| Navigation interception | Low | Add scheme check + `launchUrl` call |
| Error handling | Low | Snackbar for missing handler |
| Confirmation dialog | Low | Optional; simple AlertDialog |
| Input rejection | Low | Scheme check in add site / URL bar |
| Nested webview support | Low | Same pattern in `inappbrowser.dart` |

**Overall: Low complexity** — this is the simplest of the three protocol proposals. It's pure delegation with no custom protocol client or content rendering.

## Out of Scope

- Downloading or managing torrents within WebSpace
- Parsing magnet link metadata (name, trackers, file list)
- Displaying torrent information before launching
- Supporting other download-oriented schemes (`ed2k://`, `thunder://`)

## Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| Malicious auto-redirect to magnet | Confirmation dialog for script-initiated navigations |
| Platform doesn't support `canLaunchUrl` for `magnet:` | Fallback: attempt launch and catch error |
| iOS URL scheme restrictions | Add `magnet` to `LSApplicationQueriesSchemes` in `Info.plist` |
