# Web Push Notifications

## ADDED Requirements

### Requirement: NOTIF-001 - Notification Permission Handling

The system SHALL handle JavaScript `Notification.requestPermission()` calls from web pages and grant or deny based on the per-site notification toggle. Requires profile mode (`_useProfiles == true`) — iOS 17+ or Android with System WebView 110+.

#### Scenario: Site requests notification permission with toggle enabled

**Given** profile mode is active
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

**Given** profile mode is NOT active (`_useProfiles == false`)
**When** the user opens site settings
**Then** the `notificationsEnabled` and `backgroundPoll` toggles are not shown

### Requirement: NOTIF-002 - JavaScript Notification Polyfill

The system SHALL inject a JavaScript polyfill at `DOCUMENT_START` (with `forMainFrameOnly: false`) on every site that defines `window.Notification`, `Notification.permission`, `Notification.requestPermission()`, and the `Notification` constructor. The polyfill bridges to Dart via `addJavaScriptHandler`. WKWebView does not expose the Web Notifications API natively; on Android we polyfill anyway for code-path uniformity and consistent per-site enforcement.

#### Scenario: Polyfill is injected on every site

**Given** a webview is being created for a site (iOS or Android)
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

### Requirement: NOTIF-005 - Per-Site Background Poll Toggle

The system SHALL provide a per-site toggle that opts the site into background polling. Only visible when profile mode is active. In profile mode, there are no domain conflicts, so all background-poll sites stay loaded concurrently with their own isolated profiles. Background behavior is platform-dependent — see NOTIF-005-I (iOS) and NOTIF-005-A (Android).

#### Scenario: App enters background without background-poll sites

**Given** no sites have `backgroundPoll` set to `true`
**When** the app enters the background
**Then** all webviews are paused (existing behavior)

#### Scenario: Multiple same-domain background-poll sites coexist

**Given** Site A (`github.com/personal`) has `backgroundPoll` set to `true`
**And** Site B (`github.com/work`) has `backgroundPoll` set to `true`
**And** profile mode is active
**When** both sites are loaded
**Then** both stay loaded concurrently (PROF-003 — no domain conflict)

### Requirement: NOTIF-005-I - iOS Background Strategy

