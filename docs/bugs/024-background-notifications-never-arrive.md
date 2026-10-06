# BUG-024 — Notifications never arrive while WebSpace is in the background

Status: open

**Spec:** [web-push-notifications](../../openspec/specs/web-push-notifications/spec.md)
NOTIF-005-I, NOTIF-005-A, NOTIF-011, NOTIF-013, NOTIF-014, NOTIF-016
**Tests:** [test/background_wake_engine_test.dart](../../test/background_wake_engine_test.dart)
(the wake: which sites, how, and what it posts),
[test/wake_candidates_test.dart](../../test/wake_candidates_test.dart) (the
app's models as the wake sees them),
[test/js/headless_check_config_parity.test.js](../../test/js/headless_check_config_parity.test.js),
[test/js/background_wake_cold_engine.test.js](../../test/js/background_wake_cold_engine.test.js),
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
   (DEVTOOLS-011). *Why*: the user had no computer to read logs from. *Why
   partial*: diagnostics only. Its first logs from a device showed iOS wakes
   with notification sites enabled and none checked, which is attempt 8.

8. **2026-10-06 — this change.** A wake checks every notification site
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
   one is loaded. *Why*: in a process iOS launched for the task no frame is
   drawn, so no webview is ever built, and on Android the reclaimed process
   was the common case. *Why partial*: see the open gaps.

## Known open gaps

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
