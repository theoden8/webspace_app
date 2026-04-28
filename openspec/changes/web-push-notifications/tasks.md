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

- [ ] 5.1 In the per-site settings screen (`lib/screens/site_settings.dart` or wherever per-site toggles live), add `SwitchListTile` for `notificationsEnabled`. Subtitle: "Allow this site to show system notifications."
- [ ] 5.2 Add `SwitchListTile` for `backgroundPoll`. Subtitle (iOS): "Check for updates periodically (~15-30 min between checks while app is closed)." Subtitle (Android proxy-eligible): "Keep checking for updates while app is backgrounded." Subtitle (Android proxy-conflict): "Cannot enable: another site with a different proxy is already polling in background." Disable in the conflict case.
- [ ] 5.3 Gate visibility of both toggles on `_useProfiles` (passed in or read via a getter on `_WebSpacePageState`). When `_useProfiles == false`, do not render either tile.
- [ ] 5.4 Persist toggle changes via `setState` + `_saveAppState()`.
- [ ] 5.5 On enabling `backgroundPoll`, call `NotificationService.requestPermission()` so the OS dialog appears at a moment of clear user intent (rather than waiting for the first notification).

## 6. Lifecycle: skip pause for background-poll sites

- [ ] 6.1 Modify `_WebSpacePageState.didChangeAppLifecycleState` so that when state is `paused`, only sites with `backgroundPoll == false` are paused. Background-poll sites stay active.
- [ ] 6.2 On state `resumed`, resume only the currently active site (existing behavior); background-poll sites were never paused so no-op.
- [ ] 6.3 Manual test: enable `backgroundPoll` on the fixture site, send a delayed notification, background the app, verify it arrives.

## 7. Auto-load background-poll sites at startup

- [ ] 7.1 In `_restoreAppState`, after sites are loaded from `SharedPreferences`, iterate `_webViewModels` and add to `_loadedIndices` every site with `backgroundPoll == true` (without changing `_currentIndex`).
- [ ] 7.2 The IndexedStack will then construct those webviews on first build; they'll initialize their profile and start running JS.
- [ ] 7.3 Update LAZY-001 delta scenarios test if applicable (see `openspec/changes/web-push-notifications/specs/lazy-webview-loading/spec.md`).
- [ ] 7.4 Manual test: restart app with background-poll sites configured; verify they appear loaded (not blank placeholders) immediately after startup.

## 8. Foreground active polling timer

- [ ] 8.1 Add a `Timer? _foregroundPollTimer` field to `_WebSpacePageState`.
- [ ] 8.2 Start the timer in `initState` (or after `_restoreAppState` completes): `Timer.periodic(Duration(minutes: 5), _onForegroundPollTick)`.
- [ ] 8.3 In `_onForegroundPollTick`, iterate `_webViewModels` and for each site where `backgroundPoll == true && index != _currentIndex && _loadedIndices.contains(index)`, call `model.controller?.reload()`.
- [ ] 8.4 Cancel the timer on `didChangeAppLifecycleState(.paused)` and re-create on `.resumed`.
- [ ] 8.5 Cancel and null in `dispose()`.
- [ ] 8.6 Unit test the iteration logic (which indices to refresh) by extracting it to a pure function in a new `lib/services/foreground_poll_engine.dart`.

## 9. Android foreground service

