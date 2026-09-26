# web-push-notifications Specification

## Purpose
TBD - created by archiving change web-push-notifications. Update Purpose after archive.

## Requirements

### Requirement: NOTIF-001 - Notification Permission Handling

The system SHALL handle JavaScript `Notification.requestPermission()` calls from web pages and grant or deny based on the per-site notification toggle. Requires container mode (`_useContainers == true`) — iOS 17+ or Android with System WebView 110+.

#### Scenario: Site requests notification permission with toggle enabled

**Given** container mode is active
**And** a site has `notificationsEnabled` set to `true`
**When** the site calls `Notification.requestPermission()`
**Then** the polyfill calls the `webNotificationRequestPermission` JS handler
**And** Dart checks the per-site toggle and returns `"granted"`
**And** the site receives `"granted"` as the permission result

#### Scenario: Site requests notification permission with toggle disabled

**Given** a site has `notificationsEnabled` set to `false`
**When** the site calls `Notification.requestPermission()`
**Then** the polyfill returns `"denied"` via the JS handler

#### Scenario: Notification toggles hidden on legacy devices

**Given** container mode is NOT active (`_useContainers == false`)
**When** the user opens site settings
**Then** the `notificationsEnabled` and `backgroundPoll` toggles are not shown

### Requirement: NOTIF-002 - JavaScript Notification Polyfill

The system SHALL inject a JavaScript polyfill at `DOCUMENT_START` (with `forMainFrameOnly: false`) on every site that defines `window.Notification`, `Notification.permission`, `Notification.requestPermission()`, and the `Notification` constructor. The polyfill bridges to Dart via `addJavaScriptHandler`. WKWebView does not expose the Web Notifications API natively; on Android we polyfill anyway for code-path uniformity and consistent per-site enforcement.

#### Scenario: Polyfill is injected on every site

**Given** a webview is being created for a site (iOS or Android)
**When** the page loads
**Then** `window.Notification` is defined before any page script runs
**And** `Notification.permission` is `"granted"` if the site has `notificationsEnabled == true`, otherwise `"denied"`
**And** the polyfill is injected with `forMainFrameOnly: false` so cross-origin iframes also see it

#### Scenario: Site creates a notification via the polyfill

**Given** a site has notification permission granted
**When** the site calls `new Notification("title", { body: "message", icon: "url" })`
**Then** the polyfill calls `flutter_inappwebview.callHandler('webNotification', ...)` with title, body, icon, tag, and `siteId`
**And** Dart receives the call and shows a native notification via `flutter_local_notifications`
**And** the notification is tagged with the originating site's `siteId`

#### Scenario: Notification constructor is a no-op when permission is denied

**Given** a site has `notificationsEnabled == false` (polyfill sees `permission === 'denied'`)
**When** the site calls `new Notification(...)`
**Then** the polyfill returns without invoking the JS bridge
**And** no native notification is shown
**And** the polyfill emits a `console.warn` breadcrumb (`[WebSpace] Notification(...) suppressed: permission denied`) so the suppression is visible in the dev-tools Console

#### Scenario: Page-context Service Worker notification is bridged

**Given** a site has notification permission granted
**And** the site calls `registration.showNotification("title", {...})` from page context (e.g. after `navigator.serviceWorker.ready`)
**When** the override runs
**Then** the polyfill calls `flutter_inappwebview.callHandler('webNotification', ...)` with the same payload shape as the `Notification` constructor
**And** a native notification is shown tagged with the originating `siteId`

#### Scenario: True server-driven web push is out of reach by design

**Given** a site delivers notifications from inside its Service Worker's `push` or `message` event handler (the standard Web Push pattern)
**When** the push event fires
**Then** WebSpace does NOT deliver the notification, because the handler runs in the worker global scope which a page-injected script cannot patch, and the app has no Web Push subscription endpoint
**And** this is a known architectural limit: WebSpace delivers what the site's page-context JS posts while the page is running, plus what a background wake finds (NOTIF-014), not true server push

### Requirement: NOTIF-003 - Notification Tap Navigation

The system SHALL navigate to the originating site when the user taps a notification. This routes through `_setCurrentIndex`. In container mode, no domain conflicts occur — the target site simply becomes active.

#### Scenario: User taps a notification for a loaded site

