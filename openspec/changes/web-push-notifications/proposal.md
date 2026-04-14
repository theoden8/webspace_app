## Why

Web apps like Slack, MS Teams, Telegram Web, and Google Chat use the JavaScript Notification API and Push API to deliver real-time messages, but WebSpace currently ignores all notification permission requests and pauses every webview when the app enters the background. Users who rely on WebSpace as their primary browser for these services miss all notifications, making the app unsuitable for communication-heavy workflows (issue #192).

## What Changes

- **Handle web notification permission requests**: Implement `onPermissionRequest` in the webview to let sites request notification access via the standard JavaScript `Notification.requestPermission()` API. Permission is granted or denied per-site based on a new toggle.
- **Bridge JavaScript Notification API to native notifications**: Intercept `new Notification()` calls from web pages via a JavaScript bridge and display them as native Android/iOS notifications using `flutter_local_notifications`. Tapping a notification opens the app and switches to the originating site.
- **Per-site "background active" toggle**: Add a per-site setting that keeps selected webviews running (not paused) when the app enters the background. On Android, a foreground service keeps the process alive; on iOS, use background modes with best-effort execution (iOS imposes strict limits).
- **Per-site "notifications enabled" toggle**: Add a per-site setting to control whether the site is allowed to show notifications. Defaults to off (opt-in).
- **InAppWebViewKeepAlive for background-active sites**: Use `flutter_inappwebview`'s built-in `InAppWebViewKeepAlive` to preserve native WebView instances for background-active sites when they are removed from the widget tree (e.g., due to domain conflict). This keeps JS execution, WebSocket connections, and DOM state alive without the widget being mounted, enabling notification delivery even after the site is removed from IndexedStack.
- **Cookie restoration after domain-conflict clears**: After `_unloadSiteForDomainSwitch` calls `deleteAllCookies()`, restore cookies for all remaining background-active sites (whether kept alive via keepAlive or still in IndexedStack) so their running JavaScript retains authenticated sessions.

## Cookie Isolation Interaction

The CookieManager in `flutter_inappwebview` is a **process-wide singleton**. This creates fundamental constraints for background-active sites:

1. **Same-domain background sites cannot both run simultaneously.** Two `github.com` accounts cannot both be background-active because the singleton CookieManager can only hold one set of cookies per domain. However, `InAppWebViewKeepAlive` allows preserving the native WebView: on domain conflict, the background-active site's widget is removed from the tree and its cookies are captured, but the native WebView instance survives. When the user switches back, the same native WebView is re-attached (no reload, no lost state) and cookies are restored. JS timers and WebSocket connections stay alive through the keepAlive, but HTTP requests during the conflict window will lack correct cookies — this is an accepted trade-off vs. full disposal.

2. **Cross-domain background sites lose cookies during domain-conflict switches.** When `_unloadSiteForDomainSwitch` runs, it calls `deleteAllCookies()` — wiping the CookieManager for ALL domains. Background-active sites on other domains ARE running JS (either in IndexedStack or via keepAlive), so their fetch/XHR calls would become unauthenticated. After a domain-conflict clear, cookies must be restored for all remaining background-active sites.

3. **Notification tap triggers cookie isolation.** When the user taps a notification to switch to a site, this runs through `_setCurrentIndex`, which applies the same domain-conflict detection. If the notification's site conflicts with a currently loaded site, the standard unload-clear-restore cycle runs.

## InAppWebViewKeepAlive Design

`InAppWebViewKeepAlive` is a built-in feature of `flutter_inappwebview` (already a dependency at `^6.1.0+1`) that preserves the native WebView when its Flutter widget is removed from the tree. Key constraints:

- **One active widget per keepAlive token.** Only one `InAppWebView` widget can render a given keepAlive instance at a time. This is compatible with our IndexedStack model (only one widget visible) and with domain-conflict removal (widget removed from tree, native WebView preserved).
- **Each background-active site gets its own keepAlive token.** Stored on `WebViewModel` alongside the existing `controller` and `webview` fields.
- **Non-background-active sites do NOT use keepAlive.** They continue with the current dispose-on-conflict behavior to minimize resource usage.
- **keepAlive is created when `backgroundActive` is enabled** and disposed when `backgroundActive` is disabled or the site is deleted.

This replaces the need for a separate background execution mechanism for preserving WebView state. The foreground service (Android) is still needed to prevent OS from killing the process, but the WebView lifecycle is handled by keepAlive.

## Capabilities

### New Capabilities
- `web-push-notifications`: Covers the JavaScript Notification API bridge, native notification display, notification permission handling, per-site notification and background-active toggles, InAppWebViewKeepAlive integration for background-active sites, notification-tap deep linking, foreground service lifecycle, and cookie restoration for background-active sites after domain-conflict clears.

### Modified Capabilities
- `per-site-cookie-isolation`: `_unloadSiteForDomainSwitch` changes: background-active sites use keepAlive (detach widget, preserve native WebView) instead of full disposal. After `deleteAllCookies()`, restore cookies for all remaining background-active sites. Same-domain mutual exclusion still applies — only the cookie state and widget are affected, not the keepAlive'd native WebView.
- `lazy-webview-loading`: Sites marked as background-active should be auto-loaded on app startup (added to `_loadedIndices`) without requiring a manual visit first, so they can begin receiving notifications immediately. Domain-conflict rules apply: if two background-active sites share a domain, only one can auto-load.

## Impact

- **New dependencies**: `flutter_local_notifications` (native notification display), foreground service plugin for Android background persistence.
- **No new dependency for keepAlive**: `InAppWebViewKeepAlive` is part of `flutter_inappwebview ^6.1.0+1` (already in pubspec.yaml).
- **Android manifest**: New permissions (`POST_NOTIFICATIONS`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_SPECIAL_USE`), foreground service declaration, notification channel setup.
- **iOS Info.plist**: `UIBackgroundModes` entry for `remote-notification` (best-effort background).
- **WebViewModel** (`lib/web_view_model.dart`): New fields — `notificationsEnabled` (bool), `backgroundActive` (bool), `keepAlive` (`InAppWebViewKeepAlive?`). Serialization/deserialization for the boolean fields; keepAlive is runtime-only (not persisted, recreated on startup for backgroundActive sites).
- **Webview factory** (`lib/services/webview.dart`): Accept optional `keepAlive` parameter in `WebViewConfig`, pass through to `InAppWebView(keepAlive: ...)`. New `onPermissionRequest` handler, JavaScript bridge injection for Notification API interception.
- **Main app state** (`lib/main.dart`):
  - Modified `didChangeAppLifecycleState` to skip pausing background-active webviews.
  - Modified `_unloadSiteForDomainSwitch`: for background-active sites, remove widget from tree but do NOT null the keepAlive token (native WebView preserved). For non-background-active sites, existing dispose behavior.
  - After `deleteAllCookies()`, restore cookies for all remaining background-active sites.
  - Auto-load logic for background-active sites on startup (respecting domain-conflict rules).
  - Notification tap handler that routes through `_setCurrentIndex`.
- **New service file** (`lib/services/notification_service.dart`): Notification channel setup, display, tap routing.
- **Platform scope**: Android (full support), iOS (limited by OS background restrictions), macOS (supported by keepAlive, limited background execution).
