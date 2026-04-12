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

The system SHALL navigate to the originating site when the user taps a notification.

#### Scenario: User taps a notification

**Given** a native notification was created by Site A
**When** the user taps the notification
**Then** the app opens (or comes to foreground)
**And** Site A becomes the active site

### Requirement: NOTIF-004 - Per-Site Notification Toggle

The system SHALL provide a per-site toggle to control whether the site is allowed to show notifications.

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

The system SHALL provide a per-site toggle to keep selected webviews running when the app enters the background.

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
