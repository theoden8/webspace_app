## Why

Users want notifications from web apps loaded in WebSpace — typically lower-frequency things like email, RSS, GitHub mentions, calendar reminders, where a delay of 15-30 minutes is acceptable. WebSpace currently ignores all notification permission requests and pauses every webview when the app enters the background, so users get nothing (issue #192). Real-time chat apps (Slack/Teams/Telegram) are explicitly NOT in scope — they require server-side APNs relay which is incompatible with the app's privacy model.

## What Changes

- **JavaScript Notification API polyfill**: Inject a DOCUMENT_START user script that defines `window.Notification`, `Notification.requestPermission()`, `Notification.permission`, and the constructor. The polyfill bridges to Dart via `addJavaScriptHandler`, where the per-site toggle is checked and the notification is rendered natively via `flutter_local_notifications`.
- **Per-site "notifications enabled" toggle**: Per-site setting to control whether the site can show notifications. Defaults to off (opt-in).
- **Per-site "background poll" toggle**: Per-site setting that opts the site into background polling. Behavior is platform-dependent — see Background Strategy below.
- **Foreground active polling**: While the app is open, a 5-minute timer triggers a reload on each background-poll site that isn't the currently active site, so sites that throttle polling when not visible still get a chance to check for new content.
- **Native notification display + tap routing**: Use `flutter_local_notifications` to display, tag with `siteId`, and route taps through `_setCurrentIndex` to switch back to the originating site.

## Scope: iOS + Android, Profile Mode Only

This feature targets **iOS 17+** (per-site profiles via `WKWebsiteDataStore(forIdentifier:)`) and **Android with System WebView 110+** (per-site profiles via `androidx.webkit.Profile`). Profile mode eliminates domain conflicts (PROF-003), so background-poll sites just stay loaded with isolated cookie jars, localStorage, and ServiceWorkers. On legacy devices, the notification and background-poll toggles are hidden.

## Implementation Strategy: JavaScript Polyfill (both platforms)

WKWebView does not expose the Web Notifications API on iOS, and we want a single code path. `flutter_inappwebview`'s `onNotificationReceived` is Windows-only (empty stub on iOS even in 6.2.0-beta.3). So we polyfill the entire API at `DOCUMENT_START` (with `forMainFrameOnly: false` for cross-origin iframes):

```javascript
(function() {
  let permission = '__PER_SITE_PERMISSION__';
  function Notification(title, options) {
    options = options || {};
    if (permission !== 'granted') return;
    window.flutter_inappwebview.callHandler('webNotification', {
      title: title,
      body: options.body || '',
      icon: options.icon || '',
      tag: options.tag || '',
      siteId: '__SITE_ID__'
    });
  }
  Notification.permission = permission;
  Notification.requestPermission = function() {
    return new Promise(function(resolve) {
      window.flutter_inappwebview.callHandler('webNotificationRequestPermission')
        .then(function(result) { permission = result; resolve(result); });
    });
  };
  Object.defineProperty(window, 'Notification', { value: Notification, writable: false });
})();
```

Advantages: one code path for iOS and Android, no dependency on plugin internals, per-site control baked into the injected script. (On Android the native `Notification` API is available in WebView, but we polyfill anyway for code-path uniformity and so the per-site toggle is enforced consistently.)

Limitation: this polyfills the **Notification** API, not the **Push API** (`navigator.serviceWorker.pushManager`, VAPID). Sites that gate on Push API support will fall back to in-app messaging. Full Push API support would require a server-side push relay — out of scope.

## Background Strategy

| Phase | iOS | Android |
|---|---|---|
| **Foreground (any loaded site)** | Polyfill works in real-time | Polyfill works in real-time |
| **Foreground (background-poll sites that aren't active)** | Webview not paused; 5-min refresh timer reloads them | Webview not paused; 5-min refresh timer reloads them |
| **Just backgrounded (~30s)** | `beginBackgroundTask` grace flush | Foreground service keeps process alive |
| **Backgrounded (steady state)** | `BGAppRefreshTask` opportunistic refresh (~15-30 min cadence) | Foreground service keeps process alive — sites continue running indefinitely (subject to proxy constraint) |

### Foreground active polling (both platforms, every ~5 min)

While the app is in foreground:
- Background-poll sites are not paused (NOTIF-005), so their JS runs continuously.
- A foreground refresh timer fires every ~5 minutes and triggers a refresh on each background-poll site that is not the currently active site. This ensures sites that throttle their polling when not visible (`Page Visibility API`) still get a chance to check for new content.
- The active (focused) site doesn't need refreshing — the user is interacting with it directly.

### iOS background

iOS aggressively suspends apps within seconds of backgrounding. There is no `UIBackgroundModes` flag that legitimately keeps a WKWebView running indefinitely (`audio`/`location`/`voip` rejected for misuse, `remote-notification` requires APNs server). We use:

1. **`beginBackgroundTask`** — ~30-second grace window after backgrounding so in-flight notifications are delivered before iOS suspends the app.
2. **`BGAppRefreshTask`** — register a refresh task per background-poll site. iOS fires these at its discretion (typically every 15-30 minutes, more frequent for active users). Each invocation gets ~30 seconds to load the site, let it poll, and fire any pending notifications.

This is well-suited to email/RSS/GitHub-mention-style notifications. NOT suitable for real-time chat — Slack/Teams/Telegram users should use those apps' native iOS apps.

### Android background — proxy-free sites

For sites that DON'T use a custom proxy (`ProxyType.DEFAULT`), Android can deliver notifications continuously via a foreground service:

1. When at least one background-poll site without a custom proxy is loaded, start an Android foreground service with a persistent notification ("WebSpace is checking N sites for updates").
2. The service keeps the app process alive, so background-poll sites' webviews continue executing JS, WebSocket connections stay open, and the polyfill fires notifications in real-time.
3. When all background-poll sites are unloaded or the toggle is disabled, the foreground service stops.

### Android background — sites with a custom proxy

Android's `ProxyController.instance()` is a process-wide singleton. `setProxyOverride` applies to ALL WebViews, regardless of profile. If two background-poll sites have different proxy configs, only the most-recently-applied proxy is in effect — the other site's traffic routes through the wrong proxy.

Behavior:
- The `backgroundPoll` toggle is disabled (greyed out with explanatory text) for sites with a non-DEFAULT proxy if any other background-poll site already has a different proxy config.
- A site with a custom proxy CAN have `backgroundPoll` enabled if it is the only such site, or if all other background-poll sites use the same proxy.
- Foreground polling still works for proxy sites — when the user switches to that site, the proxy is applied and any notifications fire normally.

### Out of scope: server-side APNs relay

Real-time iOS background notifications would require a server that subscribes to W3C Web Push (with VAPID) on the user's behalf and forwards to APNs. This is incompatible with the app's privacy model and F-Droid distribution model — explicitly out of scope.

## Capabilities

### New Capabilities
- `web-push-notifications`: JavaScript Notification API polyfill, native notification display, per-site toggles (notifications, background-poll), foreground 5-min refresh timer, iOS grace-period flush + opportunistic `BGAppRefreshTask`, Android foreground service for proxy-free sites + proxy-conflict toggle gating, auto-loading of background-poll sites on startup, notification-tap deep linking. Profile mode only.

### Modified Capabilities
- `lazy-webview-loading`: Sites marked as background-poll are auto-loaded on app startup (added to `_loadedIndices`) without requiring a manual visit first. In profile mode there are no domain-conflict restrictions, so all background-poll sites auto-load freely.

## Impact

- **New dependencies**: `flutter_local_notifications` (notification display). Possibly a Flutter wrapper for `BGTaskScheduler` (iOS) and a foreground service plugin (Android), or thin native helpers if no good wrappers exist.
- **iOS Info.plist**:
  - Notification permission usage description
  - `BGTaskSchedulerPermittedIdentifiers` array listing our task identifier(s)
  - `UIBackgroundModes` array including `fetch` (the iOS umbrella for `BGAppRefreshTask`)
- **Android manifest**:
  - `POST_NOTIFICATIONS` permission (Android 13+)
  - `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_SPECIAL_USE` permissions
  - Foreground service declaration
  - Notification channel setup
- **WebViewModel** (`lib/web_view_model.dart`): Two new boolean fields (`notificationsEnabled`, `backgroundPoll`) with serialization.
- **Webview factory** (`lib/services/webview.dart`): Inject Notification polyfill at DOCUMENT_START. Register `webNotification` and `webNotificationRequestPermission` JavaScript handlers.
- **Main app state** (`lib/main.dart`):
  - Skip `pauseWebView` for background-poll sites in `didChangeAppLifecycleState`.
  - Foreground refresh timer (~5 min cadence) that triggers a reload on each background-poll site that is not the currently active site.
  - iOS: register `beginBackgroundTask` on background entry; schedule `BGAppRefreshTask` per background-poll site.
  - Android: start/stop foreground service based on whether any proxy-eligible background-poll site is loaded.
  - Auto-load background-poll sites on startup.
  - Notification tap handler routes through `_setCurrentIndex`.
  - Toggle visibility gated on `_useProfiles`; on Android, additionally gated on the proxy constraint.
- **New service files**:
  - `lib/services/notification_service.dart` — channel setup, display, tap routing
  - `lib/services/background_refresh_service.dart` — iOS `BGTaskScheduler` registration + Android foreground service control
  - Native Swift glue in `ios/Runner/` to register and dispatch `BGAppRefreshTask` to Dart
  - Native Kotlin glue in `android/app/src/main/kotlin/.../` for the foreground service
