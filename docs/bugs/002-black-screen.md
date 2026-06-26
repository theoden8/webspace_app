# BUG-002: Black screen on return to a backgrounded site (dead renderer)

**Status:** open (the offscreen case is covered by the probe; minor path gaps remain)
**Platform:** Android + iOS/macOS (the OS kills renderer/content processes on all three)
**Spec:** [openspec/specs/webview-pause-lifecycle/spec.md](../../openspec/specs/webview-pause-lifecycle/spec.md) — `PAUSE-013`, `PAUSE-014`
**Formal model:** [formal/renderer.tla](../../formal/renderer.tla) — `Recovered` (a visible dead renderer is always eventually rebuilt); the `noProbe` demonstrator reproduces this bug's offscreen partial and TLC rejects it.
**Tests:** [test/webview_renderer_gone_test.dart](../../test/webview_renderer_gone_test.dart) (behavioral) + [test/js/renderer_gone_recovery.test.js](../../test/js/renderer_gone_recovery.test.js) (wiring gate)

## Symptom

The user backgrounds the app (or switches to another site), comes back — often via a
pinned shortcut — and the page is a **black/blank rectangle that is dead**: taps, scroll,
and JS do nothing, and **a rotate / lock-unlock / tab-switch does NOT fix it**. The webview
never recovers on its own.

## Root mechanism (the invariant behind every instance)

The OS **kills the WebView's renderer / web-content process** to reclaim memory after the
app has been backgrounded (Android `onRenderProcessGone`, iOS/macOS
`onWebContentProcessDidTerminate`). The native WebView *object* is still alive, but it has
**no renderer driving it** — per Android docs it is unusable and must be **destroyed and
rebuilt**. The live JS heap and DOM are gone with the process; the back/forward stack can't
be saved. So the only recovery is to **dispose the dead webview and recreate it** at its
`currentUrl`.

**Not the same bug as [BUG-001](001-white-screen.md).** That one is a *blank surface with a
live renderer* — JS runs, and a relayout (rotate / nudge) repaints it; the fix is a 1px
surface nudge, never a dispose. Here the **renderer is dead** — a nudge does nothing; the
fix is destroy-and-rebuild. The two are told apart by one question: *does the page respond
to taps / does a rotate fix it?* Yes → BUG-001 (surface). No, and JS is dead → BUG-002
(renderer).

## Fix attempts (chronological)

### Attempt 1 — Event-driven renderer-gone recovery (`PAUSE-013`)
**Date:** 2026-05-28 · **PR:** #382-era · **Files:** lib/web_view_model.dart, lib/main.dart
**What it did:** Wired `onRenderProcessGone` / `onWebContentProcessDidTerminate` to
`WebViewConfig.onRendererGone`, which calls `WebViewModel.handleRendererGone`: it **disposes
the cached widget and controller** (`webview = null; controller = null`) and invokes
`stateSetterF`, so the host rebuild reconstructs a fresh `InAppWebView` at `currentUrl`.
**Why:** A dead renderer leaves a permanently black, unusable WebView; destroy-and-rebuild is
the only cure (the process holding the DOM/JS is gone).
**Why partial:** The platform termination event **frequently does not fire when the renderer
dies while the webview is offscreen** — especially iOS jettisoning the content process of a
view not in the hierarchy. With no event, nothing drives recovery and the site stays black on
return. This is the dominant case the user hits returning via a pinned shortcut (which
activates a previously-offscreen site).

### Attempt 2 — Proactive renderer probe on activation (`PAUSE-014`)
**Date:** 2026-06-04 · **PR:** #388 · **Files:** lib/main.dart, lib/web_view_model.dart
**What it did:** On every site activation (`_setCurrentIndex`) and app resume, probe the
renderer: evaluate `document.body ? document.body.offsetHeight : -1`. A dead process makes
`evaluateJavascript` throw, surfaced as `null`; `rendererProbeIndicatesGone(result)` returns
true **only** for `null` (every number — `0`, `-1`, positive — is alive, so a healthy/loading
page is never recreated). On `null` it joins the same `handleRendererGone` destroy-and-rebuild.
**Why:** Catches the offscreen renderer deaths that fire no event — the case Attempt 1 missed.
**Why partial:** The probe runs only on the resume / `_setCurrentIndex` activation paths. A
renderer death surfaced through a path that does not funnel through those (a webview shown
without going through `_setCurrentIndex`) would not be probed. On Android the probe also
doubles as the surface paint nudge (the `offsetHeight` read forces a synchronous layout) —
overlapping with [BUG-001](001-white-screen.md)'s remedy.

### Attempt 3 — Renderer-gone recovery in the nested screen (`PAUSE-013` + `PAUSE-014`)
**Date:** 2026-06-26 · **PR:** #451 · **Files:** lib/screens/inappbrowser.dart
**What it did:** Wired `onRendererGone` in the nested `WebViewConfig` to `_handleRendererGone`,
which bumps a `KeyedSubtree` generation key to remount a fresh `InAppWebView` (the nested analog
of the main screen's destroy-and-rebuild), and added a `didChangeAppLifecycleState` resume probe
(`offsetHeight` → `rendererProbeIndicatesGone`) for the offscreen case. Gated by the structural
test so it can't silently regress.
**Why:** The nested screen had NEITHER recovery path (confirmed while fixing the sibling BUG-001
gap #1) — a renderer death there was a permanent black screen. This is the recurring-bug shape:
main path fixed, nested path forgotten, exactly mirroring BUG-001 gap #1.
**Why partial:** Recovery remounts at the nested **entry** URL (`widget.url`), not the current
in-nested URL — in-nested navigation is lost on recovery (acceptable vs. a permanent black
screen, but not byte-equal to the main screen's `currentUrl` rebuild).

## Known open gaps (candidates for the next recurrence)

1. **Nested recovery reloads the entry URL, not the current one** (Attempt 3 limitation). A
   proper fix would rebuild the nested webview's config at `_currentUrl` (needs the `late final
   _webView` factored into a rebuildable builder), so in-nested navigation survives a renderer
   death — matching the main screen's `currentUrl` behavior.
2. **Probe coverage is tied to `_setCurrentIndex` + resume.** Even on the main path, a renderer
   death surfaced through an activation that bypasses those (a background notification site
   reloaded off the switch path) would not be probed; it relies on the event firing, which
   Attempt 1 showed is unreliable offscreen.
3. **Recovery loses session state.** Destroy-and-rebuild reloads at `currentUrl`; the JS heap,
   DOM, scroll position, and back/forward stack are gone (unavoidable — the process died). The
   `savedForRestore` snapshot mitigates form/scroll loss only where one was captured first.

## Diagnostic checklist (when this recurs)

- **Renderer or surface?** Does the page respond to taps, and does a rotate / tab-switch
  instantly fix it? **Yes → [BUG-001](001-white-screen.md)** (live surface; nudge). **No, JS
  is dead → BUG-002** (dead renderer; destroy-and-rebuild).
- Confirm the recovery fired: look for `Renderer gone for "…" — recreating` in the logs. If
  it never logged, the **event didn't fire and no probe ran** → the activation path needs to
  funnel through `_probeRendererAndRecover` (gap #1).
- `rendererProbeIndicatesGone` must treat only `null` as gone — never `0`/`-1`/positive, or a
  healthy page reload-loops. Covered by `test/webview_renderer_gone_test.dart`.
