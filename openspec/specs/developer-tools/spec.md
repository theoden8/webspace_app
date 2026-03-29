# Developer Tools

## Status
**Implemented**

## Purpose

Provide in-app debugging tools for inspecting site behavior: viewing JS console output, inspecting cookies with security flags, exporting page HTML, and accessing app-level logs for GitHub issue reporting.

## Problem Statement

There is no way to see JS console messages, inspect cookies, or export diagnostic information from within the app. Users debugging site issues or reporting bugs must rely on external tools or guesswork.

---

## Requirements

### Requirement: DEVTOOLS-001 - JS Console Log Capture

The app SHALL capture JS console messages (log, warn, error) from webviews and display them in the Console tab.

#### Scenario: View console messages

**Given** a site is loaded and produces JS console output
**When** the user opens Developer Tools
**Then** the Console tab shows timestamped, color-coded messages
**And** warnings are amber and errors are red

#### Scenario: Clear and copy console

**Given** the Console tab has messages
**When** the user taps "Clear"
**Then** all console messages are removed
**When** the user taps "Copy All"
**Then** all messages are copied to clipboard as formatted text

---

### Requirement: DEVTOOLS-002 - Cookie Inspector

The app SHALL display cookies for the current site with security flag details.

#### Scenario: View cookies with security flags

**Given** a site is loaded with cookies
**When** the user opens the Cookies tab
**Then** each cookie shows name and truncated value
**And** expanding a cookie shows domain, path, expiry, and security chips:
  - `isSecure` as green "Secure" or red "Not Secure"
  - `isHttpOnly` as green "HttpOnly" chip (only if true)
  - `sameSite` as colored chip (Strict=green, Lax=blue, None=amber)

#### Scenario: Delete a cookie

**Given** the Cookies tab shows cookies
**When** the user expands a cookie and taps "Delete"
**Then** the cookie is removed from the CookieManager
**And** the cookie list refreshes

#### Scenario: Refresh and copy cookies

**Given** the Cookies tab is open
**When** the user taps "Refresh"
**Then** cookies are re-fetched from CookieManager
**When** the user taps "Copy as JSON"
**Then** all cookies are copied to clipboard as formatted JSON

---

### Requirement: DEVTOOLS-003 - HTML Export

The app SHALL allow exporting the current page's HTML source.

#### Scenario: Export HTML to file

**Given** a site is loaded
**When** the user taps "Export HTML" in the Export tab
**Then** the page HTML is retrieved via `controller.getHtml()`
**And** a file save dialog appears with filename `{domain}_{timestamp}.html`

#### Scenario: Copy HTML to clipboard

**Given** HTML has been loaded in the Export tab
**When** the user taps "Copy to Clipboard"
**Then** the full HTML is copied to clipboard

#### Scenario: Preview HTML

**Given** HTML has been loaded
**Then** the first 200 lines are shown in monospace SelectableText

---

### Requirement: DEVTOOLS-004 - App Logs

The app SHALL maintain a ring buffer of app-level log entries accessible from both Developer Tools and App Settings, with live streaming updates and auto-scroll.

#### Scenario: View app logs

**Given** the app has been running and logging
**When** the user opens the App Logs tab
**Then** timestamped log entries are shown with tag and message
**And** the view scrolls to the bottom to show the most recent entries
**And** filter chips allow filtering by level (debug, info, warning, error)

#### Scenario: Live log streaming

**Given** the App Logs tab is open
**When** new log entries are produced by the app
**Then** they appear in the list in real time without manual refresh
**And** if the user is scrolled to the bottom, the view auto-scrolls to show new entries

#### Scenario: Auto-scroll pause on manual scroll

**Given** the App Logs tab is open and auto-scrolling
**When** the user scrolls up to view older entries
**Then** auto-scroll is paused so the view does not jump
**When** the user scrolls back to the bottom
**Then** auto-scroll resumes

#### Scenario: Export logs for issue reporting

**Given** the App Logs tab has entries
**When** the user taps "Export"
**Then** logs are saved as a .txt file via file picker
**When** the user taps "Copy"
**Then** logs are copied to clipboard for pasting into GitHub issues

#### Scenario: Access from App Settings

**Given** no site is loaded
**When** the user opens App Settings and taps "App Logs"
**Then** DevToolsScreen opens with only the App Logs tab visible

---

### Requirement: DEVTOOLS-005 - LogService

The app SHALL use a centralized LogService singleton (extending ChangeNotifier) for all debug logging, notifying listeners on each new entry.

#### Scenario: Ring buffer behavior

**Given** LogService has reached maxEntries (2000)
**When** a new entry is logged
**Then** the oldest entry is removed

#### Scenario: Debug mode passthrough

**Given** the app is running in debug mode
**When** a log entry is created
**Then** it is also printed via debugPrint

#### Scenario: Change notification

**Given** a UI widget is listening to LogService
**When** a new log entry is added or logs are cleared
**Then** LogService notifies all listeners so the UI updates in real time

---

## Implementation Details

### Files

| File | Role |
|------|------|
| `lib/services/log_service.dart` | LogService singleton, LogEntry, LogLevel enum |
| `lib/screens/dev_tools.dart` | DevToolsScreen with 4 tabs (Console, Cookies, Export, App Logs) |

### Data Models

```dart
enum LogLevel { debug, info, warning, error }

class LogEntry {
  final DateTime timestamp;
  final String tag;
  final String message;
  final LogLevel level;
}

class ConsoleLogEntry {
  final DateTime timestamp;
  final String message;
  final ConsoleMessageLevel level;  // from flutter_inappwebview
}
```

### Integration Points

- `WebViewConfig.onConsoleMessage` callback wired in `WebViewFactory.createWebView()`
- `WebViewModel.consoleLogs` list (max 500 entries)
- All service files use `LogService.instance.log()` instead of `debugPrint()`
- Popup menu "Developer Tools" item in `main.dart`
- "App Logs" tile in App Settings screen

---

## Manual Test Procedure

1. Open a site that produces JS console output (e.g., any site with analytics)
2. Three-dot menu -> Developer Tools
3. **Console tab**: verify messages appear color-coded with timestamps
4. **Cookies tab**: verify cookies listed with security chips; delete a cookie and confirm removal
5. **Export tab**: tap "Export HTML", verify file save dialog and preview
6. **App Logs tab**: verify app log entries appear; use filter chips; tap "Copy" and paste
7. Go back, open App Settings -> App Logs: verify it works without a site loaded
