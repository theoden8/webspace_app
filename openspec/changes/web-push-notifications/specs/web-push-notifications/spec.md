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

### Requirement: NOTIF-002 - JavaScript Notification Polyfill

The system SHALL inject a JavaScript polyfill at `DOCUMENT_START` (with `forMainFrameOnly: false`) that defines `window.Notification`, `Notification.permission`, `Notification.requestPermission()`, and the `Notification` constructor. The polyfill bridges to Dart via `addJavaScriptHandler`. `flutter_inappwebview`'s native `onNotificationReceived` callback is NOT used (Windows-only in current versions).

#### Scenario: Polyfill is injected on every site

**Given** a webview is being created for any site (regardless of platform)
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

The system SHALL provide a per-site toggle to keep selected webviews running when the app enters the background. Only visible when profile mode is active. Behavior is platform-dependent — see NOTIF-005-A (Android), NOTIF-005-M (macOS), NOTIF-005-I (iOS) below.

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
**And** both continue running per platform-specific background semantics

### Requirement: NOTIF-005-A - Android Real-Time Background Execution

On Android, background-active sites SHALL continue executing JavaScript indefinitely while the app is in the background, gated on a foreground service (NOTIF-006).

#### Scenario: Android app enters background with background-active sites

**Given** the platform is Android
**And** Site A and Site B both have `backgroundActive` set to `true`
**And** both are currently loaded
**When** the app enters the background
**Then** neither webview is paused (`pauseWebView` is skipped)
**And** both continue executing JavaScript, JS timers, and WebSocket connections indefinitely
**And** the foreground service keeps the process alive

### Requirement: NOTIF-005-M - macOS Real-Time Background Execution

On macOS, background-active sites SHALL continue executing JavaScript while the app is hidden or in the background. The app SHALL opt out of `NSAppNapPriority` so the OS does not throttle a fully-hidden process.

#### Scenario: macOS app is hidden with background-active sites

**Given** the platform is macOS
**And** Site A has `backgroundActive` set to `true` and is loaded
**When** the user hides the app (Cmd+H) or moves it off-screen
**Then** Site A's webview is NOT paused
**And** App Nap is disabled (`ProcessInfo.processInfo.beginActivity(...)`)
**And** Site A continues executing JavaScript at normal priority

#### Scenario: macOS App Nap is re-enabled when no background-active sites remain

**Given** App Nap was disabled because Site A had `backgroundActive == true`
**When** the user disables `backgroundActive` for Site A (or deletes the site)
**And** no other sites have `backgroundActive == true`
**Then** App Nap is re-enabled (`endActivity`)

### Requirement: NOTIF-005-I - iOS Best-Effort Background Execution

On iOS, the OS aggressively suspends apps within seconds of backgrounding. The system SHALL provide a best-effort background flush via `beginBackgroundTask` (~30s grace period) and SHALL clearly inform the user of this limitation. Real-time iOS background notifications would require server-side APNs relay (out of scope).

#### Scenario: iOS app enters background with background-active sites

**Given** the platform is iOS
**And** Site A has `backgroundActive` set to `true` and is loaded
**When** the app enters the background
**Then** the app calls `UIApplication.shared.beginBackgroundTask(expirationHandler:)`
**And** Site A's webview is NOT paused for the duration of the background task
**And** any notifications fired by Site A during the ~30 second grace period are delivered
**And** when the grace period expires (or `expirationHandler` is called), iOS suspends the app

#### Scenario: iOS user is informed of the background limitation

**Given** the platform is iOS
**And** the user enables `backgroundActive` on a site for the first time
**When** the toggle is enabled
**Then** an informational dialog appears explaining: "iOS limits background execution. Notifications arrive while WebSpace is open or in the recent-tasks list. For real-time delivery, keep WebSpace in your dock or use the Android / macOS version."
**And** the dialog is shown only once (a "shown" flag is persisted)
**And** the toggle is still allowed (the foreground + grace-period behavior is useful)

#### Scenario: iOS notifications work normally in foreground

**Given** the platform is iOS
**And** Site A has `notificationsEnabled == true` and `backgroundActive == true`
**And** the app is in foreground (active or inactive but not suspended)
**When** Site A fires a notification via the polyfill
**Then** the notification displays via `flutter_local_notifications`
**And** behavior is identical to Android / macOS in foreground

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

### Test: Polyfill is injected (NOTIF-002)
1. Import `notification_test.html` as a site
2. Open developer tools (or check the on-page log)
3. **Expected**: `typeof Notification` is `"function"` (polyfill is in place — without it, WKWebView would report `"undefined"` on iOS / macOS)
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
4. **Expected**: Native notification appears with a Google favicon icon
5. Tap "Send Notification with All Options"
6. **Expected**: Native notification appears with title, body, icon, and tag

### Test: Tap navigation (NOTIF-003)
1. Tap "Send Notification (then tap it)"
2. Switch to a different site in the app
3. Tap the notification in the system tray
4. **Expected**: App switches back to the notification fixture site

### Test: Background delivery on Android (NOTIF-005-A, NOTIF-006)
1. Platform: Android
2. Enable `backgroundActive` for the fixture site
3. Tap "Send Delayed Notifications (5s, 10s, 15s)"
4. Immediately put the app in background
5. **Expected**: 3 native notifications arrive over 15 seconds
6. **Expected**: A persistent foreground service notification appears

### Test: Background delivery on macOS (NOTIF-005-M)
1. Platform: macOS 14+
2. Enable `backgroundActive` for the fixture site
3. Tap "Send Delayed Notifications (5s, 10s, 15s)"
4. Hide the app (Cmd+H) or switch to a different Space
5. **Expected**: 3 native notifications arrive over 15 seconds (App Nap is disabled)

### Test: Background delivery on iOS (NOTIF-005-I)
1. Platform: iOS 17+
2. Enable `backgroundActive` for the fixture site (verify the one-time info dialog appears)
3. Tap "Send Delayed Notifications (5s, 10s, 15s)"
4. Immediately put the app in background (press Home / swipe up)
5. **Expected**: First notification (5s) arrives within the grace period
6. **Expected**: Subsequent notifications (10s, 15s) MAY arrive depending on iOS scheduling
7. **Expected**: After ~30 seconds, the app is suspended and no further notifications arrive until the user opens WebSpace again

### Test: iOS foreground notifications (NOTIF-005-I foreground scenario)
1. Platform: iOS
2. Enable `backgroundActive` and `notificationsEnabled` on the fixture site
3. Keep the app in foreground
4. Tap "Send Delayed Notifications (5s, 10s, 15s)"
5. **Expected**: All 3 notifications arrive normally — foreground behavior is identical to Android/macOS

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
