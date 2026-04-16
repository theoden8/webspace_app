# Developer Tools

## Status
**Implemented**

## Purpose

Provide in-app debugging tools for inspecting site behavior: viewing JS console output, inspecting cookies with security flags, sharing/exporting page HTML, viewing active user scripts, and accessing app-level logs for GitHub issue reporting.

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
**When** the user taps "Copy"
**Then** only the currently visible (filtered) messages are copied to clipboard as formatted text
**And** the snackbar shows the count of copied entries

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
**Then** only the currently visible (filtered) cookies are copied to clipboard as formatted JSON
**And** the snackbar shows the count of copied cookies

#### Scenario: Block a cookie

**Given** the Cookies tab shows cookies
**When** the user expands a cookie and taps "Block"
**Then** a `BlockedCookie(name, domain)` rule is added to the site's `blockedCookies`
**And** the cookie is immediately deleted from CookieManager
**And** the block rule is persisted
**And** the cookie will be removed on every subsequent page load

#### Scenario: Unblock a cookie

**Given** the Blocked section at the top of the Cookies tab lists blocked rules
**When** the user taps "Unblock" on a rule
**Then** the `BlockedCookie` is removed from the set
**And** the website can set the cookie again on next page load

---

### Requirement: DEVTOOLS-003 - Share HTML

The app SHALL allow sharing, saving, or copying the current page's HTML source via an AppBar action button.

#### Scenario: Share HTML via OS share sheet

**Given** a site is loaded
**When** the user taps the share icon in the AppBar and selects "Share HTML"
**Then** the page HTML is retrieved via `controller.getHtml()`
**And** the OS share sheet opens with the HTML content

#### Scenario: Save HTML to file

**Given** a site is loaded
**When** the user taps the share icon and selects "Save to file"
**Then** a file save dialog appears with filename `{domain}_{timestamp}.html`

#### Scenario: Copy HTML to clipboard

**Given** a site is loaded
**When** the user taps the share icon and selects "Copy to clipboard"
**Then** the full HTML is copied to clipboard

#### Scenario: Concurrent fetch guard

**Given** an HTML fetch is already in progress
**When** another share/save/copy action is triggered
**Then** the second action reuses the cached HTML rather than starting a concurrent fetch

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
**Then** all logs are saved as a .txt file via file picker (ignoring filters)
**When** the user taps "Copy"
**Then** only the currently visible (filtered by level chips and search query) log entries are copied to clipboard
**And** the snackbar shows the count of copied entries

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

### Requirement: DEVTOOLS-006 - Scripts Viewer

The app SHALL show active user scripts for the current site via an AppBar action button that opens a bottom sheet.

#### Scenario: View scripts

**Given** a site is loaded with user scripts configured
**When** the user taps the code icon in the AppBar
**Then** a draggable bottom sheet opens showing script count and a list of scripts
**And** each script shows its name, enabled/disabled status, and injection time

#### Scenario: Expand and copy script source

**Given** the scripts bottom sheet is open
**When** the user taps a script entry
**Then** the script source is shown in monospace text
**And** a copy button allows copying the source to clipboard

#### Scenario: No scripts configured

**Given** a site has no user scripts
**When** the user taps the code icon
**Then** the bottom sheet shows "No user scripts configured"

---

### Requirement: DEVTOOLS-007 - Console Eval

The app SHALL provide a JavaScript evaluation input in the Console tab, allowing users to execute arbitrary JS in the context of the current page and see results inline, like a standard browser console.

#### Scenario: Evaluate a JavaScript expression

**Given** a site is loaded and the Console tab is open
**When** the user types a JS expression (e.g. `document.title`) in the eval input and taps Run or presses Enter
**Then** the input is shown in the console log as `> document.title` in bold primary color
**And** the expression is evaluated via `eval()` in the page context
**And** the result is output via `console.log()` (or `console.error()` on exception)
**And** the result appears in the console log below the input

#### Scenario: Error handling

**Given** the eval input contains invalid JavaScript
**When** the user submits it
**Then** the error message is shown as a red console error entry

#### Scenario: Command history

**Given** the user has previously evaluated one or more commands
**When** the user taps the up arrow button
**Then** the previous command is loaded into the input field
**When** the user taps the down arrow button
**Then** the next command is loaded, or the input is cleared at the end of history

#### Scenario: Eval disabled without controller

**Given** the webview controller is not available (site not loaded)
**When** the Console tab is shown
**Then** the eval input is disabled and the prompt is dimmed

---

## Implementation Details

### Files

| File | Role |
|------|------|
| `lib/services/log_service.dart` | LogService singleton, LogEntry, LogLevel enum |
| `lib/screens/dev_tools.dart` | DevToolsScreen with 3 tabs (Console, Cookies, App Logs) and AppBar actions (Scripts, Share HTML, Search) |

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
5. **Share HTML** (AppBar share icon): tap and verify bottom sheet with Share/Save/Copy options; test each option
6. **Scripts** (AppBar code icon): tap and verify bottom sheet shows user scripts (or "no scripts" message); expand a script and copy its source
7. **App Logs tab**: verify app log entries appear; use filter chips; tap "Copy" and paste — verify only filtered entries are copied
8. **Filtered copy**: on each tab, enter a search query, tap Copy, and verify clipboard contains only the matching entries (not all)
9. Go back, open App Settings -> App Logs: verify it works without a site loaded (share and scripts icons should not appear)