**Given** a native notification was created by Site A
**And** Site A is still loaded in `_loadedIndices`
**When** the user taps the notification
**Then** the app opens (or comes to foreground)
**And** `_setCurrentIndex` is called with Site A's index
**And** Site A becomes the active site

#### Scenario: User taps a notification for a site that was not yet loaded

**Given** a native notification was created by Site A
**And** Site A is not in `_loadedIndices` (e.g., app was restarted)
**When** the user taps the notification
**Then** `_setCurrentIndex` adds Site A to `_loadedIndices`
**And** Site A's webview is created with its profile
**And** Site A becomes the active site

### Requirement: NOTIF-004 - Per-Site Notification Toggle

The system SHALL provide a per-site toggle to control whether the site is allowed to show notifications. Defaults to off (opt-in). Only visible when container mode is active.

#### Scenario: User enables notifications for a site

**Given** a site with `notificationsEnabled` set to `false`
**When** the user enables the notifications toggle in site settings
**Then** `notificationsEnabled` is set to `true`
**And** the setting is persisted

#### Scenario: User disables notifications for a site

**Given** a site with `notificationsEnabled` set to `true`
**When** the user disables the notifications toggle in site settings
**Then** `notificationsEnabled` is set to `false`
**And** any pending notification permission requests from the site are denied

Every runtime consumer SHALL read `WebViewModel.effectiveNotificationsEnabled`,
never the stored `notificationsEnabled` field. The effective getter forces
false for archive-tier sites (ARCH-006); `NotificationService` has no archive
check of its own, and the only gate on the `webNotification` JavaScript
handler is `config.notificationsEnabled`. That covers the site's own
`WebViewConfig` **and** both `launchUrlFunc` call sites, which hand the value
to `InAppWebViewScreen`.

#### Scenario: Archive-tier site posts no notification, in-page or nested

**Given** an archive-tier site whose stored `notificationsEnabled` is `true`
**When** its `WebViewConfig` is built, and when it opens an outbound link in
an `InAppWebViewScreen`
**Then** `config.notificationsEnabled` is `false` in both
**And** the polyfill's bridge handler is never registered, so nothing reaches
`flutter_local_notifications`
**And** no notification naming the archived site can outlive the archive
close in the system shade

### Requirement: NOTIF-005 - Per-Site Background Poll Toggle

The system SHALL provide a per-site toggle that opts the site into background polling. Only visible when container mode is active. In container mode, there are no domain conflicts, so all background-poll sites stay loaded concurrently with their own isolated profiles. Background behavior is platform-dependent — see NOTIF-005-I (iOS) and NOTIF-005-A (Android).

#### Scenario: App enters background without background-poll sites

**Given** no sites have `backgroundPoll` set to `true`
**When** the app enters the background
**Then** all webviews are paused (existing behavior)

#### Scenario: Multiple same-domain background-poll sites coexist

**Given** Site A (`github.com/personal`) has `backgroundPoll` set to `true`
**And** Site B (`github.com/work`) has `backgroundPoll` set to `true`
**And** container mode is active
**When** both sites are loaded
**Then** both stay loaded concurrently (PROF-003 — no domain conflict)

### Requirement: NOTIF-005-I - iOS Background Strategy

