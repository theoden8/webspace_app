## Why

Web apps like Slack, MS Teams, Telegram Web, and Google Chat use the JavaScript Notification API and Push API to deliver real-time messages, but WebSpace currently ignores all notification permission requests and pauses every webview when the app enters the background. Users who rely on WebSpace as their primary browser for these services miss all notifications, making the app unsuitable for communication-heavy workflows (issue #192).

## What Changes

- **JavaScript Notification API polyfill**: Inject a DOCUMENT_START user script that defines `window.Notification`, `Notification.requestPermission()`, `Notification.permission`, and the constructor. The polyfill bridges to Dart via `addJavaScriptHandler`, where the per-site toggle is checked and the notification is rendered natively via `flutter_local_notifications`.
- **Per-site "notifications enabled" toggle**: Per-site setting to control whether the site can show notifications. Defaults to off (opt-in).
- **Per-site "background active" toggle**: Per-site setting that keeps selected webviews running when the app enters the background. On iOS, background execution is limited to a ~30-second grace period via `beginBackgroundTask` — see iOS Background Strategy below.
- **Native notification display + tap routing**: Use `flutter_local_notifications` to display, tag with `siteId`, and route taps through `_setCurrentIndex` to switch back to the originating site.

## Scope: iOS + Profile Mode Only

This feature targets iOS 17+ where per-site profiles are supported via `WKWebsiteDataStore(forIdentifier:)`. Profile mode eliminates domain conflicts (PROF-003), so background-active sites just stay loaded with isolated cookie jars, localStorage, and ServiceWorkers. On legacy iOS (<17), the notification and background-active toggles are hidden.

Per-site proxy is natively supported on iOS via `WKWebsiteDataStore`, so concurrent background-active sites with different proxies work correctly — no process-wide singleton issue.

## Implementation Strategy: JavaScript Polyfill

WKWebView does not expose the Web Notifications API — `window.Notification` is `undefined`. `flutter_inappwebview`'s `onNotificationReceived` is Windows-only (empty stub on iOS even in 6.2.0-beta.3). So we polyfill the entire API at `DOCUMENT_START` (with `forMainFrameOnly: false` for cross-origin iframes):

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

Advantages over native callbacks: one code path, no dependency on plugin internals, per-site control baked into the injected script.

Limitation: this polyfills the **Notification** API, not the **Push API** (`navigator.serviceWorker.pushManager`, VAPID). Sites that gate on Push API support will fall back to in-app messaging. Full Push API support would require a server-side push relay — out of scope.

## iOS Background Strategy

iOS aggressively suspends apps within seconds of backgrounding. There is no `UIBackgroundModes` flag that legitimately keeps a WKWebView running:

- `audio` — rejected by App Store if not genuinely playing audio
- `voip` — requires PushKit + CallKit, only for real VoIP apps
- `location` — rejected if not a location-based app
- `fetch` — opportunistic ~15-30 min intervals, not real-time
- `remote-notification` — requires APNs server-side infrastructure

### Tier 1: Foreground + grace-period flush (v1 scope)

- While the app is in foreground (active or inactive), the polyfill works normally for all loaded sites.
- When the app backgrounds, register `beginBackgroundTask(expirationHandler:)` for a ~30-second grace window. Any notifications fired by background-active sites during this window are delivered.
- After the grace period, iOS suspends the app and JS execution stops.
- When the user enables `backgroundActive` for the first time, show a one-time info dialog: "iOS limits background execution. Notifications arrive while WebSpace is open. For real-time delivery, keep WebSpace in your dock."

### Tier 2: Opportunistic background fetch (future)

- Schedule `BGAppRefreshTask` for each background-active site. iOS fires it opportunistically (~15-30 min).
- Each invocation gets ~30 seconds. Reload background-active sites, let them poll, fire any notifications.
- Not real-time. Useful for low-frequency notifications (email, RSS), useless for chat.
- Separate project if user demand justifies it.

### Tier 3: Server-side APNs relay (out of scope)

- Relay Web Push via APNs. Real-time but adds a backend, privacy regression, incompatible with F-Droid distribution model.

## Capabilities

### New Capabilities
- `web-push-notifications`: JavaScript Notification API polyfill, native notification display, per-site toggles, grace-period background flush, auto-loading of background-active sites on startup, notification-tap deep linking. iOS 17+ profile mode only.

### Modified Capabilities
- `lazy-webview-loading`: Sites marked as background-active are auto-loaded on app startup (added to `_loadedIndices`) without requiring a manual visit first. In profile mode there are no domain-conflict restrictions, so all background-active sites auto-load freely.

## Impact

- **New dependencies**: `flutter_local_notifications` (notification display).
- **iOS Info.plist**: Notification permission usage description.
- **WebViewModel** (`lib/web_view_model.dart`): Two new boolean fields (`notificationsEnabled`, `backgroundActive`) with serialization.
- **Webview factory** (`lib/services/webview.dart`): Inject Notification polyfill at DOCUMENT_START. Register `webNotification` and `webNotificationRequestPermission` JavaScript handlers.
- **Main app state** (`lib/main.dart`):
  - Skip `pauseWebView` for background-active sites in `didChangeAppLifecycleState`.
  - Register `beginBackgroundTask` on background entry for grace-period flush.
  - Auto-load background-active sites on startup.
  - Notification tap handler routes through `_setCurrentIndex`.
  - Toggle visibility gated on `_useProfiles`.
- **New service file** (`lib/services/notification_service.dart`): Channel setup, display, tap routing.
