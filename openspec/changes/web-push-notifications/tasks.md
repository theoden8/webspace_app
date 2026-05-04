## 1. Data model and persistence

- [x] 1.1 Add `notificationsEnabled` (bool, default false) and `backgroundPoll` (bool, default false) fields to `WebViewModel` in `lib/web_view_model.dart`.
- [x] 1.2 Update `WebViewModel.toJson` to serialize both fields.
- [x] 1.3 Update `WebViewModel.fromJson` to deserialize with defaults `false` when keys are absent (legacy data).
- [x] 1.4 Add unit tests in `test/web_view_model_test.dart` covering the new fields' round-trip serialization.
- [x] 1.5 Run `flutter test test/settings_backup_test.dart` to confirm per-site backup/restore round-trip still passes (no global registry changes needed; these are per-site fields).

## 2. JavaScript Notification API polyfill

- [x] 2.1 Add a constant `_notificationPolyfillScript` template string in `lib/services/webview.dart` matching the polyfill in design D1, with `__PER_SITE_PERMISSION__` and `__SITE_ID__` placeholders.
- [x] 2.2 In `WebViewFactory.createWebView`, build the polyfill script by substituting placeholders from `config.siteId` and `config.notificationsEnabled`. Add as `inapp.UserScript` with `injectionTime: AT_DOCUMENT_START` and `forMainFrameOnly: false`.
- [x] 2.3 Pass `notificationsEnabled` through `WebViewConfig` and the `getWebView` parameter list (also update `launchUrl` and `InAppWebViewScreen` per CLAUDE.md "per-site settings MUST apply to nested webviews").
- [x] 2.4 Add a unit test in `test/notification_polyfill_test.dart` that verifies the substitution: given `siteId="abc"` and `notificationsEnabled=true`, the rendered script contains `'granted'` and `'abc'` and not the placeholders.

## 3. NotificationService

- [x] 3.1 Add `flutter_local_notifications` to `pubspec.yaml`.
- [x] 3.2 Create `lib/services/notification_service.dart` as a singleton wrapper around `FlutterLocalNotificationsPlugin`.
- [x] 3.3 Implement `NotificationService.init()` — initialize the plugin, set up a single notification channel (`webspace_web_notifications`), register the tap handler that decodes payload `{siteId: ...}` and calls a Dart callback.
- [x] 3.4 Implement `NotificationService.show(siteId, title, body, iconUrl?, tag?)` — display a notification with `siteId` in the payload, tagged with `tag` (or `siteId` as fallback) for OS-level deduplication.
- [x] 3.5 Wire the notification icon: prefer the cached site favicon from `IconService` for the site identified by `siteId`; fall back to app icon if unavailable. (Per design Q5, ignore site-provided `options.icon` for v1.)
- [x] 3.6 Add `NotificationService.requestPermission()` for explicit OS-permission gate; called lazily on first notification.
- [x] 3.7 Unit tests with a mock plugin: verify `show()` calls the plugin with the right channel and payload, `init()` registers handlers exactly once.

## 4. JavaScript handler registration

- [x] 4.1 In `WebViewFactory.createWebView`'s `onWebViewCreated`, register `webNotification` JS handler. Body: lookup the corresponding `WebViewModel` by `siteId`, validate `notificationsEnabled`, call `NotificationService.show(...)` with title/body/tag from the JS payload.
- [x] 4.2 Register `webNotificationRequestPermission` JS handler. Body: return `'granted'` if `notificationsEnabled == true` for that site, else `'denied'`. (No OS-level prompt at this stage — that happens lazily on first actual notification.)
- [x] 4.3 Plumb the `WebViewModel` lookup through the factory: pass a `WebViewModel? Function(String siteId)` resolver into `createWebView` so handlers can find the originating site. Wire it from `_WebSpacePageState`.
- [x] 4.4 Test: load `test/fixtures/notification_test.html` in an integration test (if feasible without a device) or document manual test steps.

## 5. Per-site UI toggles

