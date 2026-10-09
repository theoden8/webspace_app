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

The app SHALL display cookies for the current site with security flag
details, reading from the same jar the WebView itself uses.

#### Scenario: View cookies with security flags

**Given** a site is loaded with cookies
**When** the user opens the Cookies tab
**Then** each cookie shows name and truncated value
**And** expanding a cookie shows domain, path, expiry, and security chips:
  - `isSecure` as green "Secure" or red "Not Secure"
  - `isHttpOnly` as green "HttpOnly" chip (only if true)
  - `sameSite` as colored chip (Strict=green, Lax=blue, None=amber)

#### Scenario: Cookie inspector reads from the right jar

**Given** the app is running in profile mode (`_useProfiles == true`)
**When** the user opens the Cookies tab on Site A
**Then** `_refreshCookies` calls
  `ContainerCookieManager.getCookies(controller: ..., siteId: ..., url: ...)`
  which routes through the patched `inapp.CookieManager`'s
  `webViewController:` parameter
**And** the returned cookies are Site A's per-profile jar
  (`androidx.webkit.Profile.getCookieManager()` on Android, the
  WebView's `WKWebsiteDataStore.httpCookieStore` on iOS / macOS)
**And** the listed cookies match what the page itself sees, NOT the
  global default jar (which in profile mode is unused)

**Given** the app is running in legacy mode (`_useProfiles == false`)
**When** the user opens the Cookies tab on Site A
**Then** `_refreshCookies` calls `cookieManager.getCookies(url: ...)`
**And** the returned cookies come from the global jar — the only
  jar there is in legacy mode

#### Scenario: Delete a cookie

**Given** the Cookies tab shows cookies
**When** the user expands a cookie and taps "Delete"
**Then** the cookie is removed from the cookie jar that backs the
  inspector — `ContainerCookieManager.deleteCookie` in profile mode,
  `cookieManager.deleteCookie` in legacy mode (same branch as
  `_refreshCookies`)
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

### Requirement: DEVTOOLS-009 - Save Icon as PNG

The app SHALL allow saving the current site's favicon as a PNG file via an
AppBar action button, regardless of the source format the site serves.

The icon saved SHALL be the one the drawer shows for the site, taken in the
drawer's order: the user's custom icon, then the page icon the site's webview
produced ([icon-fetching](../icon-fetching/spec.md) ICON-009/013), then the
fetched favicon. `displayedSiteIconAsPng` is that order, shared with the home
shortcut (HS-003).

The favicon SHALL be fetched through the same proxy-aware client as all other
favicon requests (per-site proxy, fail-closed when it cannot be honored), so
the action never leaks the device IP.

Because a site's favicon may be a PNG, an ICO (DuckDuckGo), or an SVG, the
output SHALL always be a valid PNG: raster sources are decoded and re-encoded,
and SVG sources are rasterized.

#### Scenario: Save favicon to a PNG file

**Given** a site is loaded with a resolvable favicon
**And** it has no custom icon and no page icon
**When** the user taps the image icon in the AppBar
**Then** the favicon is resolved (preferring the `FaviconUrlCache` entry for
the site's `initUrl`) and fetched through the site's proxy
**And** it is normalized to PNG bytes
**And** a file save dialog appears with filename `{domain}_icon.png`

#### Scenario: The page icon on screen is the one saved

**Given** Site icons only is on and the drawer shows the PNG icon a GitHub page
declared
**And** `FaviconUrlCache` holds the SVG the home page scrape found
**When** the user saves the icon
**Then** the saved PNG is the drawer's icon
**And** the SVG is not fetched

#### Scenario: SVG favicon is rasterized

**Given** the resolved favicon is an SVG
**When** the user saves it
**Then** the SVG is rasterized to a square PNG before the save dialog appears

#### Scenario: No icon available

**Given** the site has no resolvable favicon (or the proxy fails closed)
**When** the user taps the image icon
**Then** a snackbar reports that no icon is available and no file dialog appears

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

#### Scenario: Copying sensitive entries takes a second confirmation

**Given** the show-sensitive toggle is on and the visible entries include sensitive ones
**When** the user taps "Copy"
**Then** a dialog names how many of them are sensitive and that the clipboard can sync off the device
**When** the user confirms
**Then** every visible entry, sensitive ones included, is copied
**When** the user cancels
**Then** nothing is written to the clipboard

#### Scenario: Sensitive entries never reach a file

**Given** the show-sensitive toggle is on
**When** the user taps "Export"
**Then** the written file carries only non-sensitive entries, whatever the toggle says

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

### Requirement: DEVTOOLS-008 - Nested Webview Developer Tools

The app SHALL allow opening Developer Tools inside an [`InAppWebViewScreen`]
nested webview (the screen that handles cross-domain navigations and
window.open popups), in a reduced "console-only" mode that surfaces the
features that don't depend on per-site state.

The reduced mode SHALL show:

- Console tab (capture, filter, copy, clear, JS eval).
- App Logs tab.
- Share HTML AppBar action.
- Save Icon as PNG AppBar action.

The reduced mode SHALL NOT show Cookies, DNS, or Scripts surfaces. Cookies
and scripts belong to the parent site (the nested webview reuses the
parent's container/jar and `siteId`), so the user manages them from the
parent site's Developer Tools entry.

#### Scenario: Open Developer Tools from a nested webview

**Given** the user has followed an outbound link or opened a popup that
landed in an `InAppWebViewScreen`
**When** the user taps the three-dot menu in the nested screen's AppBar
and selects "Developer Tools"
**Then** `DevToolsScreen` opens with `host: NestedDevToolsHost(...)`
**And** the Console and App Logs tabs are visible
**And** the Cookies, DNS, and Scripts surfaces are hidden

#### Scenario: Console captures messages from the nested page

**Given** Developer Tools is open over a nested webview
**When** the nested page produces a `console.log`/`warn`/`error`
**Then** the message is delivered through `WebViewConfig.onConsoleMessage`
to `NestedDevToolsHost.appendConsole`
**And** it appears in the Console tab in real time

#### Scenario: JS eval in a nested webview

**Given** Developer Tools is open over a nested webview and the
controller is bound
**When** the user types a JS expression and taps Run
**Then** the expression is evaluated against the nested webview's
controller (NOT the parent site's), with the same CSP-safe direct
injection used in the full mode

#### Scenario: Share HTML from a nested webview

**Given** Developer Tools is open over a nested webview
**When** the user taps the share icon and chooses Share / Save / Copy
**Then** the HTML returned by the nested webview's `controller.getHtml()`
is shared / saved / copied
**And** the filename uses the nested webview's current URL domain

---

### Requirement: DEVTOOLS-010 - Developer Mode Gate

The app SHALL carry an app-global **developer mode** flag, off by default, that gates affordances which exist to diagnose the app rather than to use it.

Diagnostics accumulate. A blank-screen repaint action (`webview-pause-lifecycle` PAUSE-028) is the first, and each one is a control an ordinary user cannot interpret sitting in a menu they open to refresh a page. Hiding them behind a debug build is not an option either: the users who hit these bugs run release builds, and the report is worth nothing if they cannot reach the tool. So the flag is reachable on every build and reached only deliberately.

- **The gesture.** App Settings SHALL show a **Version** row in the About section carrying `version+buildNumber`. Seven taps on it turn developer mode on, the Android developer-options convention, so the gesture needs no discovery mechanism of its own. The first two taps SHALL say nothing (a stray double tap is not a discovery), the third through sixth SHALL show the remaining count, and the seventh SHALL confirm. Each message SHALL replace the previous one rather than queue behind it, or the countdown lags several taps behind the finger. Tapping while already on SHALL say so and SHALL NOT count. Counting logic lives in `DeveloperUnlockEngine` (`lib/services/developer_unlock_engine.dart`), not in the widget.
- **Turning it off.** Once on, the Developer section SHALL show a **Developer mode** switch, so the state is visible and reversible without repeating the gesture. The switch is hidden while off: a control whose only purpose is to undo a hidden gesture has nothing to say before the gesture happens.
- **Reading it.** `DeveloperModeService.instance.enabled` (`lib/services/developer_mode_service.dart`) is the single reader. It is a service rather than a widget parameter because both webview-hosting screens consult it and it is **not** a per-site setting: routing it through the per-site `launchUrl` pipeline would misfile it as one. A `PopupMenuButton`'s `itemBuilder` runs each time the menu opens, so a flip takes effect with no rebuild and no restart.
- **Persistence.** The flag is a user-facing global pref: it SHALL be registered in `AppPref` (`AppPref.developerMode`) so it round-trips export/import, and the service SHALL be re-read after an import, which writes the raw key through the registry behind the service's cache.

#### Scenario: Unlocking developer mode

**Given** developer mode is off
**When** the user taps the Version row in App Settings seven times
**Then** the last five taps count down and the seventh confirms developer mode is on
**And** the Developer section grows a Developer mode switch that turns it back off

#### Scenario: A stray tap says nothing

**Given** developer mode is off
**When** the user taps the Version row twice
**Then** no message is shown, because the gesture has not been recognisably started

#### Scenario: The flag survives a backup round trip

**Given** developer mode is on and the user exports settings
**When** that backup is imported
**Then** developer mode is on and the service reflects it without a restart

---

### Requirement: DEVTOOLS-012 - Background Log

The app SHALL keep a **background log** while developer mode (DEVTOOLS-010) is on: a record of what happened while the app was not on screen, readable on the device itself, so a user whose notifications never arrived can see where the chain stopped without logcat or Console.app.

The App Logs ring (DEVTOOLS-004) cannot answer that question. It lives in memory, so the process the OS killed in the background takes its lines with it, and the steps that matter most run in native code before any Dart exists: an Android `NotificationRefreshWorker` that finds no Flutter engine, an iOS `BGAppRefreshTask` that expires. The background log is written to a file the native plugins append to themselves, and Dart appends its own background lines to the same file.

- **What it records.** App lifecycle transitions (backgrounded with the notification/background-audio inputs, resumed with the time away, the process start and, on iOS, the launch state); every change of the schedule/cancel decision with the enabled and loaded notification-site counts; every OS refresh (iOS task receipt, expiration, supersession and completion; Android enqueue, cancel, worker run, engine reachability, completion or timeout, a worker stopped early with its stop reason; engine attach/detach); every wake with a per-site outcome (load settled or not, unread baseline and current count, whether the page or the wake posted, NOTIF-013/014); every notification posted, dropped for a denied permission, or failed; and every notification site unloaded, with the reason (memory pressure, proxy or Tor exit-country mismatch, the loaded-site cap, a webspace switch, a home reset, a settings import), since an unloaded site has lost its live connection and is reached only by a wake's headless check (NOTIF-016).
- **What no lifecycle line shows.** On iOS each OS memory warning with the application state, each Low Power Mode change and the mode at launch when it is on (iOS turns off Background App Refresh while it lasts), `willTerminate`, and at launch a note when the previous process ended inside its grace period: the log's last word on that window is its start, with no expiry, resume or termination after it. On Android each trim level the system sends other than `TRIM_MEMORY_UI_HIDDEN`. These tell a real memory warning from the exit signal Flutter also reports as memory pressure (PAUSE-034), and a wake the OS withheld from one that failed.
- **System state.** The tab SHALL show the OS gates a refresh and a notification depend on, read when it opens: on iOS the Background App Refresh status, Low Power Mode, notification authorization and alert setting, and the pending refresh requests; on Android notification enablement, the `POST_NOTIFICATIONS` grant, the channel importance, battery-optimisation exemption, power-save and idle mode, the standby bucket, background restriction, and the refresh work's state, attempts and next run time; on every platform the counts of notification sites enabled, loaded and with a live webview. Copy and Export SHALL put these rows above the entries, so a log shared from a device carries the gate that stopped its wakes; none of them names a site.
- **Sensitive separation.** Each entry has a normal line that names sites only by position and count, and MAY have a sensitive companion carrying the site name, `siteId`, page title or notification text. The companion SHALL live only in memory, SHALL NOT reach the native file, an export, or the clipboard without the DEVTOOLS-004 confirmation, and SHALL be shown only while the tab's switch is on (reset per launch). The native side SHALL have no site data to record: its only path in from Dart is the append of normal lines.
- **Lifetime.** Recording SHALL run only while developer mode is on, and turning developer mode off SHALL delete the log. The native file exists only while recording, so a process the OS starts for a background task records exactly when developer mode is on. The file SHALL be capped (newest 1000 lines, a few days of ordinary use) and compacted atomically.
- **Single owner (BUG-007).** Every read, append, compaction and delete of the native file SHALL run on one serial executor (Android) or dispatch queue (iOS). Gated by `test/js/background_log_native.test.js`.
- **Archive (ARCH-001, ARCH-006).** The log adds no SharedPreferences or secure-storage key, and archive-tier sites never have notifications on (`effectiveNotificationsEnabled`), so they are never woken, posted for, or named.

#### Scenario: A wake that found no engine is on record after the process died

**Given** developer mode is on and the app was backgrounded with a notification site loaded
**And** Android later killed the process
**When** the periodic refresh fires
**Then** the worker's run and "no Flutter engine in this process; refresh skipped" are appended to the native file
**And** the next time the user opens Developer Tools, the Background tab shows both lines

#### Scenario: A process that ended inside its grace period is named at the next launch

**Given** developer mode is on and the app left the screen, so "grace period started" is the log's last line about that window
**When** the process ends before the grace period expires or the app resumes, without `willTerminate`, and the user opens the app later
**Then** the native file gets "the previous process ended inside its grace period, without an expiry or a termination notice" before the new "process launched" line

#### Scenario: An unloaded notification site is named as the reason nothing wakes

**Given** developer mode is on and one notification site is loaded
**When** a memory-pressure event unloads it and the app is then backgrounded
**Then** the log shows a warning that a notification site was unloaded for memory pressure, with 0 of 1 still loaded
**And** the schedule line shows the refresh cancelled with 1 enabled and 0 loaded

#### Scenario: Site names stay behind the switch and off disk

**Given** a wake posted for a site named "Mail"
**When** the user opens the Background tab
**Then** the wake's per-site line reads "wake site 1/1: ..." with no name
**When** the user turns on the switch
**Then** the companion line naming "Mail" appears beneath it, marked sensitive
**And** the native file, an export, and a copy without confirmation carry no "Mail"

#### Scenario: Turning developer mode off deletes the log

**Given** the background log holds entries
**When** the user turns developer mode off
**Then** the native file and the in-memory entries are deleted
**And** nothing more is recorded until developer mode is on again

---

### Requirement: DEVTOOLS-007 - Console Eval

The app SHALL provide a JavaScript evaluation input in the Console tab, allowing users to execute arbitrary JS in the context of the current page and see results inline, like a standard browser console.

#### Scenario: Evaluate a JavaScript expression

**Given** a site is loaded and the Console tab is open
**When** the user types a JS expression (e.g. `document.title`) in the eval input and taps Run or presses Enter
**Then** the input is shown in the console log as `> document.title` in bold primary color
**And** the expression is evaluated via direct code injection (CSP-safe, no `eval()`)
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

### Requirement: DEVTOOLS-011 - Experimental Features

A feature that ships before it is finished SHALL be reachable only while developer mode is on (DEVTOOLS-010) **and** its own switch in the Experimental group is on. The switch only narrows developer mode: with developer mode off no experimental feature is reachable, whatever its switch reads, so "is this feature reachable" keeps one answer.

- **The group.** App settings' Developer section SHALL show an **Experimental** group while developer mode is on, listing one switch per experimental feature that this platform can run. With no such feature on the platform, the group SHALL NOT be shown. Each switch carries its explanation behind a `HintButton` (HINT-001).
- **The switches keep their positions.** Turning developer mode off SHALL leave every switch as it was, so turning developer mode back on restores the same set of features.
- **Reading it.** `ExperimentalFeaturesService.instance.isEnabled(feature)` (`lib/services/experimental_features_service.dart`) is the single reader. The rule itself, developer mode and the switch, is the pure `experimentalFeatureEnabled`.
- **Persistence.** Each switch is a user-facing global pref registered in `AppPref`, so it round-trips export and import, and the service SHALL be re-read after an import.
- **Defaults.** A feature that developer mode alone opened before this group existed SHALL default its switch on, so an upgrade does not turn it off for a user who had it. A new feature SHALL default off.
- **Leaving the group.** A feature that graduates SHALL remove its switch and stop reading this gate; one that is dropped SHALL remove its switch with its code.

The features are:

| Feature | Switch | Default | Gate |
|---|---|---|---|
| Android's per-site proxy router (`proxy` PROXY-013) | Proxy router | on | `ProxyRouterService.isSupported`, read once at launch |
| A site's icon taken only from the site: no third-party icon service, and on Android the declared links in place of WebView's icon (`icon-fetching` ICON-014) | Site icons only | off | `publicIconServicesAllowed` in `icon_service.dart`, read on every icon fetch; `pageIconSource` in `site_icon_fetcher.dart`, read when a site's webview is created |
| Android's texture page rendering (`webview-pause-lifecycle` PAUSE-032) | Texture page rendering | off | `WebViewFactory.hybridComposition`, read once at launch |
| Tabs inside a site (`inactive-tabs` TAB-012), and web search, whose results are tabs (`link-intent-routing` LIR-029) | Site tabs | off | `_tabsFeatureEnabled` in `main.dart`, read on every use; the Default search row in App Settings and the Search group in a site's Behaviour screen, read on every build |
| Tor sites through a tor already running on the device, on Android, Linux and macOS (`tor-proxy` TOR-025) | Tor (external) | off | `TorService.wantsExternal`, read again on every flip of the switch or of developer mode (`runtimeChoiceChanged`), so it applies without a relaunch |

Outbound link routing (`link-intent-routing` LIR-013 to LIR-017) was in the group with a switch that defaulted off; it graduated with the site info sheet (`site-info-sheet`, NAV-011), which shows the site and container a routed page runs as. Page icons fetched from the links a page declares on iOS, macOS and Linux (`icon-fetching` ICON-013) were in the group with a switch that defaulted off; they graduated to the default there, and the group's Site icons only switch took the slot.

The proxy library and the connection indicator (`proxy` PROXY-030, PROXY-031) were in the group with a Saved proxies switch that defaulted off; they graduated, and are offered with developer mode on or off.

The embedded Tor client (`tor-proxy` TOR-007) was the first feature in the group, with a Built-in Tor switch that defaulted on; it graduated, and Tor is now offered wherever the platform has the runtime, with developer mode on or off.

#### Scenario: A feature needs both

- **GIVEN** developer mode is on and the Site tabs switch is off
- **WHEN** the user opens a site
- **THEN** it shows one page, with no tabs
- **AND** turning the switch on offers tabs with no restart

#### Scenario: Developer mode off closes every feature

- **GIVEN** the Site tabs switch is on
- **WHEN** the user turns developer mode off
- **THEN** tabs are not reachable
- **AND** turning developer mode back on makes them reachable again, with the switch still on

#### Scenario: The group appears with developer mode

- **GIVEN** an iOS build with developer mode off
- **WHEN** the user opens App settings
- **THEN** there is no Experimental group
- **AND** after unlocking developer mode the Developer section shows it, with Site tabs off and no Tor switch

#### Scenario: Only what this platform can run

- **GIVEN** an Android build whose WebView reports `MULTI_PROFILE`, with developer mode on
- **WHEN** the user opens App settings
- **THEN** the Experimental group lists Proxy router, on, and Texture page rendering, Site icons only, Site tabs and Tor (external), off

#### Scenario: A platform without the router

- **GIVEN** a Linux build with developer mode on
- **WHEN** the user opens App settings
- **THEN** the Experimental group lists only Site icons only, Site tabs and Tor (external), all off

#### Scenario: Site icons only starts off

- **GIVEN** an Android build with developer mode on and the Site icons only switch never touched
- **WHEN** a site's icon is fetched
- **THEN** Google's and DuckDuckGo's icon services are asked, and the site's webview reports its icon
- **AND** after the user turns Site icons only on, neither service is asked, and a site opened afterwards gets the icon its page declares

#### Scenario: The proxy router switch applies at next launch

- **GIVEN** router mode is running on Android
- **WHEN** the user turns the Proxy router switch off
- **THEN** the relay stays bound until the app restarts
- **AND** after the restart mismatched-proxy sites serialise under PROXY-008

#### Scenario: Switches survive a backup round trip

- **GIVEN** the Site icons only switch is on and the user exports settings
- **WHEN** that backup is imported
- **THEN** the switch is on without a restart

## Implementation Details

### Files

| File | Role |
|------|------|
| `lib/services/log_service.dart` | LogService singleton, LogEntry, LogLevel enum |
| `lib/screens/dev_tools.dart` | DevToolsScreen plus DevToolsHost abstraction (WebViewModelDevToolsHost, NestedDevToolsHost). Tabs/actions are gated on `host != null` (Console, Share HTML, Save Icon) and `host.blockedCookies != null` (Cookies, DNS, Scripts). |
| `lib/services/background_log.dart` | DEVTOOLS-012 `BackgroundLog`: records background lines (normal to the native file, sensitive companions in memory), merges the native file with this process, exposes the system-state rows. |
| `lib/widgets/background_log_view.dart` | The Background tab: system state, the log, the sensitive switch, Refresh / Export / Copy / Clear. |
| `android/.../BackgroundLogFile.kt`, `ios/Runner/BackgroundTaskPlugin.swift` (`BackgroundLogFile`) | Native background-log file, single-owner executor / queue, and the system-state query. |
| `lib/services/icon_png_export.dart` | The icon the drawer shows, as PNG (`displayedSiteIconAsPng`); resolves a site favicon, fetches it via the proxy-aware icon client, and normalizes any source (PNG/ICO/JPEG/SVG) to PNG bytes (`exportIconAsPng`). |
| `lib/screens/inappbrowser.dart` | InAppWebViewScreen owns a NestedDevToolsHost: forwards onConsoleMessage / onUrlChanged / onControllerCreated and exposes a "Developer Tools" entry in the popup menu. |

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
- `WebViewModel.consoleLogs` and `NestedDevToolsHost.consoleLogs`, both ring buffers (max 500 entries)
- All service files log through a `LogTag` (`LogTag.x.debug(...)`, `sensitive: true` for per-site identifiers) instead of `debugPrint()`
- Popup menu "Developer Tools" item in `main.dart` (top-level sites) and `inappbrowser.dart` (nested webviews)
- "App Logs" tile in App Settings screen
- `lib/services/developer_mode_service.dart` + `lib/services/developer_unlock_engine.dart` — DEVTOOLS-010 gate and its unlock gesture; `test/developer_unlock_engine_test.dart` characterizes the counting

---

## Manual Test Procedure

1. Open a site that produces JS console output (e.g., any site with analytics)
2. Three-dot menu -> Developer Tools
3. **Console tab**: verify messages appear color-coded with timestamps
4. **Cookies tab**: verify cookies listed with security chips; delete a cookie and confirm removal
5. **Share HTML** (AppBar share icon): tap and verify bottom sheet with Share/Save/Copy options; test each option
5a. **Save Icon as PNG** (AppBar image icon): tap and verify a save dialog with `{domain}_icon.png`; save and confirm the file opens as a PNG. Test on a site with an SVG favicon (e.g. codeberg) and one with an ICO favicon to confirm both rasterize/convert correctly
6. **Scripts** (AppBar code icon): tap and verify bottom sheet shows user scripts (or "no scripts" message); expand a script and copy its source
7. **App Logs tab**: verify app log entries appear; use filter chips; tap "Copy" and paste — verify only filtered entries are copied
8. **Filtered copy**: on each tab, enter a search query, tap Copy, and verify clipboard contains only the matching entries (not all). On the DNS tab also select the "Blocked" chip and confirm the allowed lookups stay off the clipboard
8a. **Sensitive copy**: on the App Logs tab turn on "Show sensitive entries", tap Copy, cancel the dialog and verify the clipboard is untouched; tap Copy again, confirm, and verify the sensitive lines are in the paste. Then tap Export and verify the written file has none of them
9. Go back, open App Settings -> App Logs: verify it works without a site loaded (share and scripts icons should not appear)
9a. **Background log**: with developer mode on, App Settings -> Background log opens Developer Tools on the Background tab. Background the app, wait for a refresh (or use Simulate background refresh on a site's App Logs tab), reopen and verify the lines and the System state rows. Turn on the switch and verify site names appear only then; Export and verify the file has none. Turn developer mode off and on and verify the log is empty
10. **Developer mode**: App Settings -> About -> tap Version seven times; verify the countdown starts on the third tap, each message replaces the last, and the seventh confirms. Verify a Developer mode switch appears in the Developer section, and that the page overflow menu now carries Repaint Screen on Android. Turn the switch off and verify the entry goes away
