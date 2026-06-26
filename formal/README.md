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
    `lazy-webview-loading` + `per-site-cookie-isolation`. Good composition: 24 states.
- **`kernel.cfg`** — the good composition (`Conflict = "none"`). Expect: all properties hold.
- **`kernel_conflict_repaint.cfg`** (`Conflict = "bypass"`) — a back path that re-attaches
  the surface but bypasses the repaint chokepoint (the literal BUG-001 failure). Expect:
  safety holds, `RepaintLiveness` **violated** (a LIVENESS non-mix, lasso counterexample).
- **`kernel_conflict_evict.cfg`** (`Conflict = "evict"`) — lazy-loading evicts the *visible*
  site, dropping its "never evict current" guarantee. Expect: `Inv_CurrentLoaded`
  **violated** (a SAFETY non-mix).
- **`kernel_conflict_contaminate.cfg`** (`Conflict = "contaminate"`) — the legacy cookie
  engine activates a site without capture-nuke-restore, leaving another site's cookies in the
  shared jar. Expect: `Inv_JarMatchesVisible` **violated** (a cross-site-leak SAFETY non-mix).
- **`archive.tla`** + `archive*.cfg` — ARCH-001 active-state **byte-identity**. This is a
  2-safety *hyperproperty* (it relates two executions: 0 vs N closed archives), so it does
  NOT join the single-execution kernel — it gets its own model via **self-composition** (run
  both worlds in lockstep, assert app-tier state never diverges). The `Leak` demonstrator
  folds the archive count into app-tier state and is caught.
- **`renderer.tla`** + `renderer*.cfg` — BUG-002 dead-renderer recovery (PAUSE-013 +
  PAUSE-014). `Recovered` (a visible dead renderer is always eventually rebuilt); the
  `noProbe` demonstrator drops PAUSE-014 and reproduces the offscreen-kill stuck black
  screen. Standalone (renderer lifecycle, no shared kernel state).
- **`trace/`** — the model↔code conformance bridge (below).
- **`proofs/`** — TLAPS deductive proofs for **unbounded N** (the bounded-TLC backstop). See
  [proofs/README.md](proofs/README.md): `Inv_CurrentLoaded` is proved for all `N >= 1`
  (51 obligations, machine-checked by tlapm).
- **`check.sh`** — fetches `tla2tools.jar` if absent and runs the full matrix (good + the
  three demonstrators + reachability witnesses + archive byte-identity + trace conformance).
  CI-wireable. (TLAPS proofs run separately — `proofs/check_proofs.sh` — they need tlapm.)

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

## Testing the model itself (per-requirement matrix)

A model can be wrong: vacuously true, over-constrained, or asserting a mis-stated invariant.
`check.sh` is a two-sided test matrix that guards against this — the same red/green discipline
as code tests, applied to the model:

- **NEGATIVE (anti-vacuity)** — `*_conflict_*.cfg`. A deliberate mutation that breaks a
  requirement MUST be caught. Proves the invariant actually *constrains* something rather than
  holding for free. `bypass` → `RepaintLiveness` violated; `evict` → `Inv_CurrentLoaded` violated.
- **POSITIVE (anti-inertness)** — `*_reach_*.cfg`. A reachability witness (`Reach_*`) used as an
  invariant that MUST be violated, so TLC's counterexample *is* the proof that the legal behavior
  the green checks rely on is reachable. Guards against a model that satisfies everything because
  nothing happens (a blank attach never occurs, a site is never switched, nothing is evicted).

Each requirement contributes a (positive witness, negative mutation) pair. A green safety/liveness
check is only meaningful alongside a passing positive witness — otherwise it may be vacuous. The
remaining gap (model faithful to the *code*, not just the *spec*) is closed by trace conformance.

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

## Model ↔ code conformance (the bridge) — `trace/`

Model-checking verifies the *design*; it says nothing about whether the Dart code takes a
transition the model never declared (the "unmodeled path" that defeats pure model-checking).
The codebase already emits a structured event trace via `LogService` — e.g.
`[CookieIsolation/debug] Switching to site 2…`, `[CookieIsolation/debug] After switch, loaded
indices: {1, 2}`, `[Navigation/debug] Back gesture: navigated back`. That stream is a
`(subsystem, state, action)` log. `trace/` turns it into a conformance check:

- **`trace/parse_log.py`** projects LogService lines onto the kernel's *observable* variables
  (`cur`, `loaded`, `jar`) and emits a `Trace` module. (The hidden variables `surface`/`owed`/
  `frozen` are not observable from logs — that is exactly why BUG-001 was invisible — so this
  validates the observable projection: navigation + lazy-loading + cookie-isolation.)
- **`trace/conformance.tla`** checks every recorded step is a legal observable kernel
  transition (`TraceConforms`) and that the observable safety invariants held at every state
  (`ObsInvariants`: `cur ∈ loaded`, `jar = cur`).
- **`trace/check_trace.sh`** runs it on fixtures: `sample_good.tracelog` (a real navigation excerpt)
  **must conform**; `sample_bad.tracelog` (activates a site that isn't loaded) **must be caught**.

This is what flags a new code path that skipped its module. `check.sh` runs it after the
kernel matrix. Next step: feed real `integration_test/` traces through `parse_log.py`.

## Honest limits

- Verifies the **design composition**, and (via traces) **executed code** — never a
  whole-system code proof. No deductive verifier exists for Dart.
- The kernel is only the **coupled cluster**. Most specs are leaves and are better served by
  static cross-spec invariants (registry completeness, nested-webview field flow, keyspace
  disjointness) — relational checks with no temporal cost.
- Bounded domains (`N = 3` sites): TLC is exhaustive only within the bound. For invariants
  that need to hold for *all* N, `proofs/` carries unbounded TLAPS proofs (e.g.
  `Inv_CurrentLoaded`).
- The realistic deliverable: **design-level interference becomes a CI check** instead of a
  production incident discovered after N partial fixes.

## Bug ↔ spec ↔ model traceability

| Bug | Spec | Model property |
|-----|------|----------------|
| [BUG-001 white screen](../docs/bugs/001-white-screen.md) | `webview-pause-lifecycle` PAUSE-015..018 | `kernel.tla` `RepaintLiveness` |
| [BUG-002 black screen](../docs/bugs/002-black-screen.md) | `webview-pause-lifecycle` PAUSE-013/014 | `renderer.tla` `Recovered` |
| (visible site unloaded) | `lazy-webview-loading` | `kernel.tla` `Inv_CurrentLoaded` |
| (cross-site cookie leak) | `per-site-cookie-isolation` | `kernel.tla` `Inv_JarMatchesVisible` |