- [x] 5.1 In the per-site settings screen (`lib/screens/site_settings.dart` or wherever per-site toggles live), add `SwitchListTile` for `notificationsEnabled`. Subtitle: "Allow this site to show system notifications."
- [x] 5.2 Add `SwitchListTile` for `backgroundPoll`. Subtitle (iOS): "Check for updates periodically (~15-30 min between checks while app is closed)." Subtitle (Android proxy-eligible): "Keep checking for updates while app is backgrounded." Subtitle (Android proxy-conflict): "Cannot enable: another site with a different proxy is already polling in background." Disable in the conflict case.
- [x] 5.3 Gate visibility of both toggles on `_useContainers` (passed in or read via a getter on `_WebSpacePageState`). When `_useContainers == false`, do not render either tile.
- [x] 5.4 Persist toggle changes via `setState` + `_saveAppState()`.
- [x] 5.5 On enabling `notificationsEnabled` (covers the folded `backgroundPoll`), call `NotificationService.requestPermission()` so the OS dialog appears at a moment of clear user intent. Implemented in `lib/screens/settings.dart`: after the iOS info dialog dismisses, the toggle's `onChanged` invokes `NotificationService.instance.requestPermission()`.

## 6. Lifecycle: skip pause for background-poll sites

- [x] 6.1 Modify `_WebSpacePageState.didChangeAppLifecycleState` so that when state is `paused`, only sites with `backgroundPoll == false` are paused. Background-poll sites stay active.
- [x] 6.2 On state `resumed`, resume only the currently active site (existing behavior); background-poll sites were never paused so no-op.
- [ ] 6.3 Manual test: enable `backgroundPoll` on the fixture site, send a delayed notification, background the app, verify it arrives.

## 7. Auto-load background-poll sites at startup

- [x] 7.1 In `_restoreAppState`, after sites are loaded from `SharedPreferences`, iterate `_webViewModels` and add to `_loadedIndices` every site with `backgroundPoll == true` (without changing `_currentIndex`).
- [x] 7.2 The IndexedStack will then construct those webviews on first build; they'll initialize their profile and start running JS.
- [x] 7.3 LAZY-001 delta updated to reflect the post-c6bc8f5 naming (`notificationsEnabled` replaces `backgroundActive`); auto-load happens in `_restoreAppState`'s 3-line loop. Existing `web_view_model_test` covers field round-trip; the auto-load is straight-line code with no engine to test in isolation.
- [ ] 7.4 Manual test: restart app with background-poll sites configured; verify they appear loaded (not blank placeholders) immediately after startup.

## 8. Foreground active polling timer

- [x] 8.1 Add a `Timer? _foregroundPollTimer` field to `_WebSpacePageState`.
- [x] 8.2 Start the timer in `initState` (or after `_restoreAppState` completes): `Timer.periodic(Duration(minutes: 5), _onForegroundPollTick)`.
- [x] 8.3 In `_onForegroundPollTick`, iterate `_webViewModels` and for each site where `backgroundPoll == true && index != _currentIndex && _loadedIndices.contains(index)`, call `model.controller?.reload()`.
- [x] 8.4 Cancel the timer on `didChangeAppLifecycleState(.paused)` and re-create on `.resumed`.
- [x] 8.5 Cancel and null in `dispose()`.
- [x] 8.6 Unit test the iteration logic (which indices to refresh) by extracting it to a pure function in a new `lib/services/foreground_poll_engine.dart`.

## 9. Android foreground service

- [x] 9.1 `POST_NOTIFICATIONS` was already in [`AndroidManifest.xml`](../../../android/app/src/main/AndroidManifest.xml). Added `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_SPECIAL_USE`.
- [x] 9.2 Declared the service with `android:foregroundServiceType="specialUse"` in the manifest, plus the required `PROPERTY_SPECIAL_USE_FGS_SUBTYPE` `<property>` describing the use case to the OS.
- [x] 9.3 Implemented [`BackgroundPollService.kt`](../../../android/app/src/main/kotlin/org/codeberg/theoden8/webspace/BackgroundPollService.kt) — `startForeground(...)` with a low-importance, ongoing, silent notification on channel `webspace_background_poll`. Uses `ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE` on Q+. `START_NOT_STICKY` so OS-kill doesn't restart with a null intent.
- [x] 9.4 Added [`AndroidForegroundService`](../../../lib/services/android_foreground_service.dart) — Dart wrapper around the method channel `org.codeberg.theoden8.webspace/background-poll`. `start(count)` is dedupe'd by last count; both methods are no-ops on non-Android.
- [x] 9.5 Added [`WebSpaceBackgroundPollPlugin.kt`](../../../android/app/src/main/kotlin/org/codeberg/theoden8/webspace/WebSpaceBackgroundPollPlugin.kt) and registered it in [`MainActivity.configureFlutterEngine`](../../../android/app/src/main/kotlin/org/codeberg/theoden8/webspace/MainActivity.kt). The plugin starts/stops the service via `startForegroundService`; STOP routes through `onStartCommand` so `stopForeground(REMOVE)` runs and the persistent notification disappears immediately.
- [ ] 9.6 Verify F-Droid build is clean: run `scripts/check_no_gms.sh build/app/outputs/flutter-apk/app-fdroid-release.apk` after `fvm flutter build apk --flavor fdroid --release`.

