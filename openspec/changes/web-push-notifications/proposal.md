## Why

Web apps like Slack, MS Teams, Telegram Web, and Google Chat use the JavaScript Notification API and Push API to deliver real-time messages, but WebSpace currently ignores all notification permission requests and pauses every webview when the app enters the background. Users who rely on WebSpace as their primary browser for these services miss all notifications, making the app unsuitable for communication-heavy workflows (issue #192).

## What Changes

- **JavaScript Notification API polyfill**: Inject a DOCUMENT_START user script on every platform that defines `window.Notification`, `Notification.requestPermission()`, `Notification.permission`, and the constructor. The polyfill bridges to Dart via `addJavaScriptHandler`, where the per-site toggle is checked and the notification is rendered natively via `flutter_local_notifications`. This avoids relying on platform-specific webview notification callbacks (which are Windows-only in `flutter_inappwebview` today).
- **Per-site "notifications enabled" toggle**: Per-site setting to control whether the site can show notifications. Defaults to off (opt-in).
- **Per-site "background active" toggle**: Per-site setting that keeps selected webviews running when the app enters the background. Behavior varies by platform — see Background Execution Matrix below.
- **Native notification display + tap routing**: Use `flutter_local_notifications` to display, tag with `siteId`, and route taps through `_setCurrentIndex` to switch back to the originating site.

## Scope: Profile Mode Only

This feature requires native per-site profiles (`_useProfiles == true`). On legacy devices using `CookieIsolationEngine`, the notification and background-active toggles are hidden. Profile mode eliminates domain conflicts (PROF-003), so background-active sites just stay loaded with isolated storage. The CookieIsolation engine's capture-nuke-restore cycle would make reliable background notifications infeasible.

## Implementation Strategy: JavaScript Polyfill (All Platforms)

`flutter_inappwebview` does not expose the Web Notifications API on Android, iOS, or macOS in the version we use (`6.1.0+1`). Even in the development branch (`6.2.0-beta.3`), `onNotificationReceived` is annotated `@SupportedPlatforms([WindowsPlatform()])` and the iOS / macOS implementations are empty stubs.

Instead, inject a polyfill at `DOCUMENT_START` (with `forMainFrameOnly: false` so it reaches cross-origin iframes — same pattern as our other shims):

```javascript
(function() {
  let permission = '__PER_SITE_PERMISSION__';  // 'granted' or 'denied' from per-site toggle
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

Advantages:
- **One code path for all platforms.** No per-platform branching in webview construction.
- **No dependency on plugin internals.** Works regardless of `flutter_inappwebview` version progression.
- **Per-site control.** The polyfill template injects `notificationsEnabled` directly, so a site whose toggle is off sees `permission === 'denied'` and the constructor is a no-op.
- **Consistent UX.** All notifications go through the same Dart code path, get tagged with `siteId`, and route taps the same way.

Limitation: this polyfills the **Notification** API, not the full **Push API** (`navigator.serviceWorker.pushManager`, VAPID, etc.). Sites that gate notifications on Push API support will fall back to in-app messaging instead of notifications. This is an accepted trade-off for the v1 scope; full Push API support would require ServiceWorker push subscription handling and a server-side push relay, which is out of scope.

## Background Execution Matrix

The hard constraint: **iOS suspends apps within seconds of backgrounding**. There is no `UIBackgroundModes` flag that legitimately keeps a WKWebView running to receive WebSocket messages — `audio`/`location` get App Store rejected for misuse, `voip` requires PushKit + CallKit, `fetch` is opportunistic (~30 min), `remote-notification` requires APNs server-side. macOS and Android have real solutions; iOS does not.

| Platform | Foreground | Background | Mechanism |
|----------|-----------|-----------|-----------|
| Android (profile mode) | ✅ Real-time | ✅ Real-time | Skip `pauseWebView()` for background-active sites + foreground service keeps process alive. WebSocket connections stay open, JS timers fire, polyfill calls into `flutter_local_notifications`. |
| macOS (profile mode) | ✅ Real-time | ✅ Real-time | Skip `pauseWebView()` + opt out of `NSAppNapPriority` so the OS doesn't throttle a hidden app. WebView keeps running. |
| iOS (profile mode) | ✅ Real-time | ⚠️ ~30s grace + opportunistic fetch | See iOS Background Strategy below. |
| Legacy devices (any platform) | n/a | n/a | Feature hidden — toggles not shown. |

## iOS Background Strategy

Three options, in order of complexity. Recommendation: **start with Tier 1, document the limitation, escalate to Tier 2 only if user demand justifies it.**

### Tier 1: Foreground-only with grace-period flush (recommended for v1)

- While the app is in foreground (active or inactive but not suspended), the polyfill works normally — any loaded site, including background-active ones, can fire notifications.
- When the app backgrounds, register a `beginBackgroundTask(expirationHandler:)` that gives ~30 seconds to flush in-flight notifications. After that, iOS suspends the app and JS execution stops.
- The `backgroundActive` toggle on iOS is documented as "best-effort": notifications fire while the app is open or in the recent-tasks ~30 second window after backgrounding.
- **No server, no APNs, no privacy regression.** Honest about the limitation.

### Tier 2: Opportunistic background fetch via BGAppRefreshTask

- Schedule a `BGAppRefreshTask` for each background-active site. iOS fires it opportunistically (~15–30 min intervals at the system's discretion, more often if the user opens the app frequently).
- Each invocation gets ~30 seconds. Reload (or reuse via keepAlive) each background-active site's webview, let it poll/check for messages, fire any notifications, then complete the task.
- **Not real-time.** Useful for low-frequency notifications (email, RSS feeds) but useless for chat apps that need sub-second delivery.
- Adds Info.plist `BGTaskSchedulerPermittedIdentifiers` and minor native code (~50 lines of Swift).
- Effort: ~1 week extra, including testing the unpredictable iOS scheduling.

### Tier 3: Server-side APNs relay (NOT recommended)

- Run a backend that subscribes to W3C Web Push (with VAPID) on the user's behalf for each `backgroundActive` site, then forwards via APNs to the iOS device.
- **Real-time, but**:
  - Adds a backend dependency the app currently doesn't have.
  - Every notification flows through your server — significant privacy regression.
  - Operational burden: APNs cert management, push subscription state, message acknowledgment, retry logic.
  - Doesn't scale to F-Droid distribution model (no central server).
  - Many sites don't expose VAPID/Push API outside their own SDKs.
- Out of scope for this change. Would be a separate, much larger project that may not fit the app's privacy model at all.

### iOS UI handling

- When the user enables `backgroundActive` on iOS, show a one-time info banner: "iOS limits background execution. Notifications will arrive while WebSpace is open or in the recent-tasks list. For real-time delivery, keep WebSpace in your dock or use the macOS / Android version."
- Don't disable the toggle — foreground notifications and the 30-second grace window are still useful.

## Known Constraint: Process-Wide Proxy (Android Only)

On Android, `ProxyController.instance()` is a process-wide singleton. `setProxyOverride` applies to ALL WebViews regardless of profile. If two background-active sites have different proxy configurations, only the proxy of the currently active (foreground) site is in effect.

On iOS 17+ / macOS 14+, per-site proxy is natively supported via `WKWebsiteDataStore` — each site's proxy config attaches to its per-profile data store, so concurrent background-active sites with different proxies work correctly.

Warn the user on Android if they enable `backgroundActive` on a site whose proxy conflicts with another background-active site.

## Capabilities

### New Capabilities
- `web-push-notifications`: JavaScript Notification API polyfill, native notification display, per-site toggles, foreground service lifecycle (Android), App Nap opt-out (macOS), grace-period flush (iOS), auto-loading of background-active sites on startup, notification-tap deep linking. Profile mode only.

### Modified Capabilities
- `lazy-webview-loading`: Sites marked as background-active are auto-loaded on app startup (added to `_loadedIndices`) without requiring a manual visit first. In profile mode there are no domain-conflict restrictions, so all background-active sites auto-load freely.

## Impact

- **New dependencies**: `flutter_local_notifications` (notification display, all platforms), foreground service plugin for Android.
- **Android manifest**: New permissions (`POST_NOTIFICATIONS`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_SPECIAL_USE`), foreground service declaration, notification channel setup.
- **iOS Info.plist**: `UIBackgroundModes` (`fetch` only — for Tier 2 if pursued), notification permission usage description if needed.
- **macOS Info.plist**: No special permissions; opt out of App Nap programmatically.
- **WebViewModel** (`lib/web_view_model.dart`): Two new boolean fields (`notificationsEnabled`, `backgroundActive`) with serialization.
- **Webview factory** (`lib/services/webview.dart`): Inject Notification polyfill at DOCUMENT_START with per-site permission baked in. Register `webNotification` and `webNotificationRequestPermission` JavaScript handlers.
- **Main app state** (`lib/main.dart`):
  - Skip `pauseWebView` for background-active sites in `didChangeAppLifecycleState`.
  - Auto-load background-active sites on startup.
  - iOS: register `beginBackgroundTask` on background entry, expire after 30s.
  - macOS: opt out of App Nap when at least one background-active site is loaded.
  - Notification tap handler routes through `_setCurrentIndex`.
  - Toggle visibility gated on `_useProfiles`.
- **New service file** (`lib/services/notification_service.dart`): Channel setup, display, tap routing, platform-specific lifecycle.
- **Platform scope**:
  - Android (full real-time background)
  - macOS 14+ (full real-time background)
  - iOS 17+ (foreground + grace-period flush, optional Tier 2 escalation later)
  - Legacy devices: feature hidden
