# BUG-003 — Back/forward history lost on cold start

Status: open

## Symptom

After a cold start (phone reboot, OS kill, app-switcher swipe-kill), a site
reopens with an empty back/forward stack: the back gesture does nothing, and
on Android (which restores no display data without a stack) the session can
also lose its place. The site's `currentUrl` usually survives (persisted to
SharedPreferences on navigation), so the page looks right — the *history
behind it* is gone.

## Root mechanism / invariant

Cross-restart history has two halves that must BOTH cover every path:

1. **Capture**: `controller.saveState()` bytes must be on disk (encrypted,
   `WebViewStateStorage`) and *fresh* at the moment the process dies.
2. **Restore**: the first build of the site's webview after the restart must
   consume those bytes (`schedulePendingRestoreState` →
   `onControllerCreated` → `restoreState`).

Every recurrence of this bug is one of the halves missing a path: a kill
path that no capture point covered, or a load path that skipped the restore
queue. The invariant: **any path that persists a webview's existence across
a restart must pair a capture point (before death) with a restore queue
(before first build).** Spec: PAUSE-008/009/019 in
[openspec/specs/webview-pause-lifecycle/spec.md](../../openspec/specs/webview-pause-lifecycle/spec.md).

## Fix attempts

1. **2026-06-22 — PR #424** ("cold-start history restore"). Made
   `_setCurrentIndex` fetch saved bytes for any site built fresh, not just
   in-session `savedForRestore` re-activations — before this, cross-restart
   restore never ran at all (the pre-existing PAUSE-008 storage was
   in-session only). *Why partial*: capture-side, it deliberately rode the
   existing points only (app-background, go-home, dispose/eviction — "no new
   capture on the live navigation path"), leaving every kill path that skips
   `AppLifecycleState.paused` (app-switcher swipe-kill delivers only
   `inactive`, ignored per issue #308) and every background-site navigation
   uncaptured. Restore-side, the fetch is gated on
   `!_loadedIndices.contains(index)`, which silently excludes sites that
   enter `_loadedIndices` outside `_setCurrentIndex`.

2. **2026-06-26 — PR #448** ("Restore back/forward history on Android cold
   start"). Android's `WebView.restoreState()` is dropped once the webview
   has navigated, so applying it after the `initialUrlRequest` load lost the
   stack on Android; deferred the initial load and materialized the restored
   top entry with a reload. *Why partial*: fixed the apply-side ordering on
   one platform; both capture-side gaps and the auto-loaded-site restore
   skip from attempt 1 remained on all platforms.

3. **2026-07-08 — this change** (branch
   `claude/iphone-cold-start-history-ury2pl`). Two paths closed, one per
   half. Capture: `WebViewModel.onNavigationCommitted` now feeds a per-site
   3s trailing debounce (`NavStateCaptureDebouncer`) that captures state
   after each navigation burst settles — covers switcher-kills and
   background navigators (PAUSE-009 point 3). Restore: auto-loaded
   notification sites (the one load path outside `_setCurrentIndex`, both
   legacy pre-paint and container-mode `DeferredStartupEngine`) now queue
   saved bytes before `markLoaded` (PAUSE-019). *Coverage note*: capture is
   debounced, so a kill within ~3s of the last navigation can still lose
   that final hop (older stack restores instead); accepted trade against
   per-event `saveState()` IPC pressure.

## Known open gaps

- Kill inside the 3s debounce window loses the final navigation(s) of a
  burst; the previously captured stack restores instead. By design.
- App-version upgrades intentionally wipe all saved state and rotate the
  AES key (`_clearCacheOnUpgrade`, PAUSE-008) — history is expected to
  reset on the first launch after an update.
- Incognito and archive-tier sites intentionally forget (`persistsNavState`).
  An `alwaysOpenHome` site persists its stack within a session (AOH-006) and
  forgets its landed tab's on a fresh entry (`landsAtHomeOnLoad`,
  `SiteActivationController.forgetHistory`); until issue #1046 it did not,
  and attempt 3's cold restore put the page it was left on back over home.
- Sites loaded but never navigated after their last capture keep a stale
  stack (no event to debounce); harmless in practice since nothing changed.
- Nested `InAppWebViewScreen` browsers have no persistence at all — their
  history is session-ephemeral by design.
