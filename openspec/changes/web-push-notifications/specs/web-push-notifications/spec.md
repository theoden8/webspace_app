# Web Push Notifications

## ADDED Requirements

### Requirement: NOTIF-001 - Notification Permission Handling

The system SHALL handle JavaScript `Notification.requestPermission()` calls from web pages and grant or deny based on the per-site notification toggle. Requires profile mode (`_useProfiles == true`).

#### Scenario: Site requests notification permission with toggle enabled

**Given** profile mode is active
**And** a site has `notificationsEnabled` set to `true`
**When** the site calls `Notification.requestPermission()`
**Then** the permission is granted
**And** the site receives `"granted"` as the permission result

#### Scenario: Site requests notification permission with toggle disabled

**Given** a site has `notificationsEnabled` set to `false`
**When** the site calls `Notification.requestPermission()`
**Then** the permission is denied
**And** the site receives `"denied"` as the permission result

#### Scenario: Notification toggles hidden on legacy devices

**Given** profile mode is NOT active (`_useProfiles == false`)
**When** the user opens site settings
**Then** the `notificationsEnabled` and `backgroundActive` toggles are not shown

### Requirement: NOTIF-002 - JavaScript Notification Bridge

The system SHALL intercept `new Notification()` constructor calls from web pages and display them as native platform notifications.

#### Scenario: Site creates a JavaScript notification

**Given** a site has notification permission granted
**When** the site calls `new Notification("title", { body: "message", icon: "url" })`
**Then** a native notification is displayed with the title, body, and icon
**And** the notification is tagged with the originating site's `siteId`

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

#### Scenario: App enters background with background-active sites

**Given** Site A and Site B both have `backgroundActive` set to `true`
**And** both are currently loaded (profile mode, no domain conflicts)
**When** the app enters the background
**Then** Site A and Site B's webviews are NOT paused
**And** both continue executing JavaScript
**And** both retain authenticated sessions via their per-profile cookie jars

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
**And** both continue running in background when app is backgrounded

### Requirement: NOTIF-PROXY - Proxy Conflict Warning (Android Only)

On Android, `ProxyController` is a process-wide singleton — only one proxy config is active at a time across all WebViews. When a user enables `backgroundActive` on a site with a non-default proxy, and another background-active site has a different proxy configuration, the system SHALL warn the user. On iOS 17+ / macOS 14+, per-site proxy is natively supported via `WKWebsiteDataStore`, so no warning is needed.

#### Scenario: Conflicting proxies on Android

**Given** the platform is Android
**And** Site A has `backgroundActive` set to `true` with SOCKS5 proxy
**And** the user enables `backgroundActive` on Site B which has an HTTP proxy
**When** the toggle is enabled
**Then** a warning is shown explaining that only one proxy config can be active at a time on Android
**And** the toggle is still allowed (user choice)

#### Scenario: Conflicting proxies on iOS / macOS

**Given** the platform is iOS 17+ or macOS 14+
**And** Site A has `backgroundActive` set to `true` with SOCKS5 proxy
**And** the user enables `backgroundActive` on Site B which has an HTTP proxy
**When** both are loaded concurrently
**Then** no warning is shown (per-site proxy is natively supported)
**And** each site routes traffic through its own proxy

#### Scenario: No conflict when proxies match or are default

**Given** Site A and Site B both have `backgroundActive` set to `true`
**And** both have the same proxy config (or both use DEFAULT)
**When** both are loaded concurrently
**Then** no warning is shown on any platform

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

## Manual Test Procedure

Use the HTML test fixture at `test/fixtures/notification_test.html`. Import it via "Import HTML file" on the Add Site screen. **Requires a device with profile mode support** (Android System WebView 110+ or iOS 17+ / macOS 14+).

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

### Test: Multiple background-active sites
1. Import `notification_test.html` twice (as two separate sites)
2. Enable `backgroundActive` and `notificationsEnabled` on both
3. On Site A, tap "Send Delayed Notifications", then switch to Site B
4. On Site B, tap "Send Delayed Notifications"
5. Put app in background
6. **Expected**: Notifications from both sites arrive (profile mode — no conflicts)

### Test: Edge cases
1. Tap "Send 5 Rapid Notifications" — all 5 should appear as native notifications
2. Tap "Send Empty Notification" — should display with title only, no body
3. Tap "Send Notification with Long Text" — text should be truncated or scrollable
4. Disable `notificationsEnabled`, tap "Send Without Permission" — no notification should display

### Test: Legacy device
1. On a device with `_useProfiles == false`
2. Open site settings
3. **Expected**: `notificationsEnabled` and `backgroundActive` toggles are NOT shown