On iOS, the OS suspends apps within seconds of backgrounding. The system SHALL:
1. Provide a grace-period flush via `beginBackgroundTask` (~30s) for in-flight notifications.
2. Schedule `BGAppRefreshTask` for opportunistic refreshes (typically every 15-30 minutes at the system's discretion).
3. Inform the user of these limitations on first use.

#### Scenario: App enters background — grace-period flush

**Given** the platform is iOS
**And** Site A has `backgroundPoll` set to `true` and is loaded
**When** the app enters the background
**Then** the app calls `UIApplication.shared.beginBackgroundTask(expirationHandler:)`
**And** Site A's webview is NOT paused for the duration of the background task
**And** any notifications fired by Site A during the ~30 second grace period are delivered
**And** when the grace period expires, iOS suspends the app

#### Scenario: BGAppRefreshTask runs while app is suspended

**Given** the platform is iOS
**And** Site A has `backgroundPoll` set to `true`
**And** the app is in the background and has been suspended (~30s grace period elapsed)
**When** iOS opportunistically fires the registered `BGAppRefreshTask`
**Then** the app is woken with ~30 seconds of CPU time
**And** Site A's webview is reloaded and the wake waits for the load to settle (NOTIF-013)
**And** Site A's normal page JS runs and may fire notifications via the polyfill
**And** if it posts nothing while its title's unread count rose, the app posts one for it (NOTIF-014)
**And** only then does the app call `task.setTaskCompleted(success: true)`; the next refresh is rescheduled when the task arrives

#### Scenario: User is informed of iOS background limitations

**Given** the platform is iOS
**And** the user enables `backgroundPoll` on a site for the first time
**When** the toggle is enabled
**Then** an informational dialog explains that iOS suspends WebSpace shortly after the user leaves it, that notifications arrive while it is open and for about 30 seconds after, and that iOS wakes it from time to time to reload these sites, notifying when a site's title shows a higher unread count
**And** the dialog is shown only once (a "shown" flag is persisted)
**And** the toggle is still allowed

### Requirement: NOTIF-005-A - Android Background Strategy

On Android, the system SHALL mirror the iOS opportunistic-refresh strategy: schedule a `WorkManager` periodic refresh that wakes the app every 15 minutes (system minimum) and runs the same wake as iOS (NOTIF-013, NOTIF-014). The system SHALL NOT use a foreground service to keep notification sites running. Apps that notify from the background are woken by a push channel (FCM, APNs) rather than staying resident, and a resident `specialUse` service also carries the Play review cost of `FOREGROUND_SERVICE_SPECIAL_USE`. So a site's page JS runs while the app is visible and in the short grace before Android freezes the process; after that, the wake is what reaches the user.

The `ProxyController` is a process-wide singleton, so concurrent background-poll sites with different proxy configurations remain unsupported even under the refresh model — proxies thrash when reloads run back-to-back.

The request SHALL carry an initial delay of one interval. WorkManager treats the first period of a `PeriodicWorkRequest` as due at enqueue time (`WorkSpec.calculateNextRunTime` returns `lastEnqueueTime` while `periodCount == 0`), so without the delay the refresh fires seconds after the first notification site is loaded and reloads the page the user just opened — the native refresh path does not exclude the active site, and `reloadAndRepaint` drops its painted frame. Nothing is lost by waiting: while a site is loaded its page JS is running and fires notifications live through the polyfill; the refresh only matters once the app has been backgrounded for a while.

#### Scenario: At least one notification site loaded — refresh is scheduled

**Given** the platform is Android
**And** Site A has notifications enabled and is loaded
**When** the app enters the background
**Then** a `WorkManager` `PeriodicWorkRequest` is enqueued under the unique name `webspace-notification-refresh` with a 15-minute interval, a 15-minute initial delay, and `NetworkType.CONNECTED` constraint
**And** no foreground service is started
**And** no persistent notification is shown
**And** the OS gives the process its normal short grace before freezing — no explicit `beginBackgroundTask`-equivalent is used (Android has none without a foreground service)

#### Scenario: A newly scheduled refresh does not fire immediately

**Given** the platform is Android
**And** no notification site was loaded, so the unique work was cancelled
**When** a notification site is loaded and the periodic refresh is enqueued afresh
**Then** the first refresh runs one interval later, not at enqueue time
**And** the site the user just opened is not reloaded underneath them

#### Scenario: WorkManager fires while the Flutter engine is alive — sites reload

**Given** the periodic refresh fires
**And** the app's Flutter engine is still alive (cached or warm)
**When** the worker invokes `onBackgroundRefresh` over the method channel
**Then** every loaded notification site is reloaded sequentially
**And** the page JS runs and may fire notifications via the polyfill
**And** the wake waits for the loads to settle (NOTIF-013) and posts for a silent site whose unread count rose (NOTIF-014)
**And** the worker returns `Result.success()` and the next refresh remains scheduled

#### Scenario: WorkManager fires after the process was killed — refresh is a no-op

**Given** Android killed the app process for memory pressure
**When** the periodic refresh fires
**Then** the worker observes that no Flutter engine is reachable
**And** the worker returns `Result.success()` without reloading any sites
**And** the next app launch re-enqueues the periodic refresh with `ExistingPeriodicWorkPolicy.UPDATE`

#### Scenario: Conflicting proxy disables background-poll toggle

**Given** the platform is Android
**And** Site A has `backgroundPoll` set to `true` with SOCKS5 proxy
**And** the user attempts to enable `backgroundPoll` on Site B which has an HTTP proxy
**When** the user opens Site B's settings
**Then** the `backgroundPoll` toggle is disabled (greyed out)
**And** explanatory text reads: "Cannot enable: Site A polls with a different proxy. Android applies one proxy at a time process-wide."
**And** the user can disable Site A's `backgroundPoll` first to free up the slot

#### Scenario: Foreground polling still works for proxy-conflicted sites

**Given** the platform is Android
**And** Site B has `notificationsEnabled` set to `true`
**And** Site B's `backgroundPoll` is disabled due to proxy conflict
**When** the user switches to Site B
**Then** Site B's proxy is applied via `ProxyController.setProxyOverride`
**And** Site B's webview runs normally and may fire notifications via the polyfill in real-time
**And** when the user switches away from Site B, its webview is paused and notifications stop until next visit

#### Scenario: Last background-poll site unloaded — refresh is cancelled

**Given** a `WorkManager` periodic refresh is enqueued because Site A had `backgroundPoll == true`
**When** Site A's `backgroundPoll` is disabled (or Site A is deleted)
**And** no other background-poll sites are eligible
**Then** the periodic refresh is cancelled via `WorkManager.cancelUniqueWork("webspace-notification-refresh")`

#### Scenario: User is informed of Android background limitations

**Given** the platform is Android
**And** the user enables `notificationsEnabled` on a site for the first time
**When** the toggle flips on
**Then** an informational dialog explains that Android can freeze WebSpace soon after the user leaves it, that notifications arrive while it is open, that Android wakes it no more than once every 15 minutes to reload these sites, notifying when a site's title shows a higher unread count, and that notifications stop if Android closes WebSpace
**And** the dialog is shown only once (a persisted "shown" flag)
**And** the toggle is still allowed

### Requirement: NOTIF-006 - Foreground Active Polling

While the app is in foreground, the system SHALL maintain a 5-minute refresh timer that triggers a reload on each background-poll site that is not the currently active site. This ensures sites that throttle their polling when not visible (`Page Visibility API`) still get a chance to check for new content.

#### Scenario: Foreground refresh timer fires

**Given** the app is in foreground
**And** Site A has `backgroundPoll == true` and is loaded
**And** Site B is the currently active site
**When** 5 minutes elapse
**Then** Site A is reloaded (or sent a refresh signal)
**And** Site B is NOT refreshed (it's the active site, the user is interacting with it)

#### Scenario: Active site does not get auto-refreshed

**Given** Site A is the currently active site
**And** Site A has `backgroundPoll == true`
**When** the foreground refresh timer fires
**Then** Site A is NOT refreshed by the timer
**And** any notifications fire through the polyfill in real-time as the user interacts

#### Scenario: Timer pauses when app is backgrounded

**Given** the foreground refresh timer is running
**When** the app enters the background
**Then** the foreground refresh timer is cancelled
**And** background refreshes are handled by NOTIF-005-I (iOS) or NOTIF-005-A (Android)

### Requirement: NOTIF-007 - Notification Permission

The system SHALL request OS-level notification permission before displaying the first notification.

#### Scenario: First notification on iOS triggers permission request

**Given** the platform is iOS
**And** the app has not yet requested notification permission
**When** a site attempts to show a notification
**Then** the system requests notification permission via `UNUserNotificationCenter`
**And** notifications are displayed only if the user allows it

#### Scenario: First notification on Android 13+ triggers permission request

**Given** the platform is Android with API level >= 33
**And** `POST_NOTIFICATIONS` permission has not been granted
**When** a site attempts to show a notification
**Then** the system requests the `POST_NOTIFICATIONS` runtime permission
**And** notifications are displayed only if the permission is granted

### Requirement: NOTIF-008 - Wake-up Diagnostics

Because the wake-up chain (OS scheduler -> webview reload -> page JS -> `webNotification` handler -> `NotificationService.show` -> OS delivery) spans three layers that each fail silently, the system SHALL make the chain observable and foreground-triggerable so a regression can be localized without waiting on the OS background scheduler.

#### Scenario: Every hop logs a trace line

**Given** a background refresh runs (real OS task or simulated)
**Then** the schedule/cancel decision logs the enabled and loaded notification-site counts
**And** the reload pass logs how many sites were reloaded versus skipped (unloaded / no controller)
**And** the native bridge logs task receipt, dispatch reachability, completion, expiration, and timeout (iOS `NSLog`, Android `Log` under tag `WebspaceBgRefresh`)

#### Scenario: Developer can simulate a background refresh in the foreground

**Given** the developer-tools App Logs tab is open for a site
**When** the developer taps "Simulate background refresh"
**Then** the same wake the OS background task would run (NOTIF-013/014) executes immediately
**And** the resulting trace is visible in the App Logs tab

#### Scenario: Developer can verify OS notification delivery directly

**Given** the developer-tools App Logs tab is open for a site
**When** the developer taps "Send test notification"
**Then** `NotificationService.show` posts a local notification for that `siteId`
**And** the OS permission gate and delivery are exercised independently of any page JS

### Requirement: NOTIF-009 - Notification Replacement Semantics

The system SHALL follow Web Notifications replacement semantics when mapping a
page post onto the OS notification identity (`NotificationTarget.resolve`):
a post carrying a `tag` replaces the same site's earlier post with that tag; a
post without one is always a new notification. Android collapses on the
`(tag, id)` pair and iOS/macOS on the identifier, so an untagged post SHALL
draw a per-post-unique id — deriving the id from the title (or any other
value constant across posts) silently swallows every repeat of a site's
"New message". The id sequence SHALL be seeded so a fresh process cannot reuse
an id still held by a notification the previous process posted, and the OS tag
SHALL stay the `siteId` so a tap still routes to the originating site.

#### Scenario: Untagged posts accumulate

**Given** a site with notification permission granted
**When** the page calls `new Notification("New message")` three times without a `tag`
**Then** three separate OS notifications are posted, none replacing another

#### Scenario: A page tag replaces the site's earlier post with that tag

**Given** a site posted `new Notification("2 unread", {tag: "inbox"})`
**When** it posts `new Notification("3 unread", {tag: "inbox"})`
**Then** the second post lands on the same `(tag, id)` pair and replaces the first
**And** a different page tag, or the same page tag on another site, lands beside it

### Requirement: NOTIF-010 - A post names the frame that made it

The `Notification` polyfill is injected into every frame, and any frame can
also call the `webNotification` bridge directly. The handler SHALL read the
frame identity the plugin's bridge preamble supplies
(`JavaScriptHandlerFunctionData`) and SHALL drop a post whose frame is not
the top document and whose origin differs from the top document's, so a
cross-origin iframe cannot post a notification under the site's identity,
nor replace the site's tagged notifications. The target `siteId` stays the
webview's own, never the page's. The polyfill stays in frames so
`Notification.permission` reads consistently. Gated by
`test/js/page_bridge_authority.test.js`.

#### Scenario: A cross-origin iframe posts

**Given** site "Acme" has notifications enabled and embeds a cross-origin ad frame
**When** the frame calls `new Notification('Security alert', {body: '...'})`, or the bridge directly
**Then** no OS notification is shown
**And** a post from Acme's own document, or a same-origin frame, is shown as before

### Requirement: NOTIF-011 - A loaded notification site vetoes the app-background JS pause

`AppLifecycleEngine.backgroundPlan` SHALL return `jsPauseIndex: null` when
ANY loaded site has `effectiveNotificationsEnabled`, not only when the active
site does, and `resumeJsIndex` SHALL mirror the decision. Android's
`pauseTimers()` is process-global: pausing the site on screen freezes the
page JS of every notification site behind it, and that JS is what posts the
notification. Same shape as BGAUDIO-002, and one decision on both platforms
(on iOS the pause is per-instance, so the only cost is the active site
running until iOS suspends the app).

The `App background:` decision line SHALL carry `notif=<count>`, the number
of loaded notification sites, so a `jsPause=true` line can be told apart from
a broken exemption.

#### Scenario: Notification site behind a plain active site

**Given** plain site A is on screen and notification site B is loaded behind it
**When** the app goes to background
**Then** no JS pause is issued and the decision line reads `jsPause=false ... notif=1 loaded`
**And** state capture still runs for site A

#### Scenario: Unloaded notification site does not veto

**Given** plain site A is on screen and notification site B is not loaded
**When** the app goes to background
**Then** site A is paused as before (`jsPause=true`, `notif=0`)

### Requirement: NOTIF-012 - The background-delivery test starts at the server

The adb lifecycle tier SHALL test background delivery against a server that
holds the state, the way real sites work. Scenario P in
`scripts/run_android_lifecycle_tests.sh` serves a page that shows the
server's unread count in its title (fetched on load, raised live over an
`EventSource`) and posts a notification only from its message handler, never
on load. It loads that page as a notification site *behind* a plain site on
screen, then:

1. has the server send one message while the app is visible, and requires a
   notification from the page (the live path, with the site offscreen);
2. leaves the app in the background past the cached-app freezer's debounce
   (`WS_PUSH_BACKGROUND_SECS`, default 75), has the server record a second
   message that no open stream carries (what a frozen page, or one whose
   connection was dropped, never hears), and runs the background wake
   through the debug receiver;
3. passes only if a new OS notification appears, the wake reloaded the page,
   and the wake logged one unread fallback post.

Scenario F notifies on every page load and so can only show that a reload
happened; it stays as the test of the refresh trigger, not of delivery.
`test/js/notification_live_push_scenario.test.js` gates the scenario's shape:
server-held count, no post on load, notification site offscreen, background
wait before the message, the wake driven and its post asserted, not opt-in.

#### Scenario: A reload that nobody reads fails Scenario P

**Given** a build whose wake returns before the reload settles, or posts nothing for a silent site
**When** Scenario P runs
**Then** it fails, because the page never posts on load and no notification appears for the recorded message

### Requirement: NOTIF-013 - A background wake lasts until its pages have loaded

The handler for an OS background wake (iOS `BGAppRefreshTask`, Android
`WorkManager`) SHALL NOT return until every notification site it
reloaded has finished loading, or `BackgroundWakeEngine.settleDeadline` (20 s)
has passed, plus `postGrace` (3 s) for the settled pages' JS to post.
Returning is what completes the OS task, and iOS suspends the app once it is
complete.

The handler used to return as soon as the reloads were issued
(`WKWebView.reload()` returns immediately), so the task completed before any
page had loaded and a wake never ran page JS at all. A load counts as settled
once it has been seen to start and stop, or when it never started within the
first second; a webview that goes away mid-wake stops counting. The
foreground branch (Android's worker firing while the app is visible) keeps
`_refreshNotificationSites(excludeActive: true)`. Structural gate:
`test/js/background_refresh_active_site.test.js`.

#### Scenario: A wake does not end before the page has loaded

**Given** a background wake reloads site A, whose load takes 3 seconds
**When** the wake handler runs
**Then** it returns after site A's load has stopped and the post grace has passed
**And** only then is the OS task completed

### Requirement: NOTIF-014 - A wake posts for a site whose unread count rose

A reload shows what arrived while the page was not running, and a site
need not post a notification for it. After a wake settles, for each site
that posted nothing during the wake (`NotificationService.lastPostedAt`),
the system SHALL read the unread count from the page title (the first
parenthesised integer: `(3) WhatsApp`, `Inbox (12) - Gmail`, `(99+)`) and
post one notification when it is higher than the baseline: the count
recorded when the app last left the screen, or at the previous wake. The
notification's title is the site's name and its body the page's own title,
tagged so a later rise replaces it. No baseline (the first wake after a cold
launch) posts nothing. A notification the site posts while the app is in the
background re-records its baseline a second later (the page may update its
title after posting), so a wake does not announce again what the site
already did.

Baselines live in memory only (`BackgroundWakeEngine`), so nothing about a
site is persisted for it; archive-tier sites never reach the wake
(`effectiveNotificationsEnabled`, ARCH-006). Engine tests:
`test/background_wake_engine_test.dart`.

#### Scenario: A silent site's unread count rose

**Given** site A's title read `(2) Chat` when the app was left
**When** a wake reloads site A, it posts nothing itself, and its title now reads `(5) Chat`
**Then** one notification titled with site A's name and bodied `(5) Chat` is posted
**And** the next wake posts nothing more unless the count rises again

#### Scenario: The site posts for itself

**Given** a wake during which site A posts its own notification
**Then** no unread fallback is posted for site A

