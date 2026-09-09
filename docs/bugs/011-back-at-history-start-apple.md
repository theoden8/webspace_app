# BUG-011 — Back-at-history-start misreads history on Apple

Status: open

## Symptom

With the opt-in "back gesture opens the menu" setting (NAV-009) on, the
left-edge swipe on iOS resolves against the wrong history state. Faces
seen so far:

- The drawer slides in mid-article, on a page the swipe should have
  navigated back from.
- At the actual start of a site's history the swipe does nothing, which
  is what the setting was turned on to change.
- Before either: the setting shipped and had no effect at all on
  iOS/macOS, so the row read as broken.

## Root mechanism / invariant

At the moment an edge swipe arrives, nothing on Apple tells the app
whether the visible webview has a previous history entry.

- `canGoBack()` under-reports `history.pushState` entries on WKWebView
  (NAV-002) and reports true for entries the page has since replaced, so
  an affordance gated on it opens the drawer where history exists and
  stays shut where it does not.
- The substitute signal — call `goBack()`, wait a fixed settle, compare
  the URL — is wrong in both directions too. A same-URL history entry
  (pushState to the same address, a fragment, a replaceState-heavy SPA)
  reads as "no history"; a navigation that commits after the settle
  window reads as "no history"; a redirect or a late async URL update
  reads as "history".
- The app only gets to evaluate either signal if it takes the left edge
  away from WKWebView, which owns it
  (`allowsBackForwardNavigationGestures`, NAV-001) and resolves the swipe
  silently inside itself. The root site webview sits at the `MaterialApp`
  root route, so there is no Flutter pop for `PopScope` to intercept
  either.

The invariant: **on iOS and macOS the app has no reliable "is there a
previous history entry" signal at gesture time, so no affordance may
branch on one.** WKWebView is the only component that knows, and it does
not say. The normative rule lives in
[openspec/specs/navigation/spec.md](../../openspec/specs/navigation/spec.md)
(NAV-001, NAV-002, NAV-009).

## Fix attempts

1. **Pre-#371 (date not in this repo's history).** `drawerEdgeDragWidth`
   was left enabled on iOS exactly while a tracked `_canGoBack` was
   false, so the Scaffold's own edge drag opened the drawer at what it
   believed was the start of history. *Why partial*: gated on
   `canGoBack()`, which is unreliable in both directions on WKWebView —
   the drawer opened where history existed and stayed shut where it did
   not.

2. **#371, then #512.** #371 removed both the edge drag and the
   `_canGoBack` tracking; #512 later enabled
   `allowsBackForwardNavigationGestures` on the root site webview, handing
   the edge to WKWebView outright. *Why partial*: removed the symptom by
   removing the behaviour. Issue #431 asked for it back, so the class was
   dormant, not closed.

3. **2026-08-22 — PR #549, `a8951c0`.** Reintroduced it as an opt-in
   global setting (NAV-009) decided by a pure engine and driven from the
   `PopScope` handler. *Why partial*: covered Android, where the system
   back button reaches `PopScope`. On Apple the root route has no pop and
   WKWebView consumes the swipe, so the setting was inert — visible in
   App Settings and doing nothing.

4. **2026-09-03 — PR #565, `8b13e7f`.** Claimed a 24px strip of the left
   edge on iOS with a horizontal drag recognizer and routed it through
   the same policy, deciding history from `goBack()` plus a 150ms URL
   diff. *Why partial*: swapped one unreliable history signal for
   another. The gesture now reached the app, but the drawer still opened
   over pages that had history, and the strip cost WKWebView's
   interactive swipe animation for every session that opted in.

5. **2026-09-09 — this change.** Removed the edge strip and scoped the
   NAV-009 setting to non-Apple platforms: the row is absent from App
   Settings on iOS/macOS and a restored backup carrying `backOpensMenu`
   does not turn the behaviour on there. The Apple left edge is
   WKWebView's again (NAV-001). *Why partial*: it removes the misread by
   removing the affordance — the same move as attempt 2, so the request
   behind #431 is again unserved on Apple (see gaps).

## Known open gaps

- **iOS/macOS have no back-at-history-start option.** Issue #431's
  request stands unmet there. Attempt 2 shows that leaving it unmet is
  how the class recurs: someone will ask again.
- **A third attempt needs a history signal, not a third heuristic.** The
  only candidate is in-page: a `DOCUMENT_START` script counting real
  history depth by wrapping `pushState`/`replaceState` and listening for
  `popstate`. It is itself partial — the counter resets on every
  cross-origin document, and `history.length` includes forward entries —
  so it must be treated as a signal to validate before an affordance is
  built on it, not after.
- **Nothing gates the recurrence in code.** The engine test asserts the
  setting is not offered on Apple
  ([test/back_gesture_engine_test.dart](../../test/back_gesture_engine_test.dart)),
  which fails if the platform predicate is widened, but nothing stops a
  new call site reading `canGoBack()` on iOS to drive UI.
