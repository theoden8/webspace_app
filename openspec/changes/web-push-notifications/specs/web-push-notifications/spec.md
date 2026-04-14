# Web Push Notifications

## ADDED Requirements

### Requirement: NOTIF-001 - Notification Permission Handling

The system SHALL handle JavaScript `Notification.requestPermission()` calls from web pages and grant or deny based on the per-site notification toggle.

#### Scenario: Site requests notification permission with toggle enabled

**Given** a site has `notificationsEnabled` set to `true`
**When** the site calls `Notification.requestPermission()`
**Then** the permission is granted
**And** the site receives `"granted"` as the permission result

#### Scenario: Site requests notification permission with toggle disabled

**Given** a site has `notificationsEnabled` set to `false`
**When** the site calls `Notification.requestPermission()`
**Then** the permission is denied
**And** the site receives `"denied"` as the permission result

### Requirement: NOTIF-002 - JavaScript Notification Bridge

The system SHALL intercept `new Notification()` constructor calls from web pages and display them as native platform notifications.

#### Scenario: Site creates a JavaScript notification

**Given** a site has notification permission granted
**When** the site calls `new Notification("title", { body: "message", icon: "url" })`
**Then** a native notification is displayed with the title, body, and icon
**And** the notification is tagged with the originating site's `siteId`

### Requirement: NOTIF-003 - Notification Tap Navigation

The system SHALL navigate to the originating site when the user taps a notification. This routes through `_setCurrentIndex`, which applies the standard domain-conflict detection and cookie isolation cycle.

#### Scenario: User taps a notification for a loaded site

**Given** a native notification was created by Site A
**And** Site A is still loaded in `_loadedIndices`
**When** the user taps the notification
**Then** the app opens (or comes to foreground)
**And** `_setCurrentIndex` is called with Site A's index
**And** Site A becomes the active site

#### Scenario: User taps a notification that triggers domain conflict

**Given** a native notification was created by Site A (`github.com/personal`)
**And** Site B (`github.com/work`) is currently loaded
**When** the user taps the notification
**Then** `_setCurrentIndex` runs domain-conflict detection
**And** Site B is unloaded (cookies captured, webview disposed, CookieManager cleared)
**And** Site A's cookies are restored and its webview is created
**And** Cookies for remaining background-active sites on other domains are also restored

#### Scenario: User taps a notification for a site that was unloaded

**Given** a native notification was created by Site A
**And** Site A was since unloaded (e.g., due to a domain conflict)
**When** the user taps the notification
**Then** `_setCurrentIndex` creates Site A's webview fresh
**And** Site A's cookies are restored from secure storage

### Requirement: NOTIF-004 - Per-Site Notification Toggle

The system SHALL provide a per-site toggle to control whether the site is allowed to show notifications. Defaults to off (opt-in).

#### Scenario: User enables notifications for a site

**Given** a site with `notificationsEnabled` set to `false`
**When** the user enables the notifications toggle in site settings
**Then** `notificationsEnabled` is set to `true`
**And** the setting is persisted

#### Scenario: User disables notifications for a site

**Given** a site with `notificationsEnabled` set to `true`
**When** the user disables the notifications toggle in site settings
**Then** `notificationsEnabled` is set to `false`
**And** any pending notification permission requests from the site are denied

### Requirement: NOTIF-005 - Per-Site Background Active Toggle

The system SHALL provide a per-site toggle to keep selected webviews running when the app enters the background. The `backgroundActive` flag does NOT override cookie isolation — same-domain mutual exclusion still applies.

#### Scenario: App enters background with background-active site

**Given** Site A has `backgroundActive` set to `true`
**And** Site A is currently loaded
**When** the app enters the background
**Then** Site A's webview is NOT paused
**And** Site A continues executing JavaScript

#### Scenario: App enters background without background-active sites

**Given** no sites have `backgroundActive` set to `true`
**When** the app enters the background
**Then** all webviews are paused (existing behavior)

#### Scenario: Background-active site detached by domain conflict via keepAlive

**Given** Site A (`github.com/personal`) has `backgroundActive` set to `true`
**And** Site A's webview was created with an `InAppWebViewKeepAlive` token
**And** Site A is loaded and running in background
**When** Site B (`github.com/work`) is selected by the user
**Then** Site A's cookies are captured and saved
**And** Site A's widget is removed from the IndexedStack
**And** Site A's native WebView is preserved via keepAlive (JS/WebSockets continue)
**And** Site A can still deliver notifications via the JS bridge
**But** Site A's HTTP requests may lack correct cookies until re-attached

#### Scenario: Two background-active sites on same domain

**Given** Site A (`github.com/personal`) has `backgroundActive` set to `true`
**And** Site B (`github.com/work`) has `backgroundActive` set to `true`
**When** both sites attempt to auto-load on startup
**Then** only one is loaded (the first encountered)
**And** the other remains as a placeholder due to domain conflict
**And** a warning is logged

### Requirement: NOTIF-006 - Android Foreground Service

On Android, the system SHALL use a foreground service to keep the process alive when at least one background-active site is loaded.

#### Scenario: Background-active site is loaded on Android

**Given** the platform is Android
**And** at least one loaded site has `backgroundActive` set to `true`
**When** the app enters the background
**Then** a foreground service with a persistent notification is started
**And** the notification indicates how many sites are active in background

#### Scenario: All background-active sites are unloaded

