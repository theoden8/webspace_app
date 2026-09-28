# BUG-020 — The HTTP auth tier's tap misses the remember box on the Android emulator

Status: open

**Spec:** [http-auth-prompt](../../openspec/changes/http-auth-prompt/specs/http-auth-prompt/spec.md)
HTTPAUTH-007, scenario "Every platform runs the real-engine tier"
**Test:** [integration_test/http_auth_test.dart](../../integration_test/http_auth_test.dart),
"the prompt signs in, says when a password is refused, and remembers"

## Symptom

`Build Android` → `Run emulator integration scenarios` fails in
`scripts/run_android_http_auth_tests.sh`:

```
Warning: A call to tap() with finder "Found 1 widget with type "Checkbox" ...
derived an Offset (Offset(84.0, 371.3)) that would not hit test on the specified widget.
...
Expected: true
  Actual: <false>
the remember box must be ticked before signing in
```

The hit lands on the retry dialog's own `Material` at local x=44, and the
dialog is at full height, so the box's centre is below the dialog's scroll
viewport. A re-run passes, so it shows up as an unrelated flake on whatever
branch is running (master at `1cdeb1d`, run 36340715484; PR #198 at
`f51b3744`).

## Root mechanism / invariant

`IntegrationTestWidgetsFlutterBinding.registerTestTextInput` is false, so
`enterText` and autofocus raise the emulator's real soft keyboard. The IME
shows and hides it on its own schedule, and on a swiftshader emulator that can
be well after the request. Every inset change resizes the dialog through its
`AnimatedPadding`, and the remember row is the last child of the dialog's
`SingleChildScrollView`, so it is the first thing a shrinking viewport hides.

The invariant: **a tap is only as good as the layout it was aimed at, so
the check that the target is visible and the tap itself must see the same
frame.** A fixed pause before `ensureVisible` and another before `tap` leaves
a frame between the two in which the keyboard can land. Reproduced in a widget
test by raising a simulated keyboard 150ms into the first pause. The first
frame after the inset change still lays out the full-size dialog (the
`AnimatedPadding` starts from its old value), so `ensureVisible` does nothing.
The next frame shrinks the dialog, and the tap misses with the same
hit-test chain as CI.

## Fix attempts

1. **2026-09-27 — PR #637** (`f9ed591`). Added `unfocus()`, a 300ms pump,
   `ensureVisible` on the box, another 300ms pump, and an assertion that the
   box is ticked, on the reading that the keyboard was up and simply covered
   the row. *Why partial*: it treated the keyboard as a fixed state rather
   than a moving one. `unfocus()` only *requests* the hide, and a show request
   still in flight from the dialog's autofocus can land after the first pause.
   The single `ensureVisible` is then aimed at a layout that the next frame
   replaces. It failed on master the day it merged.

2. **2026-09-28 — this branch.** `tapWhenHittable` in the test: each
   iteration scrolls the box in, pumps a frame, and taps only once
   `find.byType(Checkbox).hitTestable()` matches. It hit-tests the same
   centre point and render object that `tap()` uses, and only microtasks run
   between the check and the pointer-down, so no frame can move the box in
   between. The alternative proposed on PR #198 was rejected: re-tapping with
   `warnIfMissed: false` until the box is ticked aims each tap at a layout
   that may be moving, and a miss can land on Cancel or Sign in. *Why
   partial*: see the gaps below.

## Known open gaps

- The helper lives in this one test. Nothing stops a new integration test
  from tapping inside a scroll view after text entry with fixed pauses, and it
  would only fail on the Android emulator, intermittently.
- The helper waits up to 30s for the layout to hold still for one frame. An
  IME that keeps toggling the keyboard for longer still fails the case, now
  with a message naming the remember box rather than an unticked assertion.
