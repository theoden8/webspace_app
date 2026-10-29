# BUG-024 — Notifications never arrive while WebSpace is in the background

Status: open

**Spec:** [web-push-notifications](../../openspec/specs/web-push-notifications/spec.md)
NOTIF-005-I, NOTIF-005-A, NOTIF-011, NOTIF-013, NOTIF-014, NOTIF-016;
[webview-pause-lifecycle](../../openspec/specs/webview-pause-lifecycle/spec.md)
PAUSE-034
**Tests:** [test/background_wake_engine_test.dart](../../test/background_wake_engine_test.dart)
(the wake: which sites, how, and what it posts),
[test/wake_candidates_test.dart](../../test/wake_candidates_test.dart) (the
app's models as the wake sees them),
[test/js/background_wake_cold_engine.test.js](../../test/js/background_wake_cold_engine.test.js),
[test/app_lifecycle_engine_test.dart](../../test/app_lifecycle_engine_test.dart)
and [test/js/memory_pressure_background_gate.test.js](../../test/js/memory_pressure_background_gate.test.js)
(leaving the screen trims nothing),
emulator Scenarios F, P and P2 in
[scripts/run_android_lifecycle_tests.sh](../../scripts/run_android_lifecycle_tests.sh)

## Symptom

A site with notifications on posts nothing while WebSpace is off screen. The
user sees its messages only on opening the app, on iOS and Android alike.

## Root mechanism / invariant

A site's page can only post while its JS runs, and neither OS lets an app's
pages run in the background for long. What reaches the user is whatever runs
in the moments the OS grants: the grace after leaving the screen, and the
periodic wake (`BGAppRefreshTask`, `WorkManager`). Each instance is one of
those moments ending, or never arriving, before a page for the site has run
and been read. The invariant: **every wake the OS grants loads every
notification site's page, keeps the wake open until it has loaded, and posts
what it finds.**

## Fix attempts

1. **2026-05-03 — PR #291.** Notification sites skip the per-instance pause
   on a site switch. *Why*: iOS's `pauseTimers()` alert hack froze the page's
   JS between switches. *Why partial*: it covered switching sites inside the
   app; the OS suspending the whole app was unaddressed.

2. **2026-05-04 — PR #293.** iOS grace period (`beginBackgroundTask`) and a
   `BGAppRefreshTask` that reloads every loaded notification site. *Why*: iOS
   suspends the app within seconds of leaving the screen. *Why partial*: the
   task handler returned as soon as the reloads were issued, and it reloaded
   only loaded sites with a live webview.

3. **2026-05-09 — PR #316.** Android swapped a `specialUse` foreground
   service for a `WorkManager` periodic refresh mirroring iOS. *Why*: Play
   review of `specialUse` is intractable. *Why partial*: when Android killed
   the process the worker found no engine and returned; the spec accepted
   that as "refresh is a no-op".

4. **2026-07-31 — PR #441.** Trace logging along the chain, a foreground
   "Simulate background refresh", and the page-context
   `ServiceWorkerRegistration.showNotification` path. *Why*: every hop failed
   silently. *Why partial*: diagnostics only; the trace went to logcat and
   Console.app, which a user without a computer cannot read.

5. **2026-09-04 — PR #577.** The periodic request waits one interval before
   its first run. *Why*: it fired at enqueue time and reloaded the page the
   user had just opened. *Why partial*: scheduling only.

6. **2026-09-27 — PR #640.** The wake waits for its reloads to settle
   (NOTIF-013) and posts when a silent site's title shows a higher unread
   count (NOTIF-014); a loaded notification site vetoes the process-global
   JS pause (NOTIF-011). *Why*: the wake ended before any page loaded, and
   sites notify on server push, not on load. *Why partial*: the wake still
   took only loaded sites with a live webview, and the unread baseline lived
   in memory, so a wake in a new process had nothing to compare against.

7. **2026-10-06 — PR #670.** A background log kept on disk in developer mode
   (DEVTOOLS-012). *Why*: the user had no computer to read logs from. *Why
   partial*: diagnostics only. Its first logs from a device showed iOS wakes
   with notification sites enabled and none checked, which is attempt 8.

8. **2026-10-06 — PR #675.** A wake checks every notification site
   (NOTIF-016): a live webview is reloaded, any other site is opened in a
   headless webview built from the same per-site config (container, proxy,
   shims, blockers) and closed when the wake ends. Selection moved into the
   engine so a test drives the app's own. Sites a headless check could route
   wrongly are skipped with the reason logged (legacy isolation, incognito,
   Tor down, unbindable proxy, Android proxy or Tor exit mismatch, blockers
   not attached). On Android a worker with no engine starts one with no
   activity, whose startup builds no site webview, and destroys it after.
   Unread baselines persist (`WakeBaselineStore`), except incognito ones. The
   refresh is scheduled while any site has notifications on, not only while
   one is loaded. A post made off screen reads the notification permission
   instead of requesting it: CI's Scenario P2 caught the request throwing in
   the worker's engine, which has no activity to prompt from, so the wake
   ended at its first fallback post. *Why*: in a process iOS launched for the task no frame is
   drawn, so no webview is ever built, and on Android the reclaimed process
   was the common case. *Why partial*: see the open gaps.

9. **2026-10-08 — PR #688.** The memory-pressure cascade runs only while
   the app is resumed (PAUSE-034). *Why*: the first device log after attempt
   8 put every `SiteUnload (memory pressure)` line in the same second as an
   `App background` line, on every second exit. Flutter reports memory
   pressure on every exit from the screen (the iOS engine's
   `flutterDidEnterBackground` calls `notifyLowMemory`; Android forwards
   `TRIM_MEMORY_UI_HIDDEN`), and PAUSE-006 trimmed a tier per report, so four
   trips to the home screen disposed every notification site but the one on
   screen, and its live connection with it. For most of two days that log
   read "3 enabled, 1 loaded". No test saw it because none fed the two
   signals together: unit tests call the cascade directly, integration tests
   inject lifecycle through `handleAppLifecycleStateChanged`, which never
   reaches the engine's enter-background hook, and Scenario P, the one that
   pressed Home for real, did so once per process, which only clears a
   cache. Scenario P now leaves the screen twice. The background log now
   also records what told these cases apart only by inference: real OS
   memory warnings (iOS) and trim levels (Android), Low Power Mode changes,
   `willTerminate`, and a process that ended inside its grace period, of
   which that log had four. The refresh request is no longer resubmitted on
   every site switch and resume, each of which moved its earliest start, and
   the state row reads the OS notification permission instead of what this
   process last asked. *Why partial*: a real OS
   memory warning that lands while the app is in the background is dropped
   with the exit signal, since nothing in Dart tells them apart; and the
   same log shows Low Power Mode on and no refresh task at all since attempt
   8 shipped, so the headless wake has still not run on a device.

10. **2026-10-15 — PR #726.** The iOS Runner moved to the UIScene
   lifecycle, under which the scene's storyboard starts the engine after
   launch. The app delegate now holds `BackgroundTaskPlugin` from launch and
   attaches each engine as it starts, and the plugin sends a refresh only
   after Dart's `backgroundRefreshReady`, the handshake Android already used.
   *Why*: the task handler must be registered during launch, but it handed
   the task to a plugin built beside the engine; with the engine started
   later, a task arriving first went to no plugin, was never completed and
   never rescheduled the next one. The channel buffer the old path relied on
   also dropped a message sent before the Dart isolate ran. *Why partial*:
   not yet run on a device, and whether iOS connects the scene at all in a
   launch it makes for a refresh task is unobserved.

11. **2026-10-16 — this change.** Any site with notifications on vetoes the
   app-background JS pause, loaded or not (NOTIF-011); before, only a loaded
   one did. An Android refresh tick that lands while the app is `inactive`
   reloads around the site on screen instead of running a wake
   (`AppLifecycleEngine.refreshTickOnScreen`). *Why*: four days of a
   device's Android background log (0.3.4, then 0.3.5) had headless checks
   loading in 3 to 12 s after an exit that paused nothing, and 8 of 8 wakes after an exit
   that logged `jsPause=true` ending "still loading at the deadline" for both
   sites. Android's `pauseTimers()` reaches every webview in the process,
   those built after it included, and a wake builds its headless checks in
   that process; nothing on the wake path resumed the timers. The veto
   predates NOTIF-016, when an unloaded notification site had nothing
   running to freeze. The same log had a tick Battery Saver held back fire
   as the app returned, in `inactive`, which took the wake path and reloaded
   both live sites under the user. `anyNotifications` takes no loaded set,
   so a veto over loaded sites alone does not compile back in. *Why
   partial*: no wake in that log posted anything for two more reasons this
   leaves open (below): neither site's title gave the fallback a count in a
   headless check, and Battery Saver held most wakes until the app was
   opened.

12. **2026-10-29 — PR #842.** On Android, Back that leaves the app
   (NAV-009) sends the task behind, as Home does, instead of finishing the
   activity. *Why*: `SystemNavigator.pop()` reaches Flutter's
   `PlatformPlugin`, which finishes an activity that does not answer
   `popSystemNavigator()`, and finishing destroys the engine the activity
   owns and every site's webview with it, so each return from Back was a
   cold start with no notification site loaded. Gate:
   `test/js/back_keeps_app_running.test.js`. *Why partial*: it covers the
   one exit the app makes itself; swiping WebSpace away from Recents, the
   usual way to close an app, still ends the process (the first open gap
   below).

13. **2026-10-29 — this change.** A title read from a running page with no
   count in it is a baseline of none, and the baselines are taken on every
   step away from the foreground, not on `paused` alone. *Why*: reported on
   0.4.0 for an ordinary site. A site shows no count while nothing is
   unread, and `noteBaseline` read that as no baseline at all, which posts
   nothing; so the first message after the user had read everything and
   left never posted, and only a second one did, measured from the first.
   Scenario P records `(1) Push` before leaving, so it never met a count of
   none. And a swipe from Recents can end the process before `paused`,
   where the baseline was taken. A wake's own read without a count now
   leaves the baseline as it was rather than erasing it: a page the wake
   just loaded may not show its count yet, and reading that as none would
   post the same message again on the next wake. Engine tests in
   `test/background_wake_engine_test.dart`, gate
   `test/js/wake_baseline_lifecycle.test.js`. *Why partial*: not yet run on
   a device, and no emulator scenario starts from none or swipes the task
   away; a heavy page's count may still not be in its title 3 s after a
   headless load stops (the last gap below).

## Known open gaps

- Swiping WebSpace away from Recents ends its process at once (Android kills
  a removed task's process unless it runs a foreground service, which
  NOTIF-015 rules out), and a page's pending timer or open connection ends
  with it. The next periodic wake checks the site headless, but a page that
  posts only from a timer the user started, as a "Show in 5s" test page
  does, has nothing to post on load. iOS does the same for an app swiped
  away in the app switcher, and runs no refresh task for it until it is
  opened again; leaving for the home screen, the grace period (NOTIF-005-I)
  covers a five-second timer, as Home does on Android. Some Android builds
  force-stop an app swiped from Recents, which also cancels its periodic
  work until it is opened.

- Whether iOS connects the scene, and so starts an engine, in a launch it
  makes for a refresh task has not been observed. If it does not, the task
  waits and expires: the background log shows "refresh task waits for Dart
  to start" with no "Dart started" line after it.

- iOS decides whether a refresh task runs at all. A device that never runs
  one (Low Power Mode, Background App Refresh off, rarely used app) gets no
  wake, and nothing in the app can change that.
- The headless check on iOS has not been observed on a device in a process
  iOS launched for the task; the engine and the policy are tested, the
  WKWebView loading off screen in that process is not.
- Incognito sites are never checked headless (their session does not outlive
  their webview), so they notify only while loaded.
- On Android outside router mode, sites with different proxies cannot all be
  checked in one wake; the ones not on the wake's route are skipped.
- A site that shows no unread count in its title and does not post on load
  is reloaded by a wake but has nothing to post.
- Android appears to hold the periodic work while Battery Saver is on and
  the app is in the background and not exempt from battery optimisation.
  The log behind attempt 11, with `powerSaveMode: true`, had 13 ticks fire
  in the same second as the app's return, and background stretches of 4.7,
  11.5 and 25 hours with no wake at all. The state row shows
  `powerSaveMode`, but its changes are not logged as iOS's Low Power Mode
  changes are, so the log shows this only by inference.
- A headless check read no unread count from either site in that log: one
  site's title never carries one, the other's carried "(1)" live and none
  headless, 3 s after its load stopped. Whether the headless page was not
  signed in or had not set its title yet is not in the log, which keeps no
  title.