## 10. Android proxy conflict detection

- [x] 10.1 Added `_notificationsBlockedBySite(target)` in [`lib/main.dart`](../../../lib/main.dart) — wraps the engine and returns the blocking site's display name (or `null` if no conflict). Android-only.
- [x] 10.2 Both `SettingsScreen` call sites in `main.dart` pass the result as `notificationsBlockedBySite`.
- [x] 10.3 The Notifications `SwitchListTile` in [`lib/screens/settings.dart`](../../../lib/screens/settings.dart) renders disabled with an explanatory subtitle when blocked. Already-on toggles can still be turned off — the gate only forbids enabling.
- [x] 10.4 Pure-Dart [`ProxyConflictEngine`](../../../lib/services/proxy_conflict_engine.dart) exposes `fingerprint`, `canEnable`, and `firstConflict`. Unit-covered by [`test/proxy_conflict_engine_test.dart`](../../../test/proxy_conflict_engine_test.dart) — all NOTIF-005-A scenarios (multiple DEFAULT, same custom proxy, SOCKS5 vs HTTP, DEFAULT vs custom, mismatched credentials).

## 11. Android background lifecycle

- [x] 11.1 Added `_updateForegroundService()` in [`lib/main.dart`](../../../lib/main.dart) — counts notification sites currently in `_loadedIndices` and starts/stops the foreground service. Idempotent on the native side.
- [x] 11.2 Called from `_handlePerSiteSettingsSaved` (toggle change), the tail of `_setCurrentIndex` (loaded-set mutations), `_deleteSite` (last notification site removed), and both branches of `didChangeAppLifecycleState` (so the service is up before the activity is hidden, and re-evaluated after a memory-pressure-driven unload during background).
- [ ] 11.3 Manual test (Android): enable `notificationsEnabled` on a non-proxy site; verify the persistent notification appears. Disable; verify it disappears.

## 12. iOS background lifecycle

- [x] 12.1 Add `flutter_local_notifications` setup for iOS (`UNUserNotificationCenter` config).
- [x] 12.2 In `_WebSpacePageState.didChangeAppLifecycleState(.paused)`, on iOS call a new platform method `BackgroundTaskService.beginGracePeriod()` that wraps `UIApplication.shared.beginBackgroundTask(expirationHandler:)`. Implemented in `lib/services/background_task_service.dart` + `ios/Runner/BackgroundTaskPlugin.swift`.
- [x] 12.3 On `.resumed`, call `endGracePeriod` to release the grace window early.
- [x] 12.4 Add Swift glue in `ios/Runner/BackgroundTaskPlugin.swift` (registered from `AppDelegate.swift`) for the method channel and `beginBackgroundTask` handling.
- [x] 12.5 Add `BGTaskSchedulerPermittedIdentifiers` array to `ios/Runner/Info.plist` with identifier `org.codeberg.theoden8.webspace.notification-refresh`.
- [x] 12.6 Add `UIBackgroundModes` array to Info.plist including `fetch` and `processing`.

## 13. iOS BGAppRefreshTask

