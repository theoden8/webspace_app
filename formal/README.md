# Formal verification (`formal/`)

Model-checked state machines for the specs whose bugs live at composition
boundaries. This is one layer of a defense-in-depth pipeline; each layer is meant
to absorb a class of issue before it reaches the next:

```
spec            openspec/specs/<slug>/spec.md   normative Given/When/Then requirements
  ↓
formal          formal/*.tla                    model-check invariants + liveness + "does it mix?"
  ↓
engine          lib/services/*_engine.dart      pure-Dart orchestration, no Flutter/native
  ↓
tests           test/*.dart                     unit + contract + fakeAsync interleaving over engines
  ↓
app code        lib/                             the implementation
  ↓
integration     integration_test/               on-device: real engine + native; trace source
```

The formal layer absorbs what tests cannot: **design contradictions, missing-transition
classes, and cross-spec interference** — bugs that exist in the gaps *between* specs and
are invisible to any single-spec test. BUG-001 (white screen) is the worked example: five
partial fixes, each closing one navigation/lifecycle path that re-attached a blank surface
without repainting. `formal/kernel.tla` states that as a liveness property and rejects the
class.

## What's here

- **`kernel.tla`** — the cross-spec kernel. Variables are the *shared* runtime/persisted
  state (`surface`, `owed`, `currentIndex`, `loaded`, …). Each coupled spec contributes a
  module: the state it owns, its actions, and the invariant it preserves. Requirement IDs
  (`PAUSE-018`, …) are cited on the actions/properties that encode them.
  - Composed today: `webview-pause-lifecycle` (PAUSE-013..018) + `navigation` +
    `lazy-webview-loading`. Good composition: 24 distinct states.
- **`kernel.cfg`** — the good composition (`Conflict = "none"`). Expect: all properties hold.
- **`kernel_conflict_repaint.cfg`** (`Conflict = "bypass"`) — a back path that re-attaches
  the surface but bypasses the repaint chokepoint (the literal BUG-001 failure). Expect:
  safety holds, `RepaintLiveness` **violated** (a LIVENESS non-mix, lasso counterexample).
- **`kernel_conflict_evict.cfg`** (`Conflict = "evict"`) — lazy-loading evicts the *visible*
  site, dropping its "never evict current" guarantee. Expect: `Inv_CurrentLoaded`
  **violated** (a SAFETY non-mix). The two demonstrators show the gate catching both kinds.
- **`check.sh`** — fetches `tla2tools.jar` if absent and runs all three configs, asserting
  the good one passes and both demonstrators fail as expected. CI-wireable.

## Run it

```bash
./formal/check.sh
```

Or directly:

```bash
java -cp tla2tools.jar tlc2.TLC -config formal/kernel.cfg                  formal/kernel.tla  # passes
java -cp tla2tools.jar tlc2.TLC -config formal/kernel_conflict_repaint.cfg formal/kernel.tla  # liveness violated
java -cp tla2tools.jar tlc2.TLC -config formal/kernel_conflict_evict.cfg   formal/kernel.tla  # safety violated
```

The demonstrators' counterexamples are the point. The repaint one is a lasso ending in
`surface = "blank"` stuttering forever after `BackBypass` sets `frozen = TRUE` — the model
showing the exact interleaving that wedges the screen. The evict one is a short trace
reaching a state where `currentIndex \notin loaded`.

## How a module is structured (rely-guarantee)

```
Module(spec) = {
  owns:      state variables this spec alone mutates
  actions:   its transitions over (owned ∪ shared) state
  invariant: the property it must preserve (its Then-clauses)
  contract:  rely      = what it assumes others won't do to shared state
             guarantee = how it promises to touch shared state
}
```

- **Disjoint state ⇒ composes for free.** A spec that owns its variables and reads/writes
  nothing shared cannot interfere; it does NOT belong in the kernel. Most specs are here.
- **Shared state ⇒ must check interference.** Two modules writing the same shared variable
  can each preserve their invariant alone yet violate it jointly. That check is the kernel.

## Adding a spec: "does it mix?"

```
1. Write the spec (openspec/specs/<slug>/spec.md) — Given/When/Then.
2. Static gate: does it mutate shared kernel state?
     no  → leaf. No kernel module. (Covered by cross-spec structural invariants instead.)
     yes → continue.
3. Write its module in kernel.tla: owned vars, actions, invariant, rely/guarantee contract.
4. Mix gate: add its actions to Next and its property to the .cfg; re-run check.sh.
     clean          → it mixes. Commit the enlarged kernel.
     counterexample → it does not mix. The trace names the breaking interleaving:
        - new action breaks an existing invariant → the feature breaks someone's guarantee
        - an existing action breaks the new invariant → the new guarantee is too strong
     Fix the design, not the model.
5. If TLC's state count explodes: re-express as assume-guarantee — check the module
   against the kernel's interface contract (small) instead of the full product (huge).
6. Code gate: wire LogService events (below) so the implementation stays inside the module.
```

Steps 4 and 6 are the two halves you always need together: **4 proves the design mixes;
6 proves the code stayed inside the design.** One without the other is the gap that produced
BUG-001's five partial fixes.

## Model ↔ code conformance (the bridge)

Model-checking verifies the *design*; it says nothing about whether the Dart code takes a
transition the model never declared (the "unmodeled path" that defeats pure model-checking).
The codebase already emits a structured event trace via `LogService` — e.g.
`[WebViewLifecycle/debug] onLoadStop siteId=… url=…`, `[CookieIsolation/debug] Switching to
site 2…`, `[Container/debug] …`. That stream is a `(subsystem, state, action)` log. The
conformance step (future work): define a trace schema, replay `integration_test/` traces,
and flag any transition the kernel's `Next` does not permit. That is what catches a new code
path that skipped its module.

## Honest limits

- Verifies the **design composition**, and (via traces) **executed code** — never a
  whole-system code proof. No deductive verifier exists for Dart.
- The kernel is only the **coupled cluster**. Most specs are leaves and are better served by
  static cross-spec invariants (registry completeness, nested-webview field flow, keyspace
  disjointness) — relational checks with no temporal cost.
- Bounded domains (`N = 3` sites): model-checking is exhaustive only within the bound.
- The realistic deliverable: **design-level interference becomes a CI check** instead of a
  production incident discovered after N partial fixes.

## Bug ↔ spec ↔ model traceability

| Bug | Spec | Model property |
|-----|------|----------------|
| [BUG-001 white screen](../docs/bugs/001-white-screen.md) | `webview-pause-lifecycle` PAUSE-013..018 | `kernel.tla` `RepaintLiveness` |
