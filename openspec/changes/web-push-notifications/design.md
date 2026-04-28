## Context

WebSpace currently ignores all `Notification.requestPermission()` calls and pauses every webview when the app enters the background. Users who load communication-heavy sites (email, RSS, GitHub) get zero notifications.

Current architecture:
- Per-site profiles ([per-site-profiles spec](specs/per-site-profiles/spec.md)) on iOS 17+ and Android System WebView 110+ provide engine-level isolation. Same-domain sites coexist with isolated cookie jars, localStorage, IndexedDB, ServiceWorkers, and HTTP cache.
- `_useProfiles` is cached at startup as a single boolean.
- Lazy loading: webviews are created only when sites are first visited (`_loadedIndices`).
- Lifecycle: `didChangeAppLifecycleState` pauses all webviews on background entry.

Constraints:
- F-Droid distribution model: no Google services, no APNs server, no FCM.
- Privacy posture: no central backend; everything happens on-device.
- iOS suspends apps within ~30 seconds of backgrounding; only `BGAppRefreshTask` and `beginBackgroundTask` give us legitimate background time.
- Android `ProxyController.instance()` is a process-wide singleton; per-profile proxy is not possible.
- iOS's per-`WKWebsiteDataStore` proxy is supported on iOS 17+ — concurrent background-poll sites with different proxies work natively.

