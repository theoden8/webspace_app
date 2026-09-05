# BUG-001: White/black screen after returning to or navigating a webview (Android)

**Status:** open (recurring — each fix has closed one entry path; new paths keep surfacing)
**Platform:** Android only (hybrid-composition `SurfaceView`)
**Spec:** [openspec/specs/webview-pause-lifecycle/spec.md](../../openspec/specs/webview-pause-lifecycle/spec.md) — requirements `PAUSE-013`…`PAUSE-028`
**Formal models:** [formal/kernel.tla](../../formal/kernel.tla), [formal/warmstart.tla](../../formal/warmstart.tla), [formal/reloadlatch.tla](../../formal/reloadlatch.tla) — `RepaintLiveness` ("every blank-surface attach is eventually repainted"). The `kernel_conflict.cfg` demonstrator is a back path that bypasses the chokepoint — i.e. this exact bug — and TLC rejects it with a counterexample.

## Symptom

The webview area renders as a flat **blank** rectangle — **black** or **white** —
while the page underneath is *alive*: JS runs, taps/scroll register, timers fire.
A relayout (device rotation, lock/unlock, tab switch) instantly clears it. The
user just sees a dead-looking screen after some navigation or app-lifecycle event.

## Root mechanism (the invariant behind every instance)

On Android the webview runs under **hybrid composition** (confirmed: the fork
defaults `useHybridComposition` to `true`, which routes to
`PlatformViewsService.initExpensiveAndroidView`, "always creates a 'Hybrid
Composition (HC)' view"). The surface backing the composited result can
**re-attach (or newly attach) without receiving a paint**. The renderer is healthy,
so nothing emits an error event; the compositor just never draws onto the new
surface until something forces a relayout. The `WebView` itself is an ordinary
Android view in the hierarchy, not a `SurfaceView`; the surface that presents a
stale frame is Flutter's own `FlutterImageView` overlay, which shows the last
image it acquired and does not repaint on its own (see open gap #12).

Two colors, two sub-causes:

- **Black** = an *existing* surface re-attached unpainted after the Android
  **activity was recreated** (page area *and* the strip behind the edge-to-edge
  status bar go black).
- **White** = a *brand-new* `SurfaceView` was mounted (fresh controller, bfcache
  restore) and shows its **default fill** before first paint.

A dead *renderer* (the process was actually killed) is a **different** bug — covered
by `PAUSE-013`/`PAUSE-014` (detect via JS probe → destroy-and-rebuild). A JS
`offsetHeight` read relayouts *web content*, not the Android surface, so it can
**never** fix the blank-surface case. The only remedy that works is to **force a
relayout of the platform view** — see `_nudgeSurfaceRepaint` (toggle a 1px inset
around the `IndexedStack` a few times over ~0.5s; each size flip recomposites the
`SurfaceView`, each `setState` repaints the Flutter base surface).

**Why it keeps recurring:** the fix is always "nudge the surface," but the *trigger*
is "a code path that mounts/re-attaches a surface." Every fix has wired the nudge
into one more such path. The bug resurfaces whenever a **new** path reaches a blank
surface without passing through an already-nudged chokepoint. This is whack-a-mole
until a single chokepoint covers every surface (re)attach.

## Fix attempts (chronological — each closed one path, none closed the class)

### Attempt 1 — Event-driven renderer-gone recovery (`PAUSE-013`)
**Date:** 2026-05-28 · **PR:** #382-era · **Files:** lib/web_view_model.dart, lib/main.dart
**What it did:** Listen for platform renderer-termination callbacks
(`onRenderProcessGone` / `onWebContentProcessDidTerminate`) and destroy-and-rebuild
the webview.
**Why:** A killed renderer leaves a permanently dead page; rebuild is the only cure.
**Why partial:** Only covers a *dead renderer*. The blank-but-alive *surface* emits
no event at all on Android (and the iOS callback frequently doesn't fire for an
offscreen webview), so this never sees the white/black-screen case.

### Attempt 2 — Renderer probe on activation + first surface nudge (`PAUSE-014`, `PAUSE-015`)
**Date:** 2026-06-04 · **PR:** #388 · **Files:** lib/main.dart, lib/web_view_model.dart
**What it did:** (a) On resume / every site switch, read `document.body.offsetHeight`;
a null result means a dead renderer → reuse Attempt 1's rebuild. (b) Added
`_nudgeSurfaceRepaint` (the 1px-inset toggle) and fired it on the **resume** and
**pinned-shortcut** paths. Also sequenced `_onResumed` so resume completes before the
shortcut intent, and a single nudge fires against the final visible site.
**Why:** The probe catches offscreen renderer deaths that fire no event; the nudge is
the first thing that actually repaints the Android surface (the JS probe relayouts web
content only — it never recovered the surface).
**Why partial:** The nudge only ran on resume/shortcut. A plain in-app site switch, or
any non-resume path, could still re-attach a blank surface.

### Attempt 3 — Nudge on site activation + Android per-instance pause is a no-op (`PAUSE-015` extended, `PAUSE-016`)
**Date:** 2026-06-20 · **PR:** #436 · **Files:** lib/main.dart, lib/services/webview.dart
**What it did:** (a) Ran `_nudgeSurfaceRepaint` on the `_setCurrentIndex` activation
path (tab tap, shortcut open, cold-start restore), made re-entrant so coalescing calls
don't fight over the toggle flag. (b) Made Android per-instance `pause()`/`resume()`
**no-ops**, because cycling the foreground `SurfaceView` through `onPause/onResume`
re-attached it blank on the next paint.
**Why:** Bringing a site onstage was itself a blank-surface trigger; and Android's
per-instance pause never paused JS anyway (only the process-global timer pause does),
so it was all cost and no benefit — and the cost *was* a white screen.
**Why partial:** Covers webviews **reused** via `_setCurrentIndex`. Webviews
**recreated from scratch** don't go through `_setCurrentIndex`, so they were still
uncovered.

### Attempt 4 — Nudge on fresh controller attach (`PAUSE-017`)
**Date:** 2026-06-25 · **PR:** #450 · **Files:** lib/main.dart, lib/web_view_model.dart
**What it did:** Set `WebViewModel.onControllerReady`; `onControllerCreated` fires it
after wiring the controller, which calls `_nudgeSurfaceRepaint` when the model's index
is the visible one. Covers `_goHome`, renderer-gone rebuild, and `savedForRestore`
re-creation — all the from-scratch recreations that mount a brand-new `SurfaceView`.
**Why:** A fresh `SurfaceView` shows its white default fill; controller creation is the
one chokepoint every recreation passes through, so hooking it covers all recreation
paths at once.
**Why partial:** Only fires when a **new controller** is created. A navigation that
**reuses the existing controller** but still re-attaches a surface — i.e. a
back/forward-cache restore — fires neither this nor `_setCurrentIndex`.

### Attempt 5 — Repaint after back/forward navigation (`PAUSE-018`)
**Date:** 2026-06-25 · **PR:** #451 · **Files:** lib/main.dart
**What it did:** Routed the back gesture and the AppBar back button through
`_goBackAndRepaint` (`controller.goBack()` then `_nudgeSurfaceRepaint`).
**Why:** With back/forward cache enabled by default (PR #445), a back navigation
restores a bfcached page onto a fresh `SurfaceView` that comes back white. Back nav
reuses the controller and stays on the same site, so it passed through neither existing
chokepoint.
**Why partial:** Covers back navigation on the **main page** only — the nested
`InAppWebViewScreen` still had no nudge (closed by Attempt 6).

### Attempt 6 — Repaint after back navigation in the nested screen (`PAUSE-018`)
**Date:** 2026-06-26 · **PR:** #451 · **Files:** lib/screens/inappbrowser.dart
**What it did:** Gave `InAppWebViewScreen` its own `_goBackAndRepaint` /
`_nudgeSurfaceRepaint`, reusing the shared `SurfaceRepaintEngine`, and wrapped its
webview in the same 1px-inset `Padding`. Routed the nested Android back gesture
through the funnel. Extended the structural gate to cover `inappbrowser.dart`.
**Why:** bfcache applies to nested webviews too (PR #445), so a back nav in the
nested screen re-attaches a blank SurfaceView exactly like the main page — gap #1.
**Why partial:** Forward navigation (gap #2) is still unnudged in both screens; the
class is still closed only path-by-path (gap #3).

### Attempt 7 — Recover the visible surface on memory pressure + shareable probe diagnostic (`PAUSE-019`)
**Date:** 2026-07-08 · **Files:** lib/main.dart, openspec/specs/webview-pause-lifecycle/spec.md
**What it did:** (a) `_handleMemoryPressure` now, after evicting its victim, resolves the
active loaded index and runs `_probeRendererAndRecover` (dead renderer → recreate) then
`_nudgeSurfaceRepaint` (blank surface → recomposite) against the **visible** site. (b) Gave
`_probeRendererAndRecover` a `trigger` label and made it emit a non-sensitive `SurfaceDiag`
line (`trigger=… probe=… → renderer-alive|renderer-gone`, no site name/URL) on every path
(resume, site-switch, memory-pressure).
**Why:** Reported as an any-site Android blank. The log showed the blank landing inside
memory-pressure churn (sites evicted, app backgrounded/foregrounded). The active site is
hard-protected from eviction, so it passed through none of the already-nudged chokepoints
(`_setCurrentIndex`, `onControllerReady`, back path, resume) as a *result* of the pressure —
yet the pressure itself can jettison its renderer (iOS) or drop its `SurfaceView` buffer
(Android). This is exactly the open-gap #3 shape: a new path reaching a blank surface without
passing a nudge. The diagnostic exists because the surface-vs-renderer distinction can't be
read from a log without the `offsetHeight` probe value, and prior logs were too sensitive to share.
**Why partial:** Still per-path — it adds the memory-pressure path rather than closing the
class. It also does not *prove* the memory-pressure event was this user's trigger (the
`SurfaceDiag` line is what confirms which path + which color). And it inherits Attempt 2/4's
assumption that the nudge physically recomposites on the device (see the TLAPS refinement gap
in gap #4 below).

### Attempt 8 — Repaint on the surface-attach signal for a warm start (`PAUSE-020`)
**Date:** 2026-07-23 · **Files:** lib/main.dart, lib/services/surface_repaint_engine.dart,
formal/warmstart.tla (+ cfgs, check.sh), test/surface_repaint_engine_test.dart,
test/js/surface_repaint_funnel.test.js, openspec/specs/webview-pause-lifecycle/spec.md
**What it did:** On `resumed`, `_openResumeRepaintWindow` opens a bounded (~3s)
window; while open, the new `didChangeMetrics` override fires `_nudgeSurfaceRepaint`.
Additive to Attempt 2's tail nudge in `_onResumed`, which still fires once.
**Reproduced + proved (mechanism, not device):** the warm-start ordering the kernel
could not express (gap #4) is reproduced as a model-checked counterexample in
`formal/warmstart.tla` (`warmstart_bug.cfg`, Fix="none"): `Resume` schedules the one-shot
nudge, it drains to `nudging=0` while still painted, then `SurfaceReattach` sets the
surface blank and it stutters blank forever → `RepaintLiveness` violated. The fix
(`warmstart.cfg`, Fix="attach": the reattach itself schedules a nudge) makes the property
hold. Mirrored, runnable without TLC, in `test/surface_repaint_engine_test.dart`
(`SurfaceRepaintEngine` gained `owed`/`attach()`; a late `attach()` with no re-nudge stays
`owed`; the metrics re-nudge clears it), and gated in `surface_repaint_funnel.test.js`.
These prove the *ordering* is real and that an attach-triggered re-nudge closes it; they do
**not** prove the device link below.
**Why:** Reported as a **white** screen on **warm-starting** a site (app backgrounded,
then foregrounded — no activity recreation, so neither `onControllerReady` (Attempt 4)
nor a back path (Attempts 5–6) runs; only the resume path (Attempt 2) does). On a warm
start the hybrid-composition `SurfaceView`'s surface is destroyed on background and
**re-created on foreground**, and that re-attach can land a frame or more *after*
`_onResumed`'s single tail nudge has already drained its ~0.7s budget — so the inset
flips before the surface exists and the freshly-attached surface stays blank. A surface
re-attach re-lays-out the window, which Flutter delivers as `didChangeMetrics`: the
closest Dart-side signal to the *actual attach*, versus every prior attempt's reliance on
a lifecycle *event* whose timing only approximates the attach. Nudging on the metrics
signal lands a size-flip on the surface whenever it comes back, not at a fixed guessed
delay. Bounded to the post-resume window so steady-state keyboard/rotation metric changes
don't nudge; `_nudgeSurfaceRepaint` coalescing keeps a metrics burst on one loop.
**Why partial:** Still not the durable single chokepoint (gap #3). `didChangeMetrics` is a
*proxy* for the attach — it fires for the main FlutterView's metrics, which correlate with
but are not identical to the webview platform-view's `SurfaceView` re-attach, and it is not
*guaranteed* to fire on every device's warm resume (hence the tail nudge is kept as a
fallback). The real fix is still a native surface-changed/-redrawn callback from the fork
driving the repaint. This attempt narrows gap #3 (keys on an attach signal, not a lifecycle
event) rather than closing it.

### Attempt 9 — Repaint after a reload, latched to the document recommit (`PAUSE-021`)
**Date:** 2026-07-29 · **Files:** lib/services/surface_repaint_engine.dart, lib/web_view_model.dart,
lib/main.dart, lib/screens/inappbrowser.dart, lib/services/webview.dart,
test/surface_repaint_engine_test.dart, test/js/surface_repaint_funnel.test.js,
openspec/specs/webview-pause-lifecycle/spec.md
**What it did:** Routed every reload through a funnel that latches on the engine
(`SurfaceRepaintEngine.reloadIssued`) and nudges, then nudges *again* when the next
main-frame load settles (`consumeLoadSettled`, driven by `onLoadingChanged(false)`).
Funnels: `WebViewModel.reloadAndRepaint` on the main page (Refresh button and
Clear-cookies via `userDrivenReload`, pull-to-refresh, the `restoreState` materialize
reload, the notification background refresh) and `_reloadAndRepaint` in
`InAppWebViewScreen` (menu Refresh, pull-to-refresh). The factory's own cached-HTML
one-shot live refresh reports through the new `WebViewConfig.onReloadIssued` so it
latches identically. Both host hooks are gated on the model being the visible site.
**Why:** Reported as a **white** screen after a plain in-app **refresh**, and the reporter
**confirmed the refresh was the trigger** — unlike Attempts 7 and 8, the entry path here is
not inferred from a log, it is stated. A reload keeps
the same site and the same controller, so it passes through none of the existing
chokepoints — not `_setCurrentIndex` (Attempt 3), not `onControllerReady` (Attempt 4),
not a back path (Attempts 5–6), not a resume (Attempts 2/8): gap #3's shape again.
The reload also has the Attempt-8 *ordering* on top of that: `reload()` throws away the
painted frame immediately but commits the replacement an unbounded time later, so a
nudge fired at issue time drains its ~0.6s budget against the old surface and the
recommitted one is left blank. The load-settled signal is the closest Dart-side proxy for
that recommit, which is why the repaint is latched across the gap rather than fired once.
**Why partial:** Still per-path (gap #3): it enumerates reload call sites instead of
keying on a native surface callback. `onLoadingChanged(false)` is a *proxy* for the
commit, one step removed like `didChangeMetrics` — it maps to `onLoadStop`, which fires
after the document is parsed rather than at the compositor's first frame, so a page that
paints materially later than load-stop can still outrun the second nudge. The latch is
also single-slot on a per-screen engine shared by all sites: a site switch between a
reload and its load-stop lets the incoming site's settle consume it (a harmless extra
nudge, not a missed one). The **trigger** is confirmed, but the **remedy** is not: no
`SurfaceDiag` trace from an affected device yet shows the settled re-nudge landing after the
recommit, which is what the fix rests on. The `trigger=reload -> nudge` /
`trigger=reload-settled -> nudge` pair exists to close that; until such a trace exists the
causal claim is unverified, exactly as in Attempt 8.

### Attempt 10 — Route-return chokepoint, first-commit latch, nested-screen parity (`PAUSE-024`/`025`/`026`)
**Date:** 2026-08-20 · **Files:** lib/services/surface_route_observer.dart (new),
lib/services/surface_repaint_engine.dart, lib/main.dart, lib/screens/inappbrowser.dart,
formal/kernel.tla (+ proofs), test/surface_repaint_engine_test.dart,
test/js/surface_repaint_funnel.test.js, integration_test/white_screen_test.dart,
openspec/specs/webview-pause-lifecycle/spec.md
**What it did:** Three paths, one shape each.
(a) **Route return** (`PAUSE-024`): both webview-hosting screens are now `RouteAware` on a
shared `surfaceRouteObserver` registered on `MaterialApp.navigatorObservers`, and nudge from
`didPopNext`. The observer is typed to `PageRoute`, so only an *opaque* route — the kind that
stops the platform view being composited — triggers it; dialogs and other popup routes, which
leave the webview composited under the barrier, do not.
(b) **First commit** (`PAUSE-025`): the `reloadIssued` latch generalised to
`noteCommitPending`, and armed by a fresh controller attach and by activating a site whose load
is still in flight. `consumeLoadSettled` then repaints the committed document exactly as it
does for a reload. Diagnostics: `trigger=controller-attach -> nudge` and
`trigger=commit-settled -> nudge` (the latter subsumes `reload-settled`).
(c) **Nested-screen parity** (`PAUSE-026`): `InAppWebViewScreen` gained the controller-attach
nudge, the post-resume window + `didChangeMetrics` re-nudge, and the route-return nudge. It
already had the back path and the reload funnel.
**Why:** These are the *reachable* paths a user hits that no prior attempt covers, found by
auditing every surface (re)attach against the nudge chokepoints rather than waiting for
another report. (a) is the most common of them: every full-screen route in the app — site
settings, app settings, developer tools, downloads, the nested browser — detaches the visible
site's `SurfaceView` while it covers the screen, and popping back re-attaches it through no
chokepoint at all (same site, same controller, no navigation, no lifecycle event). (b) is
open gap #7 from the 2026-08-13 report, where a first load commits after both fresh-webview
nudges drain — the Attempt 8/9 ordering, on a surface that has never painted; the latch
already existed and simply was not armed on that path. (c) matters because the main page's
nudge physically cannot repaint the nested screen: it toggles an inset around the
`IndexedStack`, which sits *under* the nested route, so a warm start with the nested browser
on top had no repaint at all.
**Why partial:** Still per-path (gap #3), and (b) still keys on `onLoadingChanged(false)`, the
same parse-time proxy for the commit that gap #6 describes. Every trigger here is *reasoned
from the mechanism*, not confirmed from a device report: unlike Attempt 9's reload, no user
has yet stated "I returned from settings and it was white", so the `trigger=route-return`
diagnostic exists to establish that from a log. The route-return nudge also assumes the
embedder actually detaches the platform view under an opaque route; if a Flutter version keeps
it attached, the nudge is a harmless no-op rather than a fix.

### Attempt 11 — Bounded commit window + a manual repaint in the menu (`PAUSE-027`/`028`)
**Date:** 2026-09-02 · **Files:** lib/services/surface_repaint_engine.dart, lib/main.dart,
lib/screens/inappbrowser.dart, lib/web_view_model.dart, formal/reloadlatch.tla (+ cfgs,
check.sh), test/surface_repaint_engine_test.dart, test/js/surface_repaint_funnel.test.js,
lib/l10n/app_*.arb, openspec/specs/webview-pause-lifecycle/spec.md
**What it did:** Three things, one report.
(a) **The commit latch is a window, not a ticket** (`PAUSE-027`). `noteCommitPending`
arms; `noteLoadSettled` (was `consumeLoadSettled`) repaints while armed and no longer
disarms; both hosts arm through one `_armCommitLatch` helper that restarts a 15s timer
(`SurfaceRepaintEngine.commitWindow`) and closes the window with `closeCommitWindow`,
cancelled in `dispose`.
(b) **A Repaint Screen entry in the three-dot menu** (`PAUSE-028`) in both webview screens:
`_probeRendererAndRecover` then `_nudgeSurfaceRepaint` on the main page, nudge only in the
nested screen, each emitting `trigger=manual` / `trigger=manual-nested`. Gated on Android
**and** on a new developer-mode flag unlocked by seven taps on a Version row in App Settings
(`developer-tools` DEVTOOLS-010), so the diagnostic is reachable on a release build without
sitting in the menu an ordinary user opens to refresh a page.
(c) **The loading bar reflects the tap.** `userDrivenReload` marks the model loading
before it awaits the HTTP-cache clear, and takes a re-entrancy guard so a double tap
issues one reload instead of two.
(d) **Every repaint reports itself** (`PAUSE-029`). The `SurfaceDiag` line moved from a
handful of call sites into `_nudgeSurfaceRepaint(trigger)`, which took a required label:
6 of 26 nudges had been reporting, so `back`, `activate`, `memory-pressure`, `goHome`,
both fullscreen toggles and the whole nested screen were dark. Gated on developer mode
(an ordinary session must not spend `LogService`'s 2000-entry ring on it) and collapsed
through `RepaintLogThrottle`, since `didChangeMetrics` and the funnel's own coalescing
fire the same trigger many times a second. `DiagSeed` and the in-process suite turn
developer mode on, and the reload scenario now asserts the trace shows both halves of
PAUSE-021 — a pixel verdict alone cannot tell a working funnel from a page that was
merely fast.
**Reproduced + proved (mechanism, not device):** `formal/reloadlatch.tla`. `Fix="oneshot"`
(`reloadlatch_bug.cfg`) is the pre-fix latch and TLC returns the reported trace: two
`Issue`s, the aborted load `Settle`s and consumes the latch, its nudge drains, the
replacement `Settle`s onto a blank surface with `nudging = 0` and stutters blank forever —
`RepaintLiveness` violated. `Fix="window"` (`reloadlatch.cfg`) makes it hold, and
`reloadlatch_reach.cfg` proves the spent-latch state is reachable. Mirrored runnable in
`test/surface_repaint_engine_test.dart` (`rapid-refresh ordering`), including the redirect
chain and a FakeAsync case bounding the window, and gated in `surface_repaint_funnel.test.js`.
**Why:** Reported as a **white** screen that **survives repeated refreshes** — "if I hit
refresh often it's still there and I'm not sure I even see progress bar properly; hitting
refresh again helps" — which is Attempt 9's trigger with Attempt 9's fix already in place.
The trigger is confirmed by the reporter, as in Attempt 9. Attempt 9 assumed one issue
produces one commit, so it spent the latch on the first settle. A user staring at a blank
page does not refresh once and wait; they refresh again, and the second `reload()` lands
inside the first document's lifetime. The aborted load settles first and spends the
repaint on a document that is already discarded, then the replacement commits onto the
blank surface with nothing armed — so *rapid* refreshing cannot clear the screen while a
single, later refresh can, which is exactly the shape of the report. A redirect chain
settling twice is the same defect with one tap. (b) exists because the reporter is the
only observer of a path nobody enumerated (gap #9) and had no way to act on one: rotating
the device is not discoverable, and refreshing — the thing users actually try — re-issues
the load and can land blank again. It is gated because the population that can act on it is
exactly the population reporting the bug, and everyone else would meet a control whose
effect they cannot interpret. (c) is why the report says the progress bar is not
obviously there: `userDrivenReload` awaits a platform HTTP-cache clear before `reload()`,
and nothing renders during that round trip, so the tap reads as ignored and invites the
rapid second tap that (a) is about.
**Why partial:** Still per-path (gap #3) — this fixes the *latch* on the settle side, not
the enumeration of triggers, and it inherits gap #6 whole: `onLoadingChanged(false)` is
still load-stop, not the compositor's first frame. The 15s window is a *guess bounded by
taste*: a commit landing later than it is uncovered, and the model encodes that premise
rather than proving it (`CloseWindow` is enabled only when nothing is in flight). It also
buys robustness with extra nudges — an unrelated navigation settling inside the window now
repaints, which is harmless but is not free. (b) is the first thing here that can
*falsify* the remedy rather than assume it (gaps #4/#5): if a user reports the menu action
clearing the screen, the nudge demonstrably recomposites on that device; if they report it
not clearing, every attempt since Attempt 2 rests on a false premise. Until such a report
exists that remains untested, and (b) is a workaround, not a fix — a menu entry the user
has to find is an admission the automatic coverage is still incomplete. The developer-mode
gate sharpens that trade-off rather than resolving it: the diagnostic now reaches only users
who were told how to unlock it, so the falsifying report needs someone to ask for it.

## Known open gaps (candidates for the next recurrence)

1. ~~Nested `InAppWebViewScreen`~~ — **closed by Attempt 6** (now funneled + gated).
2. **Forward navigation** (`goForward`) into a bfcached entry is the symmetric case of
   Attempts 5–6 and is currently unnudged. (There is no `goForward` call site today,
   but adding one on Android would need the same funnel.)
8. ~~Return from a pushed route~~ — **closed by Attempt 10** for both screens
   (`PAUSE-024`), gated structurally and covered by pixel scenarios 8 and 9.
9. **Every attach path is still enumerated by hand.** Attempt 10 found its three paths by
   auditing the code against the chokepoint list, not from a report — which is an improvement
   on waiting for users, but the audit is only as good as the reviewer, and it must be redone
   whenever a new screen hosts a webview or a new lifecycle signal appears. That is gap #3
   from the process side: a native attach callback would make the audit unnecessary rather
   than merely up to date.
3. **The class isn't closed.** Every fix is per-path. The durable fix is a **single
   chokepoint** that nudges on *every* surface (re)attach — ideally a native
   surface-changed/-redrawn callback from the fork driving the repaint — instead of
   enumerating Dart-side navigation paths forever. **Attempt 8 narrows this**: it keys the
   warm-start repaint on `didChangeMetrics` (a Dart-side *proxy* for the surface attach)
   rather than a lifecycle event, but a proxy is not the native callback and is not
   guaranteed to fire on every device, so the gap stands. **Attempt 9 is the same shape
   once more** — a reload, keyed on the load-settled proxy — and is the second recurrence
   in a row whose fix was an *ordering* one (nudge at the trigger, re-nudge at the attach
   proxy). Two data points that the durable fix is the native callback, not a longer list
   of triggers. **Attempt 11 is a third**, and the sharpest: its trigger was already
   covered — the user was refreshing, the path Attempt 9 added — and it still went blank,
   because the *settle side* of a proxy-keyed fix has its own arithmetic to get wrong. A
   native attach callback would need no latch at all, so it would have no latch to spend.
6. **Proxies fire before the compositor.** Both attach proxies now in use are upstream of
   the actual first paint: `didChangeMetrics` (Attempt 8) tracks the main FlutterView's
   metrics, and `onLoadingChanged(false)` (Attempt 9) maps to `onLoadStop`, i.e. document
   parse rather than frame commit. A surface that receives its first frame materially
   later than either signal still outruns the nudge budget. This is gap #3 seen from the
   timing side: the native callback is the only signal that *is* the attach.
4. **The TLAPS proof doesn't cover the recurrence — by construction.**
   `RepaintLiveness` is proved over `GoodSpec`/`GoodNext`, a *fixed* set of attach actions
   (`Activate`, `Resume`, `ControllerAttach`, `Back`, `Forward`, `LoadSite`, `Evict`), each of
   which sets `owed`. A real code path that (re)attaches a surface without emitting one of those
   modeled actions is simply not a transition in `Next`, so the proof can't fail on it — that
   is gap #3 restated in model terms. Two further refinement holes: the proof *assumes* `Nudge`
   physically repaints (it can't reach SurfaceFlinger), and it says nothing about a dead
   renderer (that is [BUG-002](002-black-screen.md) / `renderer.tla`, a different property). The
   code↔model bridge that is meant to catch gap #3 — `formal/trace/` plus the
   `surface_repaint_funnel` structural gate — is scoped to `lib/main.dart` back paths, not the
   memory-pressure/lifecycle path Attempt 7 covers, so that path is not yet gated.
   **Attempt 8 partly addresses this for the warm-start ordering**: `formal/warmstart.tla`
   drops the kernel's magic `WF_vars(Nudge)` and models the nudge as an event-triggered
   one-shot with a *separate* async `SurfaceReattach`, so the bad interleaving (reattach after
   the resume nudge drains) is now a reachable, model-checked counterexample instead of an
   unmodeled path; the `surface_repaint_funnel` gate now also covers the `didChangeMetrics`
   resume path. The kernel's TLAPS proof is still over the atomic-attach `GoodNext`, so the
   two models disagree by design — `warmstart.tla` is the faithful one for this ordering.
5. **The device link is unproven.** The whole fix rests on `didChangeMetrics` actually firing
   when the webview `SurfaceView` re-attaches on a real warm resume. Flutter can dedupe
   identical window metrics, and the callback tracks the main FlutterView, not the webview
   platform view. If it does not fire on the affected device, Attempt 8 is a no-op there. The
   new `SurfaceDiag` line `trigger=metrics-resume -> nudge` exists to confirm this from a
   device log; until such a trace exists, the causal claim (this fixes the reported warm-start
   white screen) is unverified.
7. ~~**First activation of a fresh site is diagnostically dark and has no commit-side nudge.**~~
   **Closed by Attempt 10** (`PAUSE-025`): the controller attach now arms the commit latch and
   emits `trigger=controller-attach -> nudge`, so the settled load repaints the first document
   and the path is no longer dark. It inherits gap #6 — load-stop is not the frame commit.
   Original report, kept for the lineage:
   Reported 2026-08-13 (sanitized log export): user cold-started to the site picker, tapped a
   not-yet-loaded site three minutes later, webview created from scratch, main-frame load
   started, white screen. The log cannot classify it because this path emits *no* SurfaceDiag:
   the `site-switch` probe early-returns silently when `model.controller == null`
   (lib/main.dart, `_probeRendererAndRecover`), which is always true for a fresh creation.
   Both nudges that do run — activation (`_setCurrentIndex`) and controller-ready
   (Attempt 4) — fire and drain *before* the initial document commits, and the settled-side
   re-nudge is latched only by `reloadIssued()` (Attempt 9), never by a first load. So if the
   commit lands late, nothing repaints after it: the Attempt 8/9 ordering shape on one more
   path. Undetermined whether that report was this bug or a load that never committed; the
   window-pixel sampler below exists to make the next occurrence classifiable.

10. **The 15s commit window is a guess.** Attempt 11 replaced a one-shot latch with a
   bounded window because the number of commits per issue is not knowable from Dart, but
   the bound itself is picked, not derived: a document that commits more than 15s after
   its issue settles outside the window and is not repainted, and `formal/reloadlatch.tla`
   *assumes* the window outlasts the in-flight loads rather than proving it. This is gap
   #6 on the other axis — not "the proxy fires too early" but "the debt expires too soon".
   The `trigger=commit-settled` line is what would show a device where it does.
13. **Whether a native attach callback closes gap #3 is now testable, and untested.**
   The instrument exists but has not been run: `RepaintSuppression` (debug-only,
   diag tiers only) drops named Dart triggers, and adb Scenario B2 warm-starts with
   `resume,metrics-resume` suppressed — so what repaints the surface afterwards is
   whatever the native layer does alone. It is OPT-IN
   (`WS_RUN_NATIVE_REPAINT_PROBE=1`) because it is expected red against a fork with
   no such hook, and a permanently-red scenario would drown this tier's other
   signals. `formal/warmstart.tla` now splits the two readings the model previously
   conflated — `Fix="proxy"` (a correlated signal that may not fire; violates
   `RepaintLiveness`) against `Fix="attach"` (the attach itself schedules the nudge;
   holds) — which is gap #5 as a model-checked difference rather than an argument.
   Upstream `starship-s/flutter_inappwebview` 643cf23 + 1a8ed58 add exactly that
   hook (`onAttachedToWindow` + `onWindowVisibilityChanged(VISIBLE)` → geometry-free
   `requestLayout()` + `postInvalidateOnAnimation()`); both cherry-pick cleanly onto
   `v6.2.0-beta.3-privacy-v6`. Note they are **View**-lifecycle callbacks, not the
   SurfaceView's own buffer callbacks, so they cover the warm-start and fresh-mount
   triggers and none of the commit-side class (Attempts 9/10/11) — they narrow gap
   #3, they do not close it.

   **Run on 2026-09-04 (PR #576): the emulator cannot answer it.** With both
   resume-time Dart repaint paths dropped and the `SurfaceDiag` trace showing
   nothing else ran, the warm-started surface came back the page colour,
   `uniform: 1.0`. On the CI emulator (API 34, x86_64, `swiftshader_indirect`)
   the reattached SurfaceView repaints with no Dart help at all, so B2 is green
   by nature there and can never be the red that justifies the fork pin. Two
   readings of the instrument had to be fixed before that was even legible, and
   both are worth knowing:
   `RepaintSuppression` gated only `_nudgeSurfaceRepaint`, while
   `_probeRendererAndRecover` repaints too — its `offsetHeight` read forces the
   layout that schedules the missing paint — and both log under the same trigger
   name, so suppressing "the resume nudge" left the other one doing the work;
   and a passing run dumped no logcat, so a green proved nothing. Both are fixed
   (the probe honours the suppression; B2 asserts both drops and prints the trace
   on success). A corollary: because the native layer alone suffices on the
   emulator, no CI run there can say whether the probe's read repaints anything —
   which leaves the contradiction between `_nudgeSurfaceRepaint`'s doc comment
   ("a JS `offsetHeight` read does not [fix it]") and `_probeRendererAndRecover`'s
   ("the read alone fixes the blank surface") open. Deciding gap #5, and the fork
   pin with it, needs a device that actually goes white.

   **The reload path answers the same way (2026-09-04, PR #576).** Gap #5's
   warm start was one route; refresh is another. Refresh is not *the* trigger --
   the symptom is reported across warm start, tab switch, fullscreen exit and
   back navigation as well, and any account that treats one entry path as the
   bug's definition is describing a route, not the bug. Refresh is worth its own
   arm because it differs in the way that should matter: a warm start carries
   a window visibility change and a reload does not, so nothing below Dart has
   an obvious reason to repaint what a reload blanks. Scenario B3-A suppresses
   all fourteen `_nudgeSurfaceRepaint` triggers, issues one reload of a page
   that stalls 5s before its first byte, and samples *past* the commit -- blank
   before it is a slow page, blank after it is the bug. The trace shows the
   four suppressions and nothing else firing, and the surface came back
   painted. So the emulator repaints reloads on its own too, and no route this
   harness has can make it go white. B3-A is therefore opt-in
   (`WS_RUN_BLANK_CONTROL=1`) and not run in CI: it is the right experiment for
   hardware that reproduces, not for this one. Three of the attempts to get
   there were instrument defects rather than evidence -- a suppression list
   missing `_probeRendererAndRecover`, one missing `metrics-resume`, and a
   dropped `os.chdir` that made every page 404 into a white error document that
   looked exactly like the bug. Each is why the tier now prints the app pid,
   the focused window, the page-server access log and the SurfaceDiag tail on
   any pixel failure.

12. ~~Which composition mode the CI emulator runs~~ — **answered 2026-09-05, and
    it is the affected one.** The worry was real: Flutter's platform-view docs
    warn that certain Android views (`SurfaceView`, `SurfaceTexture`) do not
    invalidate themselves when their content changes, so the embedder must; if
    the emulator instead composited the webview into Flutter's own frames,
    Flutter's frame loop would redraw it and the gap could not occur there by
    construction, making gap #5's and gap #11's negatives statements about the
    emulator rather than about the bug. It does not. The mode is settled in
    Dart, not at runtime: `InAppWebViewSettings.useHybridComposition` defaults
    to `true` and this app never sets it, and the fork's
    `_createAndroidViewController` routes `true` to
    `PlatformViewsService.initExpensiveAndroidView`, whose contract in the
    pinned SDK (`packages/flutter/lib/src/services/platform_views.dart`) is
    "Always creates a 'Hybrid Composition (HC)' view" with "the Android view and
    Flutter widgets ... composed at the Android view hierarchy level". No
    TLHC-or-HC fallback is in play; that logic belongs to
    `initSurfaceAndroidView`, which is the `false` branch. So the emulator runs
    the same mode as the reporting devices, and this tier's negative results
    stand as evidence. The lifecycle tier still dumps `dumpsys SurfaceFlinger
    --list`, the per-layer composition types and the platform-view logcat
    chatter on every run (`build/white_screen_adb/composition-mode.txt`,
    uploaded on green runs too) as the runtime witness — it does not decide the
    mode, and a first cut of it that tried to read the mode off the layer count
    got the reading backwards, which is why it now prints layer names and no
    verdict. What it prints on the emulator, with the webview on screen:
    `SurfaceView[<pkg>/.MainActivity]#402`, its `(BLAST)#403` buffer-queue
    child, `Background for` that same SurfaceView, and the activity's own
    window layers. One SurfaceView, which is `FlutterSurfaceView`, and no layer
    of any kind for the webview. That is consistent with HC as current Flutter
    implements it: the SurfaceView base stays and `FlutterImageView` overlays
    are added above the platform view, and an overlay is a View inside the
    window layer, not a layer of its own. So a layer list cannot separate the
    two modes in either direction, and the Dart-level determination above is
    the only sound one. Do not re-derive a verdict from this dump.

13. **Why the device reproduces and this tier does not.** The tier's negatives
    are real (gap #12), which makes this the live question, and it has one
    settled part and several open ones.

    Settled: **the emulator repaints the platform view with no Dart help.**
    Scenario B2 (warm start) and Scenario B3-A (committed reload) each
    suppressed every `_nudgeSurfaceRepaint` trigger *and* the second repaint
    path in `_probeRendererAndRecover`, showed the drops in the trace, and the
    surface came back painted anyway. So no arrangement of scenarios on this
    host can go red on this class: the symptom needs a surface that stays stale
    until something forces it, and this one does not stay stale. Adding
    scenarios is not the missing piece.

    Open: which host difference supplies that unprompted repaint. Ranked by how
    directly each bears on it, with what CI can do about it:

    1. **Software rasterisation.** The runner has no GPU, so the emulator runs
       `-gpu swiftshader_indirect`. A software compositor recomposes the whole
       frame every vsync; there is no damage-rect, buffer-age or partial-update
       path for a stale buffer to survive in. This is the best candidate and it
       is the one CI cannot change: GitHub-hosted runners have no GPU.
    2. **Animations disabled.** The emulator step runs with
       `disable-animations: true`, zeroing all three scales. BUG-001 lives in
       activity and route transitions, and a transition with no animation has a
       different surface-transaction ordering than a real one. Cheap to flip in
       this tier; untried.
    3. **Debug build.** The tier installs `app-fdebug-debug.apk`; users run
       release. JIT vs AOT changes frame timing, and the timing is what decides
       whether an attach lands before or after a commit. Flipping it costs the
       diag hooks: `RepaintSuppression` is `kDebugMode`-gated, so B2/B3-A cannot
       run against release, though the pixel scenarios could.
    4. **One site, one trivial page.** The seed is a single site serving a
       solid-colour static document from localhost. Users run many sites in the
       `IndexedStack` with real pages: slow first paint, subframes, service
       workers, and enough memory pressure to evict a renderer. Site count and
       page weight are both raisable here.
    5. **A different isolation engine.** `_useContainers` is resolved from
       `WebViewFeature.MULTI_PROFILE` at startup, and it selects a different
       webview creation path (`containerId` set, a Profile bound in the fork's
       `prepare()`). If the emulator's bundled System WebView answers
       differently from a Play-updated one on a phone, the two are not running
       the same attach path at all. The tier now records the answer.

    The tier records 1, 2, 4 and 5 per run (`host:` lines beside the
    composition dump) so a future green states what it was green on.

    **The measurement that would settle it is on the device, not here.**
    `_traceRepaint` is gated on developer mode, not `kDebugMode`, so a release
    build with developer mode on records the full SurfaceDiag trigger sequence
    into `LogService` (2000-entry ring) and Dev Tools can export it. Capturing
    that at the moment a real screen goes white separates the two hypotheses
    every attempt so far has had to guess between: **no nudge fired** (another
    unnudged path, which is gap #3 and what all eleven attempts assumed) versus
    **a nudge fired and the surface stayed blank** (the nudge itself does not
    work on real hardware, which would invalidate the remedy rather than its
    coverage). Nothing in the repository currently distinguishes them.

14. **No CI tier has ever run a non-debug build on a device.** Every Android
    device-side script builds debug: the lifecycle tier does
    `flutter build apk --debug --flavor fdebug`, and the four `flutter test`
    tiers get a debug APK by default. The release job builds the shipped APK
    and checks two static properties of it (GMS-free, JNI survived shrinking),
    then never installs it. So the artifact that goes white has not been run by
    any test.

    Two differences follow, and both sit inside the component that goes blank:

    - **`isInspectable: kDebugMode`** (`lib/services/webview.dart:1221`, `:1928`,
      `:3621`) is the *only* build-mode-dependent WebView setting in the app.
      Every webview CI drives has `setWebContentsDebuggingEnabled(true)`; every
      webview that ships has it off. An audit of `kDebugMode` across `lib/`
      turns up nothing else touching the webview: the rest is startup
      stopwatches, log forwarding, and the diag hooks themselves.
    - **JIT vs AOT.** Frame timing decides whether an attach lands before or
      after a commit, and every ordering fix in this file (PAUSE-020/021/025/027)
      is about exactly that ordering.

    The tier can now drive `profile` (`WS_LIFECYCLE_BUILD_MODE=profile`, also a
    `workflow_dispatch` input), which flips both: AOT, `isInspectable` false,
    and still debuggable, because Flutter's profile build type is
    `initWith(debug)` (`FlutterPlugin.kt:250`) so the native `FLAG_DEBUGGABLE`
    gate the diag channels use still passes. Three gates moved from `kDebugMode`
    to `!kReleaseMode` to let it through — `DiagSeed`, `RepaintSuppression`, and
    `LogService`'s logcat forwarding — none of which changes release behaviour,
    which is what those gates were protecting.

    This does not reach the shipped artifact: profile does not run R8, and
    `minifyEnabled true` with `proguard-android-optimize.txt` is release-only,
    with no keep rules for the fork or androidx.webkit beyond their own consumer
    rules. That gap stays open.

    One correction rides along, because it changes where the next fix should
    look. The `SurfaceView`-does-not-self-invalidate rule was cited here as the
    root mechanism, but under HC the platform view is an `android.webkit.WebView`
    in the Android view hierarchy, and a `WebView` is not a `SurfaceView` — it
    draws through a functor into whatever surface contains it and never owns a
    SurfaceFlinger layer. The surface that can present a stale frame in HC is
    Flutter's own: `FlutterView.convertToImageView()` swaps the render surface
    for `FlutterImageView`s, which present whatever image was last acquired and
    do not repaint on their own. That is consistent with the symptom and with
    why a 1px inset toggle clears it, but it is a different surface from the one
    the doc quote names, and any fix aimed at "invalidate the platform view's
    SurfaceView" would be aimed at the wrong object.

   **The same run is the first direct evidence that PAUSE-027 works.**
   Scenario B3-B drives five reloads 120ms apart against that 5s page, so four
   commits abort before the fifth lands -- the shape that spent the old
   one-shot latch on an aborted load. Every reload nudge coalesced into one
   loop, and then `commit-settled` fired as a *fresh, uncoalesced* nudge when
   the real document committed ~5s later, and the surface stayed painted. That
   is the bounded commit window doing exactly what Attempt 11 built it for,
   observed on a real surface rather than argued. B3-B runs unconditionally and
   is now that fix's regression guard.

   **Forcing GPU composition was tried and could not be tried (2026-09-05).**
   The one cheap hypothesis for why the emulator repaints unasked is hardware
   overlays: an overlay-composed layer is re-scanned out every frame from
   whatever its buffer last held. `service call SurfaceFlinger 1008 i32 1`, the
   old "Disable HW overlays" developer-option call, was accepted and discarded
   on API 34 both as shell and as root, with `dumpsys` still reporting four
   layers at `composition type=DEVICE`. `1008` is a raw binder code from before
   SurfaceFlinger moved to AIDL and no longer maps to that toggle. B3-A now
   verifies that precondition and *skips* rather than failing, because a red
   from an arm whose precondition never held is the same false evidence this
   scenario exists to prevent. The overlay hypothesis is untested, not
   disproved; testing it needs whatever the developer option calls on a modern
   API level.
12. **The trace is now honest but still opt-in.** `PAUSE-029` closed the coverage half
   of the diagnostic — every path reports, and a new one cannot be silent — but the
   developer-mode gate means a user who hits the bug has no trace *of the occurrence that
   prompted them to report it*. They can only capture the next one. That is the deliberate
   trade against evicting the log ring in every ordinary session, and it is why the
   integration tiers assert on the trace rather than waiting for a user to supply one.
11. **Nobody has confirmed the nudge repaints on the affected device.** Gaps #4 and #5
   restated as an open question, not a modelling hole: every attempt since Attempt 2
   assumes the 1px inset flip physically recomposites the SurfaceView, and no device
   report has ever tested that in isolation, because every automatic nudge fires
   alongside something else. Attempt 11's menu entry (`PAUSE-028`) is the isolated test —
   one user, one tap, no navigation — and until someone reports what it does, this stays
   the single largest untested premise in the whole lineage. The developer-mode gate means
   that report will not arrive on its own: someone has to walk a reporter through the seven
   taps, so treat asking as part of triaging the next recurrence.

## Guardrails now in place

- **Formal model** ([formal/kernel.tla](../../formal/kernel.tla)): `RepaintLiveness`
  (every blank-surface attach is eventually repainted); the `bypass` demonstrator *is*
  this bug and TLC rejects it. Liveness backbone proved for unbounded N in
  [formal/proofs/repaint_liveness.tla](../../formal/proofs/repaint_liveness.tla).
- **Reload-latch model** ([formal/reloadlatch.tla](../../formal/reloadlatch.tla), run by
  `formal/check.sh`): the settle side of the commit latch, which `warmstart.tla` does not
  model. `reloadlatch_bug.cfg` (Fix="oneshot") reproduces the rapid-refresh white screen
  (`RepaintLiveness` violated on the second commit); `reloadlatch.cfg` (Fix="window")
  proves the bounded window closes it; `reloadlatch_reach.cfg` proves the spent-latch
  state is reachable.
- **Warm-start model** ([formal/warmstart.tla](../../formal/warmstart.tla), run by
  `formal/check.sh`): models the nudge as an event-triggered one-shot with a *separate*
  async `SurfaceReattach` (no magic `WF(Nudge)`), so the warm-start ordering the kernel
  can't see (gap #4) is a reachable counterexample. `warmstart_bug.cfg` (Fix="none")
  reproduces BUG-001 (`RepaintLiveness` violated); `warmstart.cfg` (Fix="attach")
  proves the attach-triggered re-nudge closes it; `warmstart_reach.cfg` proves the
  ordering is reachable (non-vacuous).
- **Engine characterization** ([test/surface_repaint_engine_test.dart](../../test/surface_repaint_engine_test.dart),
  runs under `fvm flutter test`): the same ordering in runnable Dart. `SurfaceRepaintEngine`
  tracks `owed`; a late `attach()` with no re-nudge stays `owed` (reproduction), the metrics
  re-nudge clears it (fix), including a timing-faithful 800ms-reattach case.
- **Structural gate** ([test/js/surface_repaint_funnel.test.js](../../test/js/surface_repaint_funnel.test.js),
  runs under `npm run test:js` in CI): on the main page, every Android `controller.goBack()`
  must route through `_goBackAndRepaint`. A new raw back path (the recurrence shape of
  Attempts 2–5) fails CI. Now also asserts the warm-start wiring: `didChangeMetrics` re-nudges
  within the post-resume window, and a resume opens that window. Partial: scoped to
  `lib/main.dart`; the nested screen (gap #1) is not yet gated.
  Attempt 9 adds the reload half: every `controller.reload()` in `web_view_model.dart` and
  `inappbrowser.dart` must sit inside a `reloadAndRepaint` funnel that latches the reload,
  `main.dart` must wire both host hooks to the engine, and each file must drive the repaint
  off the load-settled signal. A new raw reload fails CI.
  Attempt 10 adds three more: both webview screens must be `RouteAware`, subscribe and
  unsubscribe from `surfaceRouteObserver`, and nudge in `didPopNext` (with the observer
  registered on `MaterialApp`); each controller-attach handler must arm the commit latch as
  well as nudge; and the nested screen must carry the resume window + `didChangeMetrics`
  re-nudge. Dropping any of that wiring — the way a refactor quietly would — fails CI.
  Attempt 11 adds the latch's own shape: both hosts must arm through `_armCommitLatch`,
  which must restart a `SurfaceRepaintEngine.commitWindow` timer and close the window;
  nothing may call `noteCommitPending` outside it (an unbounded window is as much a defect
  as a one-shot one); `dispose` must cancel the timer; and both menus must carry the
  manual repaint entry wired to `_repaintCurrentSurface`, with *every* occurrence behind
  both the Android and the developer-mode gate (counted, not matched: a second menu with
  one ungated entry is the regression shape). It also holds the reporting contract: the
  funnel must take a trigger label and report through `_traceRepaint`, no call site may
  omit a label or hand-write a line, and `_traceRepaint` must carry the developer-mode
  gate, the throttle and the flush-timer cancel.
- **Window-pixel detector + scenario suite**
  ([android/.../SurfaceDiagPlugin.kt](../../android/app/src/main/kotlin/org/codeberg/theoden8/webspace/SurfaceDiagPlugin.kt),
  [lib/services/surface_diag_native.dart](../../lib/services/surface_diag_native.dart),
  [integration_test/white_screen_test.dart](../../integration_test/white_screen_test.dart)):
  the first guardrail that measures the *symptom* instead of inferring it from a trigger
  path. Window-level `PixelCopy` reads the composited pixels the user actually sees —
  the plane no JS probe (renderer) or Flutter capture (raster tree, no platform views)
  can reach — and classifies uniform white/black over the webview rect. The integration
  suite (emulator step in the `build-android` CI job, every push/PR) drives the
  in-process-drivable entry paths (fresh first activation incl. gap #7, loaded-site
  switch, reload funnel, memory pressure, fresh activation among live sites, plus
  Attempt 10's route return and nested screen) and fails on a blank window, with a white
  control page proving the detector is not vacuous.
  Until Attempt 10 it was nonetheless **blind to the ordering every recurrence since
  Attempt 8 is about**: every page it served committed in a millisecond, so the repaint
  always landed while the issue-time nudge loop was still running, and no scenario could
  tell "the fix works" from "the fix was never needed here". Scenarios 7 and 9 now
  withhold the first byte for 3s, which puts the commit outside the ~0.6s nudge budget and
  leaves the settled-side re-nudge as the only thing that can paint it.
  Not yet wired into production
  diagnostics; doing so would give `SurfaceDiag` log lines a `window=` classification.
  First emulator run confirmed the sampler reads real webview pixels on SwiftShader and
  surfaced a third signature: a platform view that has not composited at all samples as
  uniform 0x00000000 (alpha 0) — distinct from the white (fresh fill) and black
  (re-attach) blanks.
- **Adb-driven lifecycle tier** ([scripts/run_android_lifecycle_tests.sh](../../scripts/run_android_lifecycle_tests.sh),
  INTEG-011, same emulator step, every push/PR): the three entry paths an in-process
  test cannot survive — **warm start** (Attempt 8's trigger), **activity recreation**
  (the black variant's trigger), and **bfcache back navigation** (Attempts 5–6's
  trigger, via the system BACK key through the production `_goBackAndRepaint` funnel) —
  driven from outside the process via adb. Symptom read from the composited frame
  (`screencap`, the SurfaceFlinger plane) and classified by
  [scripts/classify_window_pixels.py](../../scripts/classify_window_pixels.py) with the
  in-app sampler's thresholds; a white control cold start proves this plane is not
  vacuous either. Site list is injected at launch by a debug-only `ws_diag_seed`
  intent extra ([lib/services/diag_seed.dart](../../lib/services/diag_seed.dart)) and
  activated through the production pinned-shortcut `siteId` extra (a plain cold start
  shows the webspace picker with no site selected), so the cold-start scenario also
  pixel-checks the shortcut launch path (Attempt 2's trigger).
  With this tier, every documented entry path (Attempts 3–9 plus gap #7) has
  symptom-level pixel coverage in CI; still emulator compositing, so a
  device-specific SurfaceFlinger race can outrun it (see INTEG-010's limitation note).

## Diagnostic checklist (when this recurs)

- Confirm there is a **document to paint** at all. A load the OS stranded while the app
  was backgrounded (background network restrictions, a per-app firewall such as
  CalyxOS/Datura) leaves either the engine's "connection failed" page or a page that
  never commits — the latter is white and looks exactly like this bug with a different
  cause. Tell them apart by the report: a blank that a rotate/tab-switch instantly clears
  is this bug; a blank that survives a relayout, or a visible "connection failed", is
  `PAUSE-022` (`ResumeReloadEngine`), which re-issues the load on resume. No nudge can
  fix that one.
- Confirm it's the **surface**, not a dead renderer: does the page respond to taps /
  does a rotate or tab-switch instantly fix it? If yes → surface, use the nudge. If a
  rotate doesn't fix it and JS is dead → renderer death, a different bug:
  [BUG-002](002-black-screen.md) (`PAUSE-013/014`).
- Identify the **new entry path**: what navigation/lifecycle event preceded the blank?
  Does it pass through `_setCurrentIndex` (Attempt 3) or `onControllerReady`
  (Attempt 4)? If neither, that path needs `_nudgeSurfaceRepaint`.
- Add the path to the **spec** (`PAUSE-0xx`) and to the **next entry in this file**,
  noting what it covered and why earlier attempts missed it.