- [ ] 9.1 Add `POST_NOTIFICATIONS`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_SPECIAL_USE` permissions to `android/app/src/main/AndroidManifest.xml`.
- [ ] 9.2 Declare a foreground service with `android:foregroundServiceType="specialUse"` in the manifest. Service class: `org.codeberg.theoden8.webspace.BackgroundPollService`.
- [ ] 9.3 Implement `BackgroundPollService.kt` — minimal foreground service that calls `startForeground(...)` with a persistent notification (channel id `webspace_background_poll`, title "WebSpace is checking N sites for updates").
- [ ] 9.4 Add a Dart-side wrapper `lib/services/android_foreground_service.dart` with `start(siteCount)` / `stop()` methods communicating via `MethodChannel('org.codeberg.theoden8.webspace/background-poll')`.
- [ ] 9.5 Add a Kotlin plugin `WebSpaceBackgroundPollPlugin.kt` registered alongside existing plugins in `MainActivity.kt`. Method handlers: `start(count)` starts the service, `stop()` stops it.
- [ ] 9.6 Verify F-Droid build is clean: run `scripts/check_no_gms.sh build/app/outputs/flutter-apk/app-fdroid-release.apk` after `fvm flutter build apk --flavor fdroid --release`.

## 10. Android proxy conflict detection

- [ ] 10.1 In `_WebSpacePageState`, add a method `bool _canEnableBackgroundPoll(WebViewModel target)` that returns false iff another site with `backgroundPoll == true` has a different `proxySettings`.
- [ ] 10.2 Use `_canEnableBackgroundPoll` to gate the toggle in the per-site settings UI (task 5.2).
- [ ] 10.3 When `_canEnableBackgroundPoll` is false, the toggle is disabled with the explanatory subtitle.
- [ ] 10.4 Unit tests: extract the conflict detection to a pure function in `lib/services/proxy_conflict_engine.dart`. Test scenarios from NOTIF-005-A.

## 11. Android background lifecycle

- [ ] 11.1 In `_WebSpacePageState`, add `_updateForegroundService()` — recompute whether any background-poll site is loaded and proxy-eligible; start or stop the foreground service accordingly.
- [ ] 11.2 Call `_updateForegroundService()` after: `_setCurrentIndex` settles, site addition/deletion, `backgroundPoll` toggle change, app pause/resume.
- [ ] 11.3 Manual test (Android): enable `backgroundPoll` on a non-proxy site; verify the persistent notification appears. Disable; verify it disappears.

## 12. iOS background lifecycle

- [ ] 12.1 Add `flutter_local_notifications` setup for iOS (`UNUserNotificationCenter` config).
- [ ] 12.2 In `_WebSpacePageState.didChangeAppLifecycleState(.paused)`, on iOS call a new platform method `BackgroundPollService.beginGraceTask()` that wraps `UIApplication.shared.beginBackgroundTask(expirationHandler:)`.
- [ ] 12.3 On `.resumed`, call `endBackgroundTask` to release the grace window early.
- [ ] 12.4 Add Swift glue in `ios/Runner/AppDelegate.swift` for the method channel and `beginBackgroundTask` handling.
- [ ] 12.5 Add `BGTaskSchedulerPermittedIdentifiers` array to `ios/Runner/Info.plist` with identifier `org.codeberg.theoden8.webspace.refresh`.
- [ ] 12.6 Add `UIBackgroundModes` array to Info.plist including `fetch`.

## 13. iOS BGAppRefreshTask

- [ ] 13.1 In `AppDelegate.swift`, register the `BGAppRefreshTask` handler via `BGTaskScheduler.shared.register(forTaskWithIdentifier: "...refresh", using: nil) { task in ... }` in `application(_:didFinishLaunchingWithOptions:)`.
- [ ] 13.2 Implement the handler: launch a Flutter background isolate (or post a method-channel call to the main isolate) that loads each background-poll site's webview, lets it run for ~25 seconds, then calls `task.setTaskCompleted(success: true)`.
- [ ] 13.3 Schedule the next refresh on `applicationDidEnterBackground` via `BGTaskScheduler.shared.submit(BGAppRefreshTaskRequest)`.
- [ ] 13.4 Cancel scheduled tasks on `applicationWillTerminate` and when `backgroundPoll` is disabled on the last eligible site.
- [ ] 13.5 Manual test: enable `backgroundPoll`, send the app to background, leave it 30+ min on WiFi/charging, verify the task fires (check `LogService` output via Console.app).
- [ ] 13.6 If FlutterEngine init in the BGAppRefreshTask handler is brittle, fall back to native-only handling: just bring up a pre-built FlutterEngine with a designated entrypoint that polls and fires notifications. Document the chosen approach in `design.md` if it changes.

## 14. iOS first-use info dialog

- [ ] 14.1 Add a SharedPreferences flag `ios_background_poll_dialog_shown` (default false).
- [ ] 14.2 When the user first toggles `backgroundPoll == true` on iOS and the flag is false, show an `AlertDialog` with the text from spec NOTIF-005-I.
- [ ] 14.3 On dialog dismiss, set the flag to true.
- [ ] 14.4 Test: first toggle shows dialog; subsequent toggles don't.

## 15. Notification tap routing

- [ ] 15.1 Wire `NotificationService`'s tap callback to a method on `_WebSpacePageState`: `void _onNotificationTapped(String siteId)`.
- [ ] 15.2 Implementation: find the index in `_webViewModels` where `model.siteId == siteId`. If found, call `await _setCurrentIndex(index)`. If not found (site deleted between notification and tap), log a warning and ignore.
- [ ] 15.3 Manual test: send notification, switch to another site, tap notification, verify the correct site becomes active.

## 16. iOS notification permission UX

- [ ] 16.1 First time `notificationsEnabled` is set to true on any site OR `backgroundPoll` is set to true on iOS, call `NotificationService.requestPermission()`.
- [ ] 16.2 If permission is denied, surface this in the per-site UI: subtitle "Notifications denied. Enable in Settings → WebSpace → Notifications."
- [ ] 16.3 If permission is granted, no further action.

## 17. Manual test fixture verification

- [ ] 17.1 Build for iOS, install on iOS 17+ device.
- [ ] 17.2 Import `test/fixtures/notification_test.html` as a site (via "Import HTML file").
- [ ] 17.3 Walk through all "Manual Test Procedure" entries in the spec — polyfill, permission, display, tap, foreground refresh, iOS grace flush, BGAppRefreshTask, multiple sites, edge cases, legacy device.
- [ ] 17.4 Repeat on Android with profile mode (System WebView 110+).

## 18. Documentation

- [ ] 18.1 Update root `README.md` and `CLAUDE.md` to mention the new `notificationsEnabled` / `backgroundPoll` per-site fields and the platform-specific behavior.
- [ ] 18.2 Add an entry to the spec table in `CLAUDE.md` for `web-push-notifications`.
- [ ] 18.3 Run `npx openspec validate --no-interactive --all` and verify all specs pass.

## 19. Pre-archive validation

- [ ] 19.1 All requirements from `specs/web-push-notifications/spec.md` and `specs/lazy-webview-loading/spec.md` have implementing code paths.
- [ ] 19.2 `flutter test` passes (no regressions).
- [ ] 19.3 `flutter analyze` is clean (no new warnings).
- [ ] 19.4 F-Droid build still passes `scripts/check_no_gms.sh`.
- [ ] 19.5 Manual test procedure (task 17.3) passes on both platforms.
- [ ] 19.6 Run `npx openspec verify --change web-push-notifications` (or equivalent) before archiving.
