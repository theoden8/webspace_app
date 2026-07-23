# BUG-001: White/black screen after returning to or navigating a webview (Android)

**Status:** open (recurring — each fix has closed one entry path; new paths keep surfacing)
**Platform:** Android only (hybrid-composition `SurfaceView`)
**Spec:** [openspec/specs/webview-pause-lifecycle/spec.md](../../openspec/specs/webview-pause-lifecycle/spec.md) — requirements `PAUSE-013`…`PAUSE-018`
**Formal model:** [formal/kernel.tla](../../formal/kernel.tla) — `RepaintLiveness` ("every blank-surface attach is eventually repainted"). The `kernel_conflict.cfg` demonstrator is a back path that bypasses the chokepoint — i.e. this exact bug — and TLC rejects it with a counterexample.

## Symptom

The webview area renders as a flat **blank** rectangle — **black** or **white** —
while the page underneath is *alive*: JS runs, taps/scroll register, timers fire.
A relayout (device rotation, lock/unlock, tab switch) instantly clears it. The
user just sees a dead-looking screen after some navigation or app-lifecycle event.

## Root mechanism (the invariant behind every instance)

On Android the webview is a **hybrid-composition `SurfaceView`**. That surface can
**re-attach (or newly attach) without receiving a paint**. The renderer is healthy,
so nothing emits an error event; the compositor just never draws onto the new
surface until something forces a relayout.

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
**Date:** 2026-07-23 · **Files:** lib/main.dart, openspec/specs/webview-pause-lifecycle/spec.md
**What it did:** On `resumed`, `_openResumeRepaintWindow` opens a bounded (~3s)
window; while open, the new `didChangeMetrics` override fires `_nudgeSurfaceRepaint`.
Additive to Attempt 2's tail nudge in `_onResumed`, which still fires once.
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

## Known open gaps (candidates for the next recurrence)

1. ~~Nested `InAppWebViewScreen`~~ — **closed by Attempt 6** (now funneled + gated).
2. **Forward navigation** (`goForward`) into a bfcached entry is the symmetric case of
   Attempts 5–6 and is currently unnudged. (There is no `goForward` call site today,
   but adding one on Android would need the same funnel.)
3. **The class isn't closed.** Every fix is per-path. The durable fix is a **single
   chokepoint** that nudges on *every* surface (re)attach — ideally a native
   surface-changed/-redrawn callback from the fork driving the repaint — instead of
   enumerating Dart-side navigation paths forever. **Attempt 8 narrows this**: it keys the
   warm-start repaint on `didChangeMetrics` (a Dart-side *proxy* for the surface attach)
   rather than a lifecycle event, but a proxy is not the native callback and is not
   guaranteed to fire on every device, so the gap stands.
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

## Guardrails now in place

- **Formal model** ([formal/kernel.tla](../../formal/kernel.tla)): `RepaintLiveness`
  (every blank-surface attach is eventually repainted); the `bypass` demonstrator *is*
  this bug and TLC rejects it. Liveness backbone proved for unbounded N in
  [formal/proofs/repaint_liveness.tla](../../formal/proofs/repaint_liveness.tla).
- **Structural gate** ([test/js/surface_repaint_funnel.test.js](../../test/js/surface_repaint_funnel.test.js),
  runs under `npm run test:js` in CI): on the main page, every Android `controller.goBack()`
  must route through `_goBackAndRepaint`. A new raw back path (the recurrence shape of
  Attempts 2–5) fails CI. Partial: scoped to `lib/main.dart`; the nested screen (gap #1)
  is not yet gated.

## Diagnostic checklist (when this recurs)

- Confirm it's the **surface**, not a dead renderer: does the page respond to taps /
  does a rotate or tab-switch instantly fix it? If yes → surface, use the nudge. If a
  rotate doesn't fix it and JS is dead → renderer death, a different bug:
  [BUG-002](002-black-screen.md) (`PAUSE-013/014`).
- Identify the **new entry path**: what navigation/lifecycle event preceded the blank?
  Does it pass through `_setCurrentIndex` (Attempt 3) or `onControllerReady`
  (Attempt 4)? If neither, that path needs `_nudgeSurfaceRepaint`.
- Add the path to the **spec** (`PAUSE-0xx`) and to the **next entry in this file**,
  noting what it covered and why earlier attempts missed it.
