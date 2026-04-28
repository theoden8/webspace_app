# Web Push Notifications

## ADDED Requirements

### Requirement: NOTIF-001 - Notification Permission Handling

The system SHALL handle JavaScript `Notification.requestPermission()` calls from web pages and grant or deny based on the per-site notification toggle. Requires iOS 17+ profile mode (`_useProfiles == true`).

#### Scenario: Site requests notification permission with toggle enabled

**Given** profile mode is active on iOS 17+
**And** a site has `notificationsEnabled` set to `true`
**When** the site calls `Notification.requestPermission()`
**Then** the polyfill calls the `webNotificationRequestPermission` JS handler
**And** Dart checks the per-site toggle and returns `"granted"`
**And** the site receives `"granted"` as the permission result

#### Scenario: Site requests notification permission with toggle disabled

**Given** a site has `notificationsEnabled` set to `false`
**When** the site calls `Notification.requestPermission()`
**Then** the polyfill returns `"denied"` via the JS handler

#### Scenario: Notification toggles hidden on legacy devices

**Given** profile mode is NOT active (`_useProfiles == false`, iOS <17)
**When** the user opens site settings
**Then** the `notificationsEnabled` and `backgroundActive` toggles are not shown

### Requirement: NOTIF-002 - JavaScript Notification Polyfill

WKWebView does not expose the Web Notifications API (`window.Notification` is `undefined`). The system SHALL inject a JavaScript polyfill at `DOCUMENT_START` (with `forMainFrameOnly: false`) that defines `window.Notification`, `Notification.permission`, `Notification.requestPermission()`, and the `Notification` constructor. The polyfill bridges to Dart via `addJavaScriptHandler`.

#### Scenario: Polyfill is injected on every site

**Given** a webview is being created for a site on iOS
**When** the page loads
**Then** `window.Notification` is defined before any page script runs
**And** `Notification.permission` is `"granted"` if the site has `notificationsEnabled == true`, otherwise `"denied"`
**And** the polyfill is injected with `forMainFrameOnly: false` so cross-origin iframes also see it

#### Scenario: Site creates a notification via the polyfill

**Given** a site has notification permission granted
**When** the site calls `new Notification("title", { body: "message", icon: "url" })`
**Then** the polyfill calls `flutter_inappwebview.callHandler('webNotification', ...)` with title, body, icon, tag, and `siteId`
**And** Dart receives the call and shows a native notification via `flutter_local_notifications`
**And** the notification is tagged with the originating site's `siteId`

#### Scenario: Notification constructor is a no-op when permission is denied

**Given** a site has `notificationsEnabled == false` (polyfill sees `permission === 'denied'`)
**When** the site calls `new Notification(...)`
**Then** the polyfill returns without invoking the JS bridge
**And** no native notification is shown

### Requirement: NOTIF-003 - Notification Tap Navigation

The system SHALL navigate to the originating site when the user taps a notification. This routes through `_setCurrentIndex`. In profile mode, no domain conflicts occur — the target site simply becomes active.

#### Scenario: User taps a notification for a loaded site

**Given** a native notification was created by Site A
**And** Site A is still loaded in `_loadedIndices`
**When** the user taps the notification
**Then** the app opens (or comes to foreground)
**And** `_setCurrentIndex` is called with Site A's index
**And** Site A becomes the active site

#### Scenario: User taps a notification for a site that was not yet loaded

**Given** a native notification was created by Site A
**And** Site A is not in `_loadedIndices` (e.g., app was restarted)
**When** the user taps the notification
**Then** `_setCurrentIndex` adds Site A to `_loadedIndices`
**And** Site A's webview is created with its profile
**And** Site A becomes the active site

### Requirement: NOTIF-004 - Per-Site Notification Toggle

The system SHALL provide a per-site toggle to control whether the site is allowed to show notifications. Defaults to off (opt-in). Only visible when profile mode is active.

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

The system SHALL provide a per-site toggle to keep selected webviews running when the app enters the background. Only visible when profile mode is active. In profile mode, there are no domain conflicts, so all background-active sites stay loaded concurrently with their own isolated profiles.

#### Scenario: App enters background without background-active sites

**Given** no sites have `backgroundActive` set to `true`
**When** the app enters the background
**Then** all webviews are paused (existing behavior)

#### Scenario: Multiple same-domain background-active sites coexist

**Given** Site A (`github.com/personal`) has `backgroundActive` set to `true`
**And** Site B (`github.com/work`) has `backgroundActive` set to `true`
**And** profile mode is active
**When** both sites are loaded
**Then** both stay loaded concurrently (PROF-003 — no domain conflict)

