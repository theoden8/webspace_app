# BUG-006 — Site settings silently drop unsaved changes on leave

Status: closed (one `DirtyGuard` mixin, `lib/widgets/dirty_guard.dart`, guards
every editor; `test/js/site_settings_dirty_snapshot.test.js` fails CI when a
form field loaded in `_loadFromModel`, or a member written into a form object
in place, is missing from the settings screen's `snapshot()` record, and when a
screen with a Save action does not mix the guard in)

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

4. **2026-09-09 — PR #589 (`6f68e7d`).** Not a fix — the regression.
   Added the Tor exit country row, which writes into the form's proxy object
   in place (`_proxySettings.torExitCountry = ...`). The gate saw
   `_proxySettings` referenced in `_currentSnapshot` (through
   `_proxySettings.type`) and passed, but the snapshot never read the exit
   country, so pinning one and leaving discarded it with no prompt.

5. **2026-09-28 — this branch.** Registered `_proxySettings.torExitCountry`
   in `_currentSnapshot`, and added a second rule to the gate: every
   `_field.member = ...` statement in `settings.dart` must have
   `_field.member` referenced in the snapshot. Found while moving the
   network controls onto the per-site Network screen (NET-001), whose value
   object carries the exit country. *Why partial*: attempt 3 closed the
   class at field granularity, and a form object is one field holding
   several values; the member rule reads plain assignment statements, so a
   member changed through a method call or a cascade would still escape it.
   Regression test: `test/site_settings_network_row_test.dart` ("pinning a
   Tor exit country guards the leave").

6. **2026-10-06 — `refactor/settings-primitives`.** The symptom through a
   path with no guard at all: the user script editor and the webspace editor
   each have a Save action and popped on back, dropping whatever had been
   typed. The three guards that did exist (site settings, App Settings'
   outbound proxy, the proxy library editors) were three copies of the
   snapshot-map diff with three dialogs. All five now mix in `DirtyGuard`,
   whose snapshot is a record (field-by-field `==` from the compiler, with
   `ValueList`/`ValueSet` for collections, where a joined string stood in
   before), and the gate gained a third rule: every `lib/screens` file with a
   `_save`/`_saveSettings` method mixes the guard in. *Why partial*: the
   record still lists the settings screen's fields by hand, so the per-field
   rule stays; the editor rule keys off the method name. Regression test:
   `test/editor_discard_guard_test.dart`.

## Known open gaps

- The member rule matches `_field.member = ...` statements only. A form
  object mutated through a method (`_proxySettings.pin(...)`) or a cascade
  would not be seen; keep form objects plain, or replace them whole.

- The gate keys off `_loadFromModel`. A hypothetical form field initialized
  elsewhere (inline initializer only, never loaded from the model) would
  escape it — though such a field also wouldn't reflect persisted state, so
  it would be broken in a more visible way first.
- Sub-screens reached from settings (the user script list, domain claims,
  QR import, saved sign-ins) apply their changes immediately via callbacks
  rather than through the Save flow; they are outside this mechanism by
  design and do not silently drop anything. The user script *editor* is not
  one of them: it has a Save action and is guarded (attempt 6).
- The editor rule finds editors by a `_save`/`_saveSettings` method; an
  editor whose save action is named otherwise escapes it. The four "Site" screens
  (behaviour, network, privacy, permissions) are not in that set: they
  report into the settings screen's fields, which the snapshot reads.
