# BUG-003: User-script source runs before its library (ReferenceError)

**Status:** open (SPA/history path now gated; other injection races may remain)
**Platform:** all (observed on iOS; the mechanism is platform-independent event ordering)
**Spec:** [openspec/specs/user-scripts/spec.md](../../openspec/specs/user-scripts/spec.md) — `US-002b`
**Tests:** [test/js/user_script_shim.test.js](../../test/js/user_script_shim.test.js), [test/user_script_test.dart](../../test/user_script_test.dart)

## Symptom

Console errors of the form `ReferenceError: Can't find variable: <Library>` (e.g.
`DarkReader`) on sites with a user script that pairs a CDN library (`urlSource`) with
user init code (`source`). The library eventually loads and the script works, so the
feature *appears* fine — the errors are the user's init code firing into a JS context
where the library half has not been evaluated yet. Observed on linkedin.com (iOS),
several times per page load.

## Root mechanism (the invariant behind every instance)

A script with `urlSource` is injected as ONE unit (library + source) by
`initialUserScripts` at its configured injection time. But the injection *lifecycle*
has several other entry points that re-run `source` (or the full script) via
`evaluateJavascript`: `onLoadStart`, `onLoadStop`, and `onUpdateVisitedHistory` (SPA
re-inject). **Any of those entry points that fires before the initial injection has
evaluated the library, and runs `source` anyway, throws.** The invariant every fix
must preserve: *`source` may only execute in a JS context where the script's library
has already been evaluated* — which is exactly what the per-document
`window.__wsRan_<id>` flag records.

## Fix attempts (chronological)

### Attempt 1 — Skip `urlSource` scripts in onLoadStart/onLoadStop re-injection
**Date:** pre-2026-06-10 (history shallow; documented in `reinjectOnLoadStart`'s doc comment) · **Files:** lib/services/user_script_service.dart
**What it did:** `reinjectOnLoadStart` / `reinjectOnLoadStop` skip any script whose
`urlSource` is non-empty; those scripts rely solely on the native
`initialUserScripts` mechanism.
**Why:** Re-injecting large libraries via `evaluateJavascript` at `onLoadStart` races
the JS context setup and caused these ReferenceErrors on full page loads.
**Why partial:** Only covered the `onLoadStart`/`onLoadStop` paths. The third re-run
path — `reinjectOnSpaNavigation` from `onUpdateVisitedHistory` — still ran `source`
unconditionally, and `onUpdateVisitedHistory` fires for `history.replaceState` churn
*during* the initial page load, before the library has been evaluated.

### Attempt 2 — Gate SPA re-inject on the `__wsRan_<id>` flag + same-URL dedup
**Date:** 2026-07-07 · **Files:** lib/services/user_script_service.dart, lib/services/webview.dart
**What it did:** `reinjectOnSpaNavigation` wraps each `source` re-run in
`if (window.__wsRan_<id>) { ... }` — the flag the guarded initial injection sets — so
the re-run is a logged no-op until the library has actually been evaluated in this
document. Also deduped the trigger: `onUpdateVisitedHistory` events whose URL matches
the last SPA-re-injected URL (or the pending `onLoadStart` URL) are skipped, and the
dedup URL resets on `onLoadStart`.
**Why:** LinkedIn calls `replaceState` several times while the document is still
loading; each event re-ran `DarkReader.enable(...)` before `darkreader.js` had been
evaluated. Skipping is safe because an unset flag means the initial injection is
still pending and will run library + source itself.
**Why partial (known gaps):** (a) If the *initial* injection itself fails mid-library
(e.g. an exception inside the library), the flag is set but the library API may be
absent — `source` re-runs will still throw; the flag records "attempted", not
"succeeded". (b) A BFCache restore where the document was evicted but
`onLoadStart` never fires could leave `source` un-re-run for that URL (dedup marks
the URL consumed on every history event).

## Known open gaps

- The `__wsRan_<id>` flag conflates "injection ran" with "library evaluated
  successfully". A library that throws partway leaves the flag set.
- `reinjectOnSpaNavigation` re-runs `source` for ALL enabled scripts on every route
  change; libraries whose init has network side effects (DarkReader re-fetching page
  CSS through `__wsFetch`) repeat those side effects per route change. Dedup only
  collapses same-URL churn, not the cost of legitimate route changes.