- [x] 13.1 In `AppDelegate.swift`, register the `BGAppRefreshTask` handler via `BGTaskScheduler.shared.register(...)` in `application(_:didFinishLaunchingWithOptions:)`. Implementation in `BackgroundTaskPlugin.registerLaunchHandler`.
- [x] 13.2 Implement the handler: forward the task to Dart via `onBackgroundRefresh`, which calls `_refreshNotificationSites` to reload every loaded notification site so its page JS can fire pending notifications. Dart calls `bgRefreshDidComplete(success:)` to ack iOS.
- [x] 13.3 Schedule the next refresh on `applicationDidEnterBackground` via `BackgroundTaskService.scheduleNextRefresh()`. Also re-scheduled at the tail of every refresh handler so the cycle continues.
- [x] 13.4 Cancel scheduled tasks via `BackgroundTaskService.cancelScheduledRefreshes()` (available; not currently called automatically since iOS drops the schedule when the app is force-quit anyway).
- [ ] 13.5 Manual test: enable `notificationsEnabled`, send the app to background, leave it 30+ min on WiFi/charging, verify the task fires (check `LogService` output via Console.app).
- [ ] 13.6 If FlutterEngine init in the BGAppRefreshTask handler is brittle, fall back to native-only handling: just bring up a pre-built FlutterEngine with a designated entrypoint that polls and fires notifications. Document the chosen approach in `design.md` if it changes.

## 14. iOS first-use info dialog

- [x] 14.1 Add a SharedPreferences flag `iosNotificationLimitsInfoShown` (default false).
- [x] 14.2 When the user first toggles `notificationsEnabled == true` on iOS and the flag is false, show an `AlertDialog` with the text from spec NOTIF-005-I (implemented in `maybeShowIosNotificationLimitsDialog` in `lib/screens/settings.dart`).
- [x] 14.3 On dialog dismiss, set the flag to true.
- [x] 14.4 Test: see `test/ios_notification_info_dialog_test.dart`.

## 15. Notification tap routing

- [x] 15.1 Wire `NotificationService`'s tap callback to a method on `_WebSpacePageState`: `void _onNotificationTapped(String siteId)`.
- [x] 15.2 Implementation: find the index in `_webViewModels` where `model.siteId == siteId`. If found, call `await _setCurrentIndex(index)`. If not found (site deleted between notification and tap), log a warning and ignore.
- [ ] 15.3 Manual test: send notification, switch to another site, tap notification, verify the correct site becomes active.

## 16. iOS notification permission UX

- [x] 16.1 First time `notificationsEnabled` is set to true on any site, call `NotificationService.requestPermission()`. Implemented in `lib/screens/settings.dart`'s notification toggle `onChanged`. (`backgroundPoll` is folded into `notificationsEnabled` per c6bc8f5.)
- [x] 16.2 If permission is denied, surface this in the per-site UI: subtitle "Notifications denied. Enable in Settings → ...". `NotificationService` exposes `permissionGranted` + `addPermissionListener`; the per-site settings widget swaps the subtitle reactively.
- [x] 16.3 If permission is granted, no further action — subtitle stays at the default explanatory text.

## 17. Manual test fixture verification

- [ ] 17.1 Build for iOS, install on iOS 17+ device.
- [ ] 17.2 Import `test/fixtures/notification_test.html` as a site (via "Import HTML file").
- [ ] 17.3 Walk through all "Manual Test Procedure" entries in the spec — polyfill, permission, display, tap, foreground refresh, iOS grace flush, BGAppRefreshTask, multiple sites, edge cases, legacy device.
- [ ] 17.4 Repeat on Android with container mode (System WebView 110+).

## 18. Documentation

- [x] 18.1 Updated `CLAUDE.md` with a "Per-site web push notifications" section covering polyfill, no-pause, auto-load, retention priority, and the iOS background contract. Root README is intentionally untouched (it already covers per-site features at a higher level).
- [x] 18.2 Added `web-push-notifications` row to the spec table in `CLAUDE.md`.
- [x] 18.3 `npx openspec validate --no-interactive --all` reports `40 passed, 0 failed`. As part of this pass, fixed pre-existing `per-site-cookie-isolation` errors (ISO-010/011/012 sat outside the `## Requirements` section; ISO-012 needed a leading SHALL).

## 19. Pre-archive validation

- [ ] 19.1 All requirements from `specs/web-push-notifications/spec.md` and `specs/lazy-webview-loading/spec.md` have implementing code paths.
- [ ] 19.2 `flutter test` passes (no regressions).
- [ ] 19.3 `flutter analyze` is clean (no new warnings).
- [ ] 19.4 F-Droid build still passes `scripts/check_no_gms.sh`.
- [ ] 19.5 Manual test procedure (task 17.3) passes on both platforms.
- [ ] 19.6 Run `npx openspec verify --change web-push-notifications` (or equivalent) before archiving.