On iOS, the OS suspends apps within seconds of backgrounding. The system SHALL:
1. Provide a grace-period flush via `beginBackgroundTask` (~30s) for in-flight notifications.
2. Schedule `BGAppRefreshTask` for opportunistic refreshes (typically every 15-30 minutes at the system's discretion).
3. Inform the user of these limitations on first use.

#### Scenario: App enters background — grace-period flush

**Given** the platform is iOS
**And** Site A has `backgroundPoll` set to `true` and is loaded
**When** the app enters the background
**Then** the app calls `UIApplication.shared.beginBackgroundTask(expirationHandler:)`
**And** Site A's webview is NOT paused for the duration of the background task
**And** any notifications fired by Site A during the ~30 second grace period are delivered
**And** when the grace period expires, iOS suspends the app

#### Scenario: BGAppRefreshTask runs while app is suspended

**Given** the platform is iOS
**And** Site A has `backgroundPoll` set to `true`
**And** the app is in the background and has been suspended (~30s grace period elapsed)
**When** iOS opportunistically fires the registered `BGAppRefreshTask`
**Then** the app is woken with ~30 seconds of CPU time
**And** Site A's webview is loaded (or reused if still alive in keepAlive)
**And** Site A's normal page JS runs and may fire notifications via the polyfill
**And** the app calls `task.setTaskCompleted(success: true)` and reschedules the next refresh

#### Scenario: User is informed of iOS background limitations

**Given** the platform is iOS
**And** the user enables `backgroundPoll` on a site for the first time
**When** the toggle is enabled
**Then** an informational dialog appears explaining: "iOS limits background execution. Notifications arrive while WebSpace is open, in the recent-tasks list, or during periodic background refreshes (typically every 15-30 minutes)."
**And** the dialog is shown only once (a "shown" flag is persisted)
**And** the toggle is still allowed

### Requirement: NOTIF-005-A - Android Background Strategy

On Android, the system SHALL keep background-poll sites running indefinitely via a foreground service, EXCEPT when proxy conflicts apply. The `ProxyController` is a process-wide singleton, so concurrent background-poll sites with different proxy configurations are not supported.

#### Scenario: All background-poll sites use default proxy — foreground service starts

**Given** the platform is Android
**And** Site A has `backgroundPoll` set to `true` with `ProxyType.DEFAULT`
**And** Site B has `backgroundPoll` set to `true` with `ProxyType.DEFAULT`
**When** at least one of these sites is loaded
**Then** an Android foreground service is started with a persistent notification ("WebSpace is checking N sites for updates")
**And** the foreground service keeps the app process alive
**And** when the app enters the background, both sites' webviews are NOT paused
**And** both sites continue executing JavaScript indefinitely

#### Scenario: All background-poll sites share the same custom proxy — foreground service starts

**Given** the platform is Android
**And** Site A has `backgroundPoll` set to `true` with SOCKS5 proxy on `localhost:9050`
**And** Site B has `backgroundPoll` set to `true` with the same SOCKS5 proxy
**When** both are loaded
**Then** the foreground service starts (proxy configs match)
**And** both sites continue running in background

#### Scenario: Conflicting proxy disables background-poll toggle

**Given** the platform is Android
**And** Site A has `backgroundPoll` set to `true` with SOCKS5 proxy
**And** the user attempts to enable `backgroundPoll` on Site B which has an HTTP proxy
**When** the user opens Site B's settings
**Then** the `backgroundPoll` toggle is disabled (greyed out)
**And** explanatory text reads: "Cannot enable: Site A is already polling in background with a different proxy. Android allows only one proxy at a time."
**And** the user can disable Site A's `backgroundPoll` first to free up the slot

#### Scenario: Foreground polling still works for proxy-conflicted sites

**Given** the platform is Android
**And** Site B has `notificationsEnabled` set to `true`
**And** Site B's `backgroundPoll` is disabled due to proxy conflict
**When** the user switches to Site B
**Then** Site B's proxy is applied via `ProxyController.setProxyOverride`
**And** Site B's webview runs normally and may fire notifications via the polyfill in real-time
**And** when the user switches away from Site B, its webview is paused and notifications stop until next visit

#### Scenario: Last background-poll site unloaded — foreground service stops

**Given** the foreground service is running because Site A had `backgroundPoll == true`
**When** Site A's `backgroundPoll` is disabled (or Site A is deleted)
**And** no other background-poll sites are eligible
**Then** the foreground service is stopped
**And** the persistent notification is dismissed

### Requirement: NOTIF-006 - Foreground Active Polling

While the app is in foreground, the system SHALL maintain a 5-minute refresh timer that triggers a reload on each background-poll site that is not the currently active site. This ensures sites that throttle their polling when not visible (`Page Visibility API`) still get a chance to check for new content.

#### Scenario: Foreground refresh timer fires

**Given** the app is in foreground
**And** Site A has `backgroundPoll == true` and is loaded
**And** Site B is the currently active site
**When** 5 minutes elapse
**Then** Site A is reloaded (or sent a refresh signal)
**And** Site B is NOT refreshed (it's the active site, the user is interacting with it)

#### Scenario: Active site does not get auto-refreshed

**Given** Site A is the currently active site
**And** Site A has `backgroundPoll == true`
**When** the foreground refresh timer fires
**Then** Site A is NOT refreshed by the timer
**And** any notifications fire through the polyfill in real-time as the user interacts

#### Scenario: Timer pauses when app is backgrounded

**Given** the foreground refresh timer is running
**When** the app enters the background
**Then** the foreground refresh timer is cancelled
**And** background refreshes are handled by NOTIF-005-I (iOS) or NOTIF-005-A (Android)

### Requirement: NOTIF-007 - Notification Permission

The system SHALL request OS-level notification permission before displaying the first notification.

#### Scenario: First notification on iOS triggers permission request

**Given** the platform is iOS
**And** the app has not yet requested notification permission
**When** a site attempts to show a notification
**Then** the system requests notification permission via `UNUserNotificationCenter`
**And** notifications are displayed only if the user allows it

#### Scenario: First notification on Android 13+ triggers permission request

**Given** the platform is Android with API level >= 33
**And** `POST_NOTIFICATIONS` permission has not been granted
**When** a site attempts to show a notification
**Then** the system requests the `POST_NOTIFICATIONS` runtime permission
**And** notifications are displayed only if the permission is granted

## Manual Test Procedure

Use the HTML test fixture at `test/fixtures/notification_test.html`. Import it via "Import HTML file" on the Add Site screen. **Requires profile mode support** (iOS 17+ or Android with System WebView 110+).

### Test: Polyfill is injected (NOTIF-002)
1. Import `notification_test.html` as a site
2. Check the on-page log
3. **Expected**: `typeof Notification` is `"function"` (polyfill is in place)
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
2. **Expected**: A native notification appears with title "Test Notification"
3. Tap "Send Notification with Icon"
4. **Expected**: Native notification appears with the icon
5. Tap "Send Notification with All Options"
6. **Expected**: Native notification appears with title, body, icon, and tag

### Test: Tap navigation (NOTIF-003)
1. Tap "Send Notification (then tap it)"
2. Switch to a different site in the app
3. Tap the notification in the system tray / notification center
4. **Expected**: App switches back to the notification fixture site

### Test: Foreground refresh timer (NOTIF-006)
1. Enable `backgroundPoll` and `notificationsEnabled` on the fixture site
2. Open developer tools / app logs
3. Switch to a different site (so the fixture is loaded but not active)
4. Wait 5 minutes
5. **Expected**: Log shows the fixture site was reloaded by the foreground timer

### Test: iOS background — grace-period flush (NOTIF-005-I)
1. Platform: iOS
2. Enable `backgroundPoll` for the fixture site (verify the one-time info dialog appears)
3. Tap "Send Delayed Notifications (5s, 10s, 15s)"
4. Immediately put the app in background
5. **Expected**: First notification (5s) arrives within the grace period
6. **Expected**: Subsequent notifications (10s, 15s) MAY arrive depending on iOS scheduling
7. **Expected**: After ~30 seconds, the app is suspended

### Test: iOS background — opportunistic refresh (NOTIF-005-I)
1. Platform: iOS
2. Add a site that polls a server when loaded (e.g., a custom HTML fixture that fetches every 10 seconds)
3. Enable `backgroundPoll`
4. Background the app and leave it for 30+ minutes
5. **Expected**: At some point within ~15-30 min, iOS fires `BGAppRefreshTask` and any pending notifications appear

### Test: Android background — foreground service (NOTIF-005-A)
1. Platform: Android
2. Enable `backgroundPoll` for the fixture site (proxy = DEFAULT)
3. **Expected**: A persistent foreground service notification appears
4. Tap "Send Delayed Notifications (5s, 10s, 15s)"
5. Background the app
6. **Expected**: All 3 notifications arrive over 15 seconds (foreground service keeps the process alive)

### Test: Android proxy conflict (NOTIF-005-A)
1. Platform: Android
2. Create Site A with SOCKS5 proxy, enable `backgroundPoll`
3. Create Site B with HTTP proxy
4. Open Site B's settings
5. **Expected**: `backgroundPoll` toggle is disabled with explanatory text
6. Disable `backgroundPoll` on Site A
7. **Expected**: `backgroundPoll` toggle on Site B is now enabled

### Test: Multiple background-poll sites
1. Import `notification_test.html` twice (as two separate sites)
2. Enable `backgroundPoll` and `notificationsEnabled` on both
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
1. On a device without profile mode support
2. Open site settings
3. **Expected**: `notificationsEnabled` and `backgroundPoll` toggles are NOT shown
