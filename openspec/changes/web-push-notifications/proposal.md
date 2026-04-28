## Why

Web apps like Slack, MS Teams, Telegram Web, and Google Chat use the JavaScript Notification API and Push API to deliver real-time messages, but WebSpace currently ignores all notification permission requests and pauses every webview when the app enters the background. Users who rely on WebSpace as their primary browser for these services miss all notifications, making the app unsuitable for communication-heavy workflows (issue #192).

## What Changes

- **Handle web notification permission requests**: Implement `onPermissionRequest` in the webview to let sites request notification access via the standard JavaScript `Notification.requestPermission()` API. Permission is granted or denied per-site based on a new toggle.
- **Bridge JavaScript Notification API to native notifications**: Intercept `new Notification()` calls from web pages via a JavaScript bridge and display them as native Android/iOS notifications using `flutter_local_notifications`. Tapping a notification opens the app and switches to the originating site.
- **Per-site "background active" toggle**: Add a per-site setting that keeps selected webviews running (not paused) when the app enters the background. On Android, a foreground service keeps the process alive; on iOS, use background modes with best-effort execution (iOS imposes strict limits).
- **Per-site "notifications enabled" toggle**: Add a per-site setting to control whether the site is allowed to show notifications. Defaults to off (opt-in).

## Scope: Profile Mode Only

This feature requires native per-site profiles (`_useProfiles == true`). On legacy devices using `CookieIsolationEngine`, the notification and background-active toggles are hidden/disabled. Rationale:

- **No domain conflicts.** Profile mode (PROF-003) allows same-domain sites to coexist with fully isolated storage. Background-active sites just stay loaded in IndexedStack — no disposal, no cookie clearing, no keepAlive workarounds.
- **Per-profile ServiceWorkers.** Each profile owns its own ServiceWorker registrations, so push subscriptions are isolated per-site.
- **No cookie restoration dance.** The singleton CookieManager problem doesn't exist in profile mode. Background sites keep authenticated sessions naturally.

On legacy devices, the CookieIsolation engine's capture-nuke-restore cycle and singleton CookieManager make reliable background notifications infeasible: domain conflicts dispose webviews, `deleteAllCookies()` wipes sessions, and keepAlive'd WebViews lose authentication. Rather than ship a degraded experience, we gate the feature on profile support.

## Known Constraint: Process-Wide Proxy (Android Only)

On Android, `ProxyController.instance()` is a process-wide singleton. `setProxyOverride` applies to ALL WebViews regardless of profile. If two background-active sites have different proxy configurations, only the proxy of the currently active (foreground) site is in effect — the background site's traffic routes through the wrong proxy.

On iOS 17+ / macOS 14+, per-site proxy is natively supported via `WKWebsiteDataStore` — each site's proxy config is attached to its per-profile data store, so concurrent background-active sites with different proxies work correctly.

Recommendation: accept the Android limitation and document it. Most notification-producing sites (Slack, Teams, Telegram) won't use per-site proxies. Warn the user on Android if they enable `backgroundActive` on a site whose proxy conflicts with another background-active site.

## Capabilities

### New Capabilities
- `web-push-notifications`: JavaScript Notification API bridge, native notification display, notification permission handling, per-site notification and background-active toggles, foreground service lifecycle, auto-loading of background-active sites on startup, and notification-tap deep linking. Profile mode only.

### Modified Capabilities
- `lazy-webview-loading`: Sites marked as background-active are auto-loaded on app startup (added to `_loadedIndices`) without requiring a manual visit first. In profile mode there are no domain-conflict restrictions, so all background-active sites auto-load freely.

## Impact

- **New dependencies**: `flutter_local_notifications` (native notification display), foreground service plugin for Android background persistence.
- **Android manifest**: New permissions (`POST_NOTIFICATIONS`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_SPECIAL_USE`), foreground service declaration, notification channel setup.
- **iOS Info.plist**: `UIBackgroundModes` entry for `remote-notification` (best-effort background).
- **WebViewModel** (`lib/web_view_model.dart`): Two new boolean fields (`notificationsEnabled`, `backgroundActive`) with serialization/deserialization.
- **Webview factory** (`lib/services/webview.dart`): New `onPermissionRequest` handler, JavaScript bridge injection for Notification API interception.
- **Main app state** (`lib/main.dart`):
  - Modified `didChangeAppLifecycleState` to skip pausing background-active webviews.
  - Auto-load logic for background-active sites on startup.
  - Notification tap handler routes through `_setCurrentIndex`.
  - Toggle visibility gated on `_useProfiles`.
- **New service file** (`lib/services/notification_service.dart`): Notification channel setup, display, tap routing.
- **Platform scope**: Android (full support with profiles), iOS 17+ (profile support, limited background), macOS 14+ (profile support, deferred background). Legacy devices: feature hidden.
