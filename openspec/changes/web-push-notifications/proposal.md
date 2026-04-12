## Why

Web apps like Slack, MS Teams, Telegram Web, and Google Chat use the JavaScript Notification API and Push API to deliver real-time messages, but WebSpace currently ignores all notification permission requests and pauses every webview when the app enters the background. Users who rely on WebSpace as their primary browser for these services miss all notifications, making the app unsuitable for communication-heavy workflows (issue #192).

## What Changes

- **Handle web notification permission requests**: Implement `onPermissionRequest` in the webview to let sites request notification access via the standard JavaScript `Notification.requestPermission()` API. Permission is granted or denied per-site based on a new toggle.
- **Bridge JavaScript Notification API to native notifications**: Intercept `new Notification()` calls from web pages via a JavaScript bridge and display them as native Android/iOS notifications using `flutter_local_notifications`. Tapping a notification opens the app and switches to the originating site.
- **Per-site "background active" toggle**: Add a per-site setting that keeps selected webviews running (not paused) when the app enters the background. On Android, a foreground service keeps the process alive; on iOS, use background modes with best-effort execution (iOS imposes strict limits).
- **Per-site "notifications enabled" toggle**: Add a per-site setting to control whether the site is allowed to show notifications. Defaults to off (opt-in).

## Capabilities

### New Capabilities
- `web-push-notifications`: Covers the JavaScript Notification API bridge, native notification display, notification permission handling, per-site notification toggle, notification-tap deep linking back to the originating site, and the per-site background-active toggle with foreground service lifecycle.

### Modified Capabilities
- `per-site-cookie-isolation`: Background-active sites must remain loaded across site switches even when a domain conflict occurs. Currently, conflicting sites are fully disposed. With background-active sites, the conflicting background site's cookies are saved and the webview is paused (not disposed), then restored when the foreground site is deselected. This changes the disposal policy for background-flagged sites.
- `lazy-webview-loading`: Sites marked as background-active should be auto-loaded on app startup (added to `_loadedIndices`) without requiring a manual visit first, so they can begin receiving notifications immediately.

## Impact

- **New dependencies**: `flutter_local_notifications` (native notification display), `android_alarm_manager_plus` or foreground service plugin for Android background persistence.
- **Android manifest**: New permissions (`POST_NOTIFICATIONS`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_SPECIAL_USE`), foreground service declaration, notification channel setup.
- **iOS Info.plist**: `UIBackgroundModes` entry for `remote-notification` (best-effort background).
- **WebViewModel** (`lib/web_view_model.dart`): Two new boolean fields (`notificationsEnabled`, `backgroundActive`) with serialization/deserialization.
- **Webview factory** (`lib/services/webview.dart`): New `onPermissionRequest` handler, JavaScript bridge injection for Notification API interception.
- **Main app state** (`lib/main.dart`): Modified lifecycle handler to skip pausing background-active webviews, modified `_setCurrentIndex` to pause (not dispose) background-active sites on domain conflict, auto-load logic for background-active sites on startup.
- **New service file** (`lib/services/notification_service.dart`): Notification channel setup, display, tap routing.
- **Platform scope**: Android (full support), iOS (limited by OS background restrictions), macOS (deferred — desktop has fewer background constraints).