### Requirement: NOTIF-006 - iOS Best-Effort Background Execution

On iOS, the OS suspends apps within seconds of backgrounding. The system SHALL provide a best-effort background flush via `beginBackgroundTask` (~30s grace period) and SHALL inform the user of this limitation on first use.

#### Scenario: App enters background with background-active sites

**Given** Site A has `backgroundActive` set to `true` and is loaded
**When** the app enters the background
**Then** the app calls `UIApplication.shared.beginBackgroundTask(expirationHandler:)`
**And** Site A's webview is NOT paused for the duration of the background task
**And** any notifications fired by Site A during the ~30 second grace period are delivered
**And** when the grace period expires, iOS suspends the app

#### Scenario: User is informed of the background limitation

**Given** the user enables `backgroundActive` on a site for the first time
**When** the toggle is enabled
**Then** an informational dialog appears explaining: "iOS limits background execution. Notifications arrive while WebSpace is open or in the recent-tasks list."
**And** the dialog is shown only once (a "shown" flag is persisted)
**And** the toggle is still allowed

#### Scenario: Foreground notifications work normally

**Given** Site A has `notificationsEnabled == true` and `backgroundActive == true`
**And** the app is in foreground
**When** Site A fires a notification via the polyfill
**Then** the notification displays via `flutter_local_notifications` in real-time

### Requirement: NOTIF-007 - iOS Notification Permission

The system SHALL request iOS notification permission via `UNUserNotificationCenter` before displaying the first notification.

#### Scenario: First notification triggers iOS permission request

**Given** the app has not yet requested iOS notification permission
**When** a site attempts to show a notification
**Then** the system requests notification permission from the user via the iOS permission dialog
**And** notifications are displayed only if the user allows it

## Manual Test Procedure

Use the HTML test fixture at `test/fixtures/notification_test.html`. Import it via "Import HTML file" on the Add Site screen. **Requires iOS 17+ with profile mode support.**

### Test: Polyfill is injected (NOTIF-002)
1. Import `notification_test.html` as a site
2. Check the on-page log
3. **Expected**: `typeof Notification` is `"function"` (polyfill is in place — without it, WKWebView would report `"undefined"`)
4. **Expected**: `Notification.permission` reflects the per-site toggle state

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
2. **Expected**: A native iOS notification appears with title "Test Notification"
3. Tap "Send Notification with Icon"
4. **Expected**: Native notification appears with a Google favicon icon
5. Tap "Send Notification with All Options"
6. **Expected**: Native notification appears with title, body, icon, and tag

### Test: Tap navigation (NOTIF-003)
1. Tap "Send Notification (then tap it)"
2. Switch to a different site in the app
3. Tap the notification in the notification center
4. **Expected**: App switches back to the notification fixture site

### Test: Background delivery (NOTIF-006)
1. Enable `backgroundActive` for the fixture site (verify the one-time info dialog appears)
2. Tap "Send Delayed Notifications (5s, 10s, 15s)"
3. Immediately put the app in background (swipe up / press Home)
4. **Expected**: First notification (5s) arrives within the grace period
5. **Expected**: Subsequent notifications (10s, 15s) MAY arrive depending on iOS scheduling
6. **Expected**: After ~30 seconds, the app is suspended and no further notifications arrive until the user opens WebSpace again

### Test: Foreground notifications
1. Enable `backgroundActive` and `notificationsEnabled` on the fixture site
2. Keep the app in foreground, switch to a different site
3. Tap "Send Delayed Notifications (5s, 10s, 15s)" on the fixture site before switching
4. **Expected**: All 3 notifications arrive normally while the app is open

### Test: Multiple background-active sites
1. Import `notification_test.html` twice (as two separate sites)
2. Enable `backgroundActive` and `notificationsEnabled` on both
3. On Site A, tap "Send Delayed Notifications", then switch to Site B
4. On Site B, tap "Send Delayed Notifications"
5. Keep app in foreground
6. **Expected**: Notifications from both sites arrive (profile mode — no conflicts)

### Test: Edge cases
1. Tap "Send 5 Rapid Notifications" — all 5 should appear as native notifications
2. Tap "Send Empty Notification" — should display with title only, no body
3. Tap "Send Notification with Long Text" — text should be truncated or scrollable
4. Disable `notificationsEnabled`, tap "Send Without Permission" — no notification should display

### Test: Legacy device
1. On a device with iOS <17 (`_useProfiles == false`)
2. Open site settings
3. **Expected**: `notificationsEnabled` and `backgroundActive` toggles are NOT shown