Stakeholders: end users (issue #192), the maintainer (theoden8), F-Droid reviewers (no GMS / no proprietary push).

## Goals / Non-Goals

**Goals:**
- Deliver native notifications from sites that use the JavaScript Notification API (`new Notification(...)`).
- Per-site opt-in: users explicitly enable notifications and background polling for sites that need them.
- Real-time foreground delivery on iOS and Android.
- Best-effort iOS background delivery via `BGAppRefreshTask` (15-30 min cadence).
- Real-time Android background delivery via foreground service for proxy-free sites.
- Zero new external dependencies on push relays, APNs servers, FCM, or any centralized infrastructure.
- One code path for the JS bridge across iOS and Android.

**Non-Goals:**
- Real-time iOS background notifications. Out of scope by design — the only path is APNs server relay, which violates the privacy model and F-Droid constraints.
- Web Push API (`navigator.serviceWorker.pushManager`, VAPID). Sites that gate notifications on Push API support will fall back to in-app messaging. Future work, not v1.
- Slack / Teams / Telegram real-time chat. Users should use those apps' native iOS/Android apps. The proposal (issue #192) explicitly relaxes this — the requester accepts non-real-time delivery.
- Legacy device support (`_useProfiles == false`). Toggles are hidden; the feature is unavailable.
- macOS support. Out of scope until the iOS work proves stable; macOS reuses most of the iOS code path with `NSAppNapPriority` instead of `BGAppRefreshTask`.
- Cross-app notification deduplication, grouping, or thread management. Each notification is tagged with `siteId`; OS-level grouping is whatever the OS provides by default.

## Decisions

### D1: Polyfill the Notification API at DOCUMENT_START on every platform

We define `window.Notification` ourselves via an injected user script (with `forMainFrameOnly: false`) that bridges to Dart via `addJavaScriptHandler`. Per-site permission state is baked into the polyfill template so a denied site sees `permission === "denied"` and the constructor is a no-op.

**Why:**
- WKWebView (iOS) does not expose Web Notifications natively. Without a polyfill, sites just see `typeof Notification === "undefined"` and disable their notification UI entirely.
- `flutter_inappwebview`'s `onNotificationReceived` is annotated `@SupportedPlatforms([WindowsPlatform()])` — empty stub on iOS / macOS even in 6.2.0-beta.3.
- Polyfilling on Android too (where the API IS native) keeps the code path uniform: one place to enforce per-site permission, one place to add `siteId` tagging, one place to test.

**Alternatives considered:**
- *Use plugin's native callback when it lands.* Rejected — open-ended timeline, and we'd still need the iOS polyfill regardless. Two code paths for the same feature is worse than one.
- *Polyfill only on iOS, use native API on Android.* Rejected — divergent behavior (e.g., service worker registration semantics) across platforms hurts testability.

### D2: Two new per-site fields — `notificationsEnabled`, `backgroundPoll`

Both default to `false` (opt-in). `notificationsEnabled` controls whether the polyfill returns "granted" and whether `new Notification()` reaches Dart. `backgroundPoll` controls whether the site's webview is auto-loaded at startup, kept unpaused on background, and registered with the platform's background mechanism.

**Why:**
- Two distinct user intents: "I want notifications when I'm using this site" vs. "I want notifications even when this site isn't open." The first is cheap; the second has resource costs (battery, memory) and platform-specific quirks (iOS dialog, Android proxy conflict).
- Independent: a user might want `notificationsEnabled` without `backgroundPoll` (only get notifications during active use).

**Alternatives considered:**
- *Single `notificationsEnabled` field that implies background.* Rejected — conflates two decisions, makes UX worse, can't represent foreground-only.

### D3: Foreground refresh timer (5 min cadence) reloads non-active background-poll sites

While the app is in foreground, a Timer.periodic fires every 5 minutes and triggers a reload on each loaded background-poll site that isn't `_currentIndex`. The active site is skipped because the user is interacting with it directly.

**Why:**
- Many sites use the Page Visibility API to throttle polling when their tab/page is not visible (`document.hidden === true`). Without our refresh, a Gmail tab loaded in background but not active might check for new mail every 30+ minutes.
- 5 min is a heuristic balance: short enough to feel timely, long enough to avoid battery drain. The user's foreground attention is bounded anyway — if they're using the app for an hour, they get 12 refreshes per background-poll site.

**Alternatives considered:**
- *Inject JS to override Page Visibility.* Rejected — too invasive, breaks sites that rely on real visibility for video/animations, and many sites poll regardless of visibility anyway.
- *Listen for navigator.onLine / network events.* Rejected — doesn't help; sites still throttle.
- *Configurable cadence per site.* Rejected for v1 — adds UX complexity without clear demand.

### D4: iOS background = `beginBackgroundTask` (30s flush) + `BGAppRefreshTask` (opportunistic)

On `didChangeAppLifecycleState(.paused)`, register `beginBackgroundTask` for the grace window. Background-poll webviews aren't paused for the duration. Schedule a `BGAppRefreshTaskRequest` on background entry; iOS fires it at its discretion.

When `BGAppRefreshTask` fires:
1. We have ~30 seconds. Bring up each background-poll site's webview if not already loaded. Reuse if alive (the WKWebsiteDataStore profile keeps cookies, so no re-auth needed).
2. The site loads, runs its normal page JS, polls, and any notifications fire through the polyfill → Dart → `flutter_local_notifications`.
3. Call `task.setTaskCompleted(success: true)`. Schedule the next refresh.

**Why:**
- These are the only legitimate iOS background mechanisms for our use case. APNs requires server-side, NetworkExtension requires VPN-app-policy reviewers' blessing.
- 30 second tasks per ~15-30 min interval is sufficient for low-frequency notifications.

**Alternatives considered:**
- *NetworkExtension to hold WebSocket connections.* Rejected — App Store policy bars non-VPN use.
- *Silent push from arbitrary APNs sender.* Rejected — apps can't receive push from non-Apple-approved senders.
- *Keep-alive via UIBackgroundMode = audio with silent sound.* Rejected — App Store rejection is guaranteed.

### D5: Android background = foreground service for proxy-eligible sites; toggle-disabled UI for proxy conflicts

When at least one background-poll site is loaded AND that site uses `ProxyType.DEFAULT` (or the same proxy as all other background-poll sites), start a foreground service with a persistent notification. The service keeps the process alive; webviews don't pause; JS keeps running indefinitely.

Proxy conflict UI: if the user tries to enable `backgroundPoll` on Site B whose proxy differs from already-background-polling Site A, the toggle is disabled with explanatory text. The user can disable Site A's `backgroundPoll` first to free up the proxy slot.

**Why:**
- Foreground service is the standard Android mechanism for legitimate long-running background work (music players, fitness trackers, messengers). Google explicitly endorses it for messenger/notification use cases.
- The proxy constraint is real: `ProxyController.instance()` is process-wide, so concurrent sites with different proxies would have one of them silently routing through the wrong proxy. Better to refuse the configuration up front than ship silent breakage.

**Alternatives considered:**
- *Allow the proxy conflict but warn the user.* Rejected — too easy to miss, and the failure mode is privacy-violating (traffic going through the wrong proxy).
- *Use WorkManager periodic tasks instead of foreground service.* Rejected — Android imposes 15 min minimum interval and may delay heavily; we lose the real-time delivery that's Android's main advantage over iOS.
- *Patch ProxyController to be per-WebView.* Rejected — would require forking flutter_inappwebview and Chromium-side changes; way out of scope.

### D6: Toggles gated on `_useProfiles`

`notificationsEnabled` and `backgroundPoll` toggles are visible only when profile mode is active (iOS 17+ or Android with WebView 110+). On legacy devices the feature is hidden entirely.

**Why:**
- In legacy mode (CookieIsolation engine), domain conflicts dispose webviews and `deleteAllCookies()` clears the singleton CookieManager. A backgrounded "background-poll" site would lose its session the moment any other same-domain site activates. Reliable notifications are infeasible.
- Hiding the feature is cleaner than shipping a degraded-mode that silently doesn't work.

**Alternatives considered:**
- *Show the toggles disabled with explanatory text.* Considered acceptable but adds clutter for users on legacy devices who can't act on it. Hide is simpler.

### D7: Notification tap routes through `_setCurrentIndex`

When the user taps a notification, the platform-native tap handler fires our Dart callback with the `siteId`. We look up the index for that `siteId` in `_webViewModels` and call `_setCurrentIndex(index)`. In profile mode there are no domain conflicts, so this is a normal site activation.

**Why:**
- Existing path. No new orchestration. Lazy loading and profile binding both happen via the standard `_setCurrentIndex` flow.
- Edge case: if the site was deleted between sending the notification and the user tapping, we log a warning and ignore the tap.

### D8: Auto-load background-poll sites on startup

On `_restoreAppState`, after sites are restored, iterate over those with `backgroundPoll == true` and add them to `_loadedIndices` (without setting `_currentIndex`). Their webviews are constructed in the IndexedStack but stay Offstage until the user manually selects them.

**Why:**
- A background-poll site that was never visited can't deliver notifications. Auto-loading at startup lets the polyfill register immediately.
- Profile mode means there's no domain-conflict cost to having multiple sites loaded simultaneously.

**Alternatives considered:**
- *Lazy-load on first BGAppRefreshTask fire.* Rejected — we'd miss in-foreground polling and the 30s grace flush. Auto-load is simpler.

## Risks / Trade-offs

- **iOS `BGAppRefreshTask` cadence is non-deterministic** → users may experience unpredictable notification delays (10 min one time, 2 hours another). Mitigated by the one-time iOS info dialog explaining this. Not real-time chat, by design.

- **Sites that use Push API + ServiceWorker bypass our polyfill** → notifications won't fire for these sites; they'll fall back to in-app messaging. Mitigated by documenting this as a known limitation; users on affected sites won't see anything worse than today's "no notifications at all." Future work: ServiceWorker push subscription handling.

- **Polyfill replaces `window.Notification` even on Android where the native API works** → site code that introspects (e.g., `Notification.toString().includes("[native code]")`) might detect the polyfill. Mitigation: extremely rare check; if it becomes an issue we can use `Object.defineProperty` with `configurable: false, writable: false` and manage the `toString` representation.

- **Foreground refresh timer reloads sites every 5 min, breaking long-running flows** → e.g., a half-typed message or a video mid-playback gets reloaded. Mitigated by skipping the active site and only refreshing background-poll sites. The user accepted this by enabling `backgroundPoll` — these sites are intended for passive monitoring.

- **Android foreground service notification is mandatory and visible** → users will see a persistent "WebSpace is checking N sites" notification whenever they have background-poll enabled. This is by design (Android requires it for foreground services) and serves as a transparency mechanism. Mitigation: clear messaging in onboarding.

- **iOS user enables backgroundPoll expecting Android-like real-time** → cognitive mismatch. Mitigated by the one-time info dialog on first toggle.

- **POST_NOTIFICATIONS denied on Android 13+** → we requested it but the user said no. Notifications fail silently. Mitigation: log a warning, gray out the toggle subtitle with "Notification permission denied — re-enable in system settings."

- **Battery drain from unintentional `backgroundPoll` enabling** → user toggles it on a site that polls aggressively. Mitigation: opt-in default + the foreground service notification (Android) and the one-time dialog (iOS) both make the cost visible.

- **Notification tap on a deleted site** → race condition: notification was sent, user deletes the site, then taps. Mitigation: look up `siteId` in `_webViewModels` and silently ignore if not found, log warning.

- **`flutter_local_notifications` plugin lifecycle and FlutterEngine init in BGAppRefreshTask handler** → BGAppRefreshTask handlers run in a backgrounded process where the FlutterEngine may not be initialized. Mitigation: use the plugin's headless background isolate pattern. Spike during implementation; if this is too brittle, fall back to native notification scheduling and only invoke Flutter for tap handling.

## Migration Plan

No migration needed for existing users. The new fields default to `false` so no behavior change unless users opt in.

`WebViewModel.fromJson` should default `notificationsEnabled` and `backgroundPoll` to `false` when the keys are absent (existing serialized state).

Settings backup/restore: add both keys to `WebViewModel.toJson` (already covered automatically by per-site serialization, no registry change needed per CLAUDE.md guidance).

Rollback: if the feature breaks badly, gate it on a single boolean (e.g., `_notificationsFeatureEnabled`) we can flip false. Without that, the polyfill becomes a no-op (returns "denied"), the foreground service stops, BGAppRefreshTask is cancelled. No data loss.

## Open Questions

1. **Plugin choice for foreground service on Android.** Options: `flutter_foreground_task`, `foreground_service`, or roll our own thin Kotlin layer. Decision deferred to implementation; preference is to roll our own to avoid adding a dependency for ~50 lines of Kotlin.

2. **`BGAppRefreshTask` task identifier — single or per-site?** iOS allows multiple registered identifiers but each schedules independently. Single identifier per app + iterating sites in the handler is simpler; per-site identifiers might get more frequent OS scheduling. Spike during implementation.

3. **Foreground refresh implementation — `controller.reload()` or fire a custom event?** `reload()` is heavy (re-fetches the page); a custom event (`document.dispatchEvent(new Event('refresh'))`) is lighter but sites have to opt in. Defaulting to `reload()` for simplicity; can revisit if it causes issues.

4. **Notification permission UX on first site that requests it.** Show the system permission dialog immediately, or defer until the user explicitly enables `notificationsEnabled` on a site? Probably defer — only ask when the user demonstrates intent.

5. **Per-notification icon source.** Site provides URL in `options.icon`. Do we download it on every notification (network-blocking) or use cached site favicon? Use favicon — `IconService` already has it cached, simpler and faster. Site-provided icons could be a future enhancement.
