# BUG-006 — Site settings silently drop unsaved changes on leave

Status: closed (structural gate `test/js/site_settings_dirty_snapshot.test.js`
subsumes per-field fixes: a form field loaded in `_loadFromModel` but missing
from `_currentSnapshot` now fails CI instead of shipping unguarded)

**Spec:** [openspec/specs/site-editing/spec.md](../../openspec/specs/site-editing/spec.md) — EDIT-009

## Symptom

The user edits something on the per-site settings screen, leaves without
tapping Save (system back, app-bar back, iOS edge swipe), and the change is
gone — no "Discard changes?" prompt, no snackbar, nothing. Reads as the
setting not working at all when the user later finds it unchanged.

## Root mechanism / invariant

The screen decides whether to warn by diffing the live form against a
snapshot map (`_currentSnapshot`) captured on open and after each save;
`PopScope.canPop` is `!_isDirty()`. The map is a **hand-enumerated list of
fields**. Any form field that exists in the UI but is not registered in the
map is invisible to the diff: editing only that field leaves `_isDirty()`
false, `canPop` stays true, and the pop proceeds silently. So every new
per-site setting added to the screen re-opens the symptom for its own field
unless its author remembers the registration step. The invariant: **every
field `_loadFromModel` assigns must be referenced in `_currentSnapshot`,
except fields fully derived from an already-registered field.**

## Fix attempts

1. **2026-06-13 — PR #418 (`100843d`).** Added the mechanism: snapshot map,
   `_isDirty()`, `PopScope` + discard dialog; text controllers poke
   `setState` so `canPop` re-evaluates per keystroke. *Why partial*: the
   snapshot enumerates fields by hand with nothing enforcing completeness.
   Correct for every field that existed on that date, silently wrong for
   any field added later without registration.

2. **2026-06-27 — PR #454 (`2fe004f`).** Not a fix — the regression.
   Added kiosk mode as a new settings tile (`_kioskMode`: loaded, rendered,
   saved) but never registered it in `_currentSnapshot`. Toggling only
   Kiosk Mode and leaving discarded the change with no warning.

3. **2026-07-17 — this branch.** Registered `_kioskMode` in
   `_currentSnapshot`, and closed the class with a structural gate
   (`test/js/site_settings_dirty_snapshot.test.js`): it parses
   `_loadFromModel` assignment targets and asserts each is referenced in
   `_currentSnapshot`, with a justified allowlist for derived fields
   (currently `_liveGpsApproximate`, covered by
   `_liveLocationGranularity`). A forgotten registration now fails
   `npm run test:js` in CI naming the field.

## Known open gaps

- The gate keys off `_loadFromModel`. A hypothetical form field initialized
  elsewhere (inline initializer only, never loaded from the model) would
  escape it — though such a field also wouldn't reflect persisted state, so
  it would be broken in a more visible way first.
- Sub-screens reached from settings (user scripts, domain claims, QR
  import) apply their changes immediately via callbacks rather than through
  the Save flow; they are outside this mechanism by design and do not
  silently drop anything.