**Given** a foreground service is running
**When** the last background-active site is unloaded or its toggle is disabled
**Then** the foreground service is stopped

### Requirement: NOTIF-007 - Android Notification Permission

On Android 13+, the system SHALL request the `POST_NOTIFICATIONS` runtime permission before displaying notifications.

#### Scenario: First notification on Android 13+

**Given** the platform is Android with API level >= 33
**And** `POST_NOTIFICATIONS` permission has not been granted
**When** a site attempts to show a notification
**Then** the system requests the `POST_NOTIFICATIONS` runtime permission
**And** notifications are displayed only if the permission is granted

### Requirement: NOTIF-008 - InAppWebViewKeepAlive for Background-Active Sites

Background-active sites SHALL use `InAppWebViewKeepAlive` to preserve their native WebView instance when the widget is removed from the tree (e.g., due to domain conflict). This keeps JS execution, WebSocket connections, and DOM state alive, enabling continued notification delivery.

#### Scenario: KeepAlive token created when backgroundActive is enabled

**Given** a site has `backgroundActive` set to `false`
**And** no keepAlive token exists for the site
**When** the user enables `backgroundActive` in site settings
**Then** an `InAppWebViewKeepAlive` instance is created on the `WebViewModel`
**And** the webview is recreated with the keepAlive token passed to `InAppWebView(keepAlive: ...)`

#### Scenario: KeepAlive token disposed when backgroundActive is disabled

**Given** a site has `backgroundActive` set to `true` with a keepAlive token
**When** the user disables `backgroundActive` in site settings
**Then** the keepAlive token is disposed
**And** the webview is recreated without a keepAlive token (standard behavior)

#### Scenario: KeepAlive preserves state across domain-conflict detach/reattach

**Given** Site A has `backgroundActive` set to `true` with a keepAlive token
**And** Site A has scrolled to the middle of a page and has form data entered
**When** Site A is detached from IndexedStack due to domain conflict
**And** later the user switches back to Site A
**Then** the same native WebView is re-attached via keepAlive
**And** scroll position, form data, and DOM state are preserved
**And** no page reload occurs

#### Scenario: Non-background-active sites do not use keepAlive

**Given** a site has `backgroundActive` set to `false`
**When** the site's webview is created
**Then** no `InAppWebViewKeepAlive` token is used
**And** the webview follows existing dispose-on-conflict behavior

#### Scenario: KeepAlive token disposed on site deletion

**Given** a background-active site with a keepAlive token
**When** the user deletes the site
**Then** the keepAlive token is disposed
**And** the native WebView is destroyed

## Manual Test Procedure

Use the HTML test fixture at `test/fixtures/notification_test.html`. Import it via "Import HTML file" on the Add Site screen.

### Test: Permission grant/deny (NOTIF-001, NOTIF-004)
1. Import `notification_test.html` as a site
2. Open site settings, ensure `notificationsEnabled` is OFF
3. Tap "Request Permission" in the fixture
4. **Expected**: Permission result is `denied`, logged in the on-page log
5. Enable `notificationsEnabled` in site settings
6. Tap "Request Permission" again
7. **Expected**: Permission result is `granted`

### Test: Notification display (NOTIF-002)
1. With permission granted, tap "Send Basic Notification"
2. **Expected**: A native notification appears with title "Test Notification"
3. Tap "Send Notification with Icon"
4. **Expected**: Native notification appears with a Google favicon icon
5. Tap "Send Notification with All Options"
6. **Expected**: Native notification appears with title, body, icon, and tag

### Test: Tap navigation (NOTIF-003)
1. Tap "Send Notification (then tap it)"
2. Switch to a different site in the app
3. Tap the notification in the system tray
4. **Expected**: App switches back to the notification fixture site

### Test: Background delivery (NOTIF-005, NOTIF-006)
1. Enable `backgroundActive` for the fixture site
2. Tap "Send Delayed Notifications (5s, 10s, 15s)"
3. Immediately put the app in background
4. **Expected**: 3 native notifications arrive over 15 seconds
5. On Android: a persistent foreground service notification should appear

### Test: Edge cases
1. Tap "Send 5 Rapid Notifications" — all 5 should appear as native notifications
2. Tap "Send Empty Notification" — should display with title only, no body
3. Tap "Send Notification with Long Text" — text should be truncated or scrollable
4. Disable `notificationsEnabled`, tap "Send Without Permission" — no notification should display

### Test: KeepAlive state preservation (NOTIF-008)
1. Import `notification_test.html` as Site A, enable `backgroundActive`
2. Add a second site with the same file:// domain or create two `github.com` sites
3. On Site A, tap "Send Delayed Notifications (5s, 10s, 15s)", scroll down, type in the log
4. Switch to the conflicting site (Site A detached via keepAlive)
5. **Expected**: Delayed notifications still arrive (native WebView alive via keepAlive)
6. Switch back to Site A
7. **Expected**: Scroll position and page state preserved, no page reload, on-page log shows successful sends

### Test: Cookie isolation interaction
1. Import `notification_test.html` as Site A
2. Add a real site (e.g., `github.com`) as Site B
3. Enable `backgroundActive` and `notificationsEnabled` on Site A
4. Tap "Send Delayed Notifications" on Site A, then switch to Site B
5. **Expected**: Notifications still arrive (file:// domain doesn't conflict with github.com)
6. The on-page log records successful sends (check when switching back to Site A)
