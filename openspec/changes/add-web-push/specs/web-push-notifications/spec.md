# Web Push Notifications

## MODIFIED Requirements

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
**And** the polyfill emits a `console.warn` breadcrumb (`[WebSpace] Notification(...) suppressed: permission denied`) so the suppression is visible in the dev-tools Console

#### Scenario: Page-context Service Worker notification is bridged

**Given** a site has notification permission granted
**And** the site calls `registration.showNotification("title", {...})` from page context (e.g. after `navigator.serviceWorker.ready`)
**When** the override runs
**Then** the polyfill calls `flutter_inappwebview.callHandler('webNotification', ...)` with the same payload shape as the `Notification` constructor
**And** a native notification is shown tagged with the originating `siteId`

#### Scenario: True server-driven web push is out of reach by design

**Given** Web Push is not offered (`web-push` WEBPUSH-001), or the user has not allowed the site (WEBPUSH-003)
**And** a site delivers notifications from inside its Service Worker's `push` or `message` event handler (the standard Web Push pattern)
**When** the push event would fire
**Then** WebSpace does NOT deliver the notification, because the webview has no Push API of its own and the site was never given an endpoint
**And** there WebSpace delivers what the site's page-context JS posts while the page is running, plus what a background wake finds (NOTIF-014), not true server push

#### Scenario: Server-driven web push where it is offered

**Given** Web Push is offered (WEBPUSH-001) and the user allowed the site (WEBPUSH-003)
**When** the site's server pushes
**Then** the push reaches the site's service worker `push` handler and what it shows is posted as the site's notification (WEBPUSH-005)
