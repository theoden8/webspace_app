## Why

Web apps like Slack, MS Teams, Telegram Web, and Google Chat use the JavaScript Notification API and Push API to deliver real-time messages, but WebSpace currently ignores all notification permission requests and pauses every webview when the app enters the background. Users who rely on WebSpace as their primary browser for these services miss all notifications, making the app unsuitable for communication-heavy workflows (issue #192).

## What Changes

- **Handle web notification permission requests**: Implement `onPermissionRequest` in the webview to let sites request notification access via the standard JavaScript `Notification.requestPermission()` API. Permission is granted or denied per-site based on a new toggle.
- **Bridge JavaScript Notification API to native notifications**: Intercept `new Notification()` calls from web pages via a JavaScript bridge and display them as native Android/iOS notifications using `flutter_local_notifications`. Tapping a notification opens the app and switches to the originating site.
- **Per-site "background active" toggle**: Add a per-site setting that keeps selected webviews running (not paused) when the app enters the background. On Android, a foreground service keeps the process alive; on iOS, use background modes with best-effort execution (iOS imposes strict limits).
- **Per-site "notifications enabled" toggle**: Add a per-site setting to control whether the site is allowed to show notifications. Defaults to off (opt-in).
- **Cookie restoration after domain-conflict clears**: After `_unloadSiteForDomainSwitch` calls `deleteAllCookies()`, restore cookies for all remaining background-active loaded sites so their running JavaScript retains authenticated sessions.

## Cookie Isolation Interaction

The CookieManager in `flutter_inappwebview` is a **process-wide singleton**. This creates fundamental constraints for background-active sites:

1. **Same-domain background sites cannot both run simultaneously.** Two `github.com` accounts cannot both be background-active because the singleton CookieManager can only hold one set of cookies per domain. Mutual exclusion (ISO-001) still applies: a domain-conflict switch disposes the conflicting site's webview regardless of its `backgroundActive` flag.

2. **Cross-domain background sites lose cookies during domain-conflict switches.** When `_unloadSiteForDomainSwitch` runs, it calls `deleteAllCookies()` — wiping the CookieManager for ALL domains, not just the conflicting one. Currently this is harmless because non-active loaded sites are paused (no JS running, no network requests). But background-active sites on other domains ARE running JS, so their fetch/XHR calls would become unauthenticated. After a domain-conflict clear, cookies must be restored for all remaining background-active sites.

3. **Notification tap triggers cookie isolation.** When the user taps a notification to switch to a site, this runs through `_setCurrentIndex`, which applies the same domain-conflict detection. If the notification's site conflicts with a currently loaded site, the standard unload-clear-restore cycle runs.

## Capabilities

### New Capabilities
- `web-push-notifications`: Covers the JavaScript Notification API bridge, native notification display, notification permission handling, per-site notification and background-active toggles, notification-tap deep linking, foreground service lifecycle, and cookie restoration for background-active sites after domain-conflict clears.

### Modified Capabilities
- `per-site-cookie-isolation`: `_unloadSiteForDomainSwitch` must restore cookies for remaining background-active loaded sites after `deleteAllCookies()`. Same-domain mutual exclusion (dispose) still applies unconditionally — `backgroundActive` does NOT exempt a site from domain conflicts.
- `lazy-webview-loading`: Sites marked as background-active should be auto-loaded on app startup (added to `_loadedIndices`) without requiring a manual visit first, so they can begin receiving notifications immediately. Domain-conflict rules apply: if two background-active sites share a domain, only one can auto-load.

## Impact

- **New dependencies**: `flutter_local_notifications` (native notification display), foreground service plugin for Android background persistence.
- **Android manifest**: New permissions (`POST_NOTIFICATIONS`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_SPECIAL_USE`), foreground service declaration, notification channel setup.
- **iOS Info.plist**: `UIBackgroundModes` entry for `remote-notification` (best-effort background).
- **WebViewModel** (`lib/web_view_model.dart`): Two new boolean fields (`notificationsEnabled`, `backgroundActive`) with serialization/deserialization.
- **Webview factory** (`lib/services/webview.dart`): New `onPermissionRequest` handler, JavaScript bridge injection for Notification API interception.
- **Main app state** (`lib/main.dart`):
  - Modified `didChangeAppLifecycleState` to skip pausing background-active webviews.
  - Modified `_unloadSiteForDomainSwitch` to restore cookies for remaining background-active sites after `deleteAllCookies()`.
  - Auto-load logic for background-active sites on startup (respecting domain-conflict rules).
  - Notification tap handler that routes through `_setCurrentIndex`.
- **New service file** (`lib/services/notification_service.dart`): Notification channel setup, display, tap routing.
- **Platform scope**: Android (full support), iOS (limited by OS background restrictions), macOS (deferred — desktop has fewer background constraints).
