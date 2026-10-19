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
- **`warmstart.tla`** + `warmstart*.cfg` — BUG-001 warm-start white screen (PAUSE-020).
  `RepaintLiveness` with the nudge modeled as an event-triggered one-shot and the
  SurfaceView reattach as a *separate* async action (no magic `WF(Nudge)`), so the ordering
  the kernel's atomic `Resume == Attach` hides is reachable; `Fix="none"` reproduces the
  blank surface, `Fix="attach"` closes it. Standalone (one surface, no shared kernel state).
- **`reloadlatch.tla`** + `reloadlatch*.cfg` — BUG-001 rapid-refresh white screen
  (PAUSE-027). The *settle* side of the same ordering: `Fix="oneshot"` is the one-shot
  commit latch, which the aborted load of a double refresh spends, leaving the replacement's
  commit blank and violating `RepaintLiveness`; `Fix="window"` is the bounded window that
  repaints every commit inside it. Standalone (one surface, bounded issue count).
- **`proxy.tla`** + `proxy*.cfg` — proxy mutual exclusion (spec: `proxy`). `Inv_ProxyCoherent`
  (every loaded site shares the active proxy, because Android serialises mismatched-proxy
  sites onto one native proxy slot); the `mismatch` demonstrator co-loads a mismatched site
  and is caught. A slot's proxy is its running identity's (`ident`, LIR-018/LIR-024): a
  hosted tab's rebind serialises the visible slot and unloads a background one; the
  `staleident` and `sitenotslot` demonstrators keep a mismatched background slot loaded and
  serialise by the sites instead of their slots. Standalone (fixed scenario).
- **`process_route.tla`** + `process_route*.cfg` — the process-wide proxy rule's own
  timing (PROXY-008, BUG-037), as `ProcessRoute` runs it: claims that take a ticket and wait
  for the rule's turn, writes out one at a time, releases at any moment. `Inv_Covers` (a
  page sends only on its own route), `Inv_NoGhost` (the rule lists only what runs),
  `Inv_Assert` (the code's assert holds); the `readd`, `midwrite` and `noturn` demonstrators
  list a released occupant, void a claim only during its write, and let two writes out at
  once. Standalone: which sites run when is `activation.tla`'s.
- **`retention.tla`** + `retention*.cfg` — memory-pressure cascade picker (PAUSE-006).
  `Inv_CurrentKept` (the active site is never evicted) + `Inv_NotifLast` (higher-retention /
  notification sites are evicted last); the `starve` demonstrator evicts a retained site early
  and is caught. Standalone (one monotone pressure episode).
- **`containers.tla`** + `containers*.cfg` — per-site container keyspace disjointness (spec:
  `per-site-containers`). `Inv_Disjoint` (the site → container binding is injective, so no two
  sites share storage); the `alias` demonstrator binds two sites to one container and is
  caught. A relational invariant (the Alloy-shaped property), checked bounded in TLC.
  `Inv_PostureMatchesContainer` (LIR-018: a slot binds the container of the site whose posture
  and cookie mirror it applies); the `ownermirror` demonstrator binds a host's container while
  mirroring cookies to the owner.
- **`kiosk.tla`** + `kiosk*.cfg` — kiosk-mode shell lock (spec: `kiosk-mode`).
  `Inv_LockedIsSealed` (a locked kiosk-shortcut session hides the drawer / tab strip / app-bar
  actions and holds fullscreen) + `Inv_LockMatchesSource` (lock ⇔ kiosk-shortcut launch); the
  `exitfs` and `chrome` demonstrators leave fullscreen / build the drawer while locked and are
  caught. Standalone (a pure UI state machine; no shared kernel state).
- **`store_serial.tla`** + `store_serial*.cfg` — secure-storage write serialisation (specs:
  `cookie-secure-storage`, `proxy-password-secure-storage`, ARCH-001). `Inv_NoLostUpdate`
  (every completed read-modify-write's key stays persisted, because the static write lock makes
  each RMW atomic); the `interleave` demonstrator splits the read and the write (the unlocked
  path) and drops a concurrently-committed key. Standalone (a fixed N-op scenario).
- **`switchguard.tla`** + `switchguard*.cfg` — site-switch version guard vs a concurrent
  structural mutation (specs: `navigation`, `lazy-webview-loading`). `Inv_NoWrongActivation`
  (a superseded switch bails rather than committing against a stale positional index); the
  `noguard` demonstrator drops the version check and, after a delete/import/archive mutation,
  activates the wrong site (the legacy-mode cross-site cookie exposure). Standalone (a UI
  orchestration state machine; no shared kernel state).
- **`jar_nonempty.tla`** + `jar_nonempty*.cfg` — legacy cookie engine: the shared jar is never
  left empty across a superseded restore (spec: `per-site-cookie-isolation`).
  `Inv_JarRepopulated` (once nuked, the jar is always repopulated before the engine returns to
  rest); the `bail` demonstrator restores-with-bail and leaves the jar empty for the next
  activation to capture and persist as `[]` (the session-wipe). Standalone.
- **`activation.tla`** + the configs printed from `lib/formal_model/checks.dart` — site activation at the granularity of its
  awaits (specs: `lazy-webview-loading`, `per-site-cookie-isolation`, `per-site-containers`,
  `webview-pause-lifecycle`). Taps, home, memory pressure, preloads, row moves and sign-ins
  land only when every flow waits on a platform reply, as an event does in Dart; what runs between two
  awaits is one step, and a flow handed the jar's turn takes it as any other step, unordered
  with the rest (the queue hands it on in a microtask). Where `kernel.tla`
  and `switchguard.tla` take a switch as one step, this splits it at every await the code has
  (nav load, conflict unloads, the pause of the site it leaves, the jar restore's five calls,
  the container, the target's resume) beside pressure unloads and moves. The pause it sends
  every other loaded site after its commit is unawaited and changes nothing modelled, so the
  walk answers it at once. Invariants: the shown site is loaded at rest (LAZY-007), one loaded
  site per base domain (ISO-001), no session lost or crossed (BUG-032), no priority-picked
  unload disposes the shown site or the live activation's target (PAUSE-006, BUG-033).
  `ColdStart` starts it at launch instead: nothing loaded, every session in its storage, the
  jar holding whatever the last session left, any site's, and the jar's clear queued for its
  first turn; notification sites load there as preloads, activations that do not show. Eleven
  planted mistakes, each a bug the code once had or would deadlock, are each caught (the cold
  start's `lateclear`, a clear outside the jar's turns, and `preloadbare`, a site loaded with
  no restore, among them; `keepturn`, a jar operation that ends holding its turn, is a
  deadlock, which every config here checks for: a behavior may end only in `Done`); six
  witnesses show the interleavings are reached. The same code under
  the same alphabet is enumerated in Dart by `test/activation_schedules_test.dart`, from
  launch too. Standalone, so `kernel.tla`'s proofs stand. A site's tabs (TAB-003, BUG-036)
  are the tab tables' flows under `activation_tabs.cfg`, its containers twin, beside
  webspace switches `activation_tabs_spaces.cfg` and, on a routed slot,
  `activation_tabs_router_containers.cfg` (a rebind that reroutes the slot opens it
  again, LIR-024: `Reach_Reopened`, and `noreopen` its mutant): which tab
  each webview, queued back stack and saved file holds the history of (`built`, `hist`,
  `queued`, `file`), with `Inv_TabShown`, `Inv_TabFiles`, `Inv_TabBound` and `Inv_TabActive`
  held across taps, pressure and go-home between the tab flows' awaits; `pointerearly` (the
  bug's first shape), `captureatreply` (its capture keyed after a rebind) and `takeany` (its
  restore side) are printed mutants. The plan's proxy and Tor rules are printed too
  (`ProxyContenders`, `TorDissenters`, over the environment's `Contending`, `Route`, `TorExit`
  and `TorRuntime`): `activation_proxy.cfg` and its containers twin, the router's shared
  session (`activation_router_containers.cfg`) and two Tor exits
  (`activation_tor_containers.cfg`) hold `Inv_OneRoute` (PROXY-008: running sites in one proxy
  scope run one route, running Tor sites one exit) across taps and preloads, and
  `preloadmismatch` is a background load that skips the check. A nested screen runs as a
  site beside the loaded ones (`nested`, the sites `Running`): the nested open is a flow of
  the activation table, and `activation_nested*.cfg` let a link open any site nested
  (`Linked`) while the page underneath takes no input; `nestedonce` (an open that does not
  ask again once the proxy moved) and `preloadunchecked` (a preload that commits beside the
  screen) are printed mutants. A background wake's headless checks run beside them too
  (`headless`, among `Running`): the wake is a table of its own (`BackgroundWakeEngine.table`),
  the app's lifecycle its `Background` and `Foreground` inputs (`fore`), and
  `activation_wake*.cfg` turn on the sites' notifications (`Notified`) and the lifecycle
  (`Waking`) to hold `Inv_OneRoute` and `Inv_ChecksOffScreen` (the app back on screen ends
  every check, NOTIF-016); `wakeunchecked` (a check that does not ask the rule) and
  `wakebesidetap` (one that goes up beside an activation in flight) are printed mutants. The
  DNS lists are a table too (`DnsBlockService.table`): a download of the app-wide level, of a
  level a site asks for, and the clear, whose one write puts the lists and the level in force
  (`dns`) and tells each live view its site's level (`told`, `ViewBlockers`); a frame builds
  and drops the views (`ViewBuilt`, `ViewGone`, hand-written), and `activation_dns*.cfg` hold
  `Inv_Told` with the sites' levels (`SiteLevel`) and the levels a download picks
  (`DnsLevels`); `foldbeforelevel` (the views told with the level the fold replaces) is a
  printed mutant. A webspace chosen on the list is an input of the activation table too
  (WEBSPACE-013): it supersedes an activation in flight, waits for the device's online
  answer, and unloads, as choices, the loaded sites it stops showing (`Away`); the
  `activation_spaces*.cfg` hold the activation's invariants across it and `Inv_LeftHidden`
  (no site the switch left is on screen while it stands), and `spaceold` (the switch that
  superseded nothing) is a printed mutant. An archive close is a table of its own
  (`ArchiveController.closeTable`, ARCH-014): it takes the archive's sites off the list
  (`gone`) in one commit that supersedes an activation in flight, waits for the frame that
  unmounts their webviews (`views`), then deletes their containers (`boxes`), which a
  mounted webview's binding keeps; a frame mounts every loaded site's webview (`Frame`,
  hand-written), and a tap the close superseded deletes again a container it made for a
  site no longer on the list. `activation_archive_containers` holds `Inv_Sealed` (once
  closed, none of the archive's sites is loaded, on screen, mounted or on disk), and
  `closenoframe` (the deletes before the frame) is a printed mutant. The
  caps are constants too (`MaxLoaded`, `MaxResident`): the
  plan picks any evictable sites of the size the caps leave, and
  `activation_cap_containers.cfg` runs them at two and one.

  Part of it is printed from the code, so that part cannot drift from it. An engine written as
  a step table ([`lib/services/step_table.dart`](../lib/services/step_table.dart)) reads and
  writes the model's variables through one declaration each (`Var`, `Mutable`, `Indexed`,
  `Members`), so a guard or a write is one tree that runs in the engine and prints as TLA+,
  and the runner asserts after every step that nothing outside the arm's declared writes
  changed; `lib/formal_model/main.dart` prints the tables' actions: `activation_tables` from
  `SiteActivationController`, `SiteUnloadEngine` and `CookieIsolationEngine`, and
  `activation_steps` (`Outcomes`) from `ActivationStep`. The inputs that start a flow (a tap,
  home, a preload, memory pressure) are steps of the activation table too (`Step.input`),
  printed as `InputTableStep`. A step that starts another table's input in its own turn
  declares it, a `Spawn` (the tab rebind that reroutes a slot opens it again, LIR-024):
  the runner starts it after the arm's other effects and its mark and asserts the input
  landed there once, an input landing in a step's turn any other way fails an assert, and
  the printer prints the input's effects in the step's action on the flow numbered next
  (`Starts`, which `Input` takes too), over the state the arm leaves; a behavior that would
  start one past the last input ends there (`Done`). An operator of the engines' own (`Evictable`, `Stale`,
  `Conflicts`, `Spare`, `Gone`, `Share`, the pressure plan's sets) is a `Def` in the engine
  that owns its variables, run there and printed as `activation_ops`. `activation_base.tla`
  holds the variables, the constants and the environment's operators (the inputs' timing,
  the jar's turn, the ghosts);
  `activation.tla` the environment's inputs (a row move, a page signing in, the launch
  clear), the invariants and the witnesses. A mistake in a table or a definition is a mutant,
  a copy with the fault printed beside it under `mutants/<name>/`; a mistake in the environment
  is a `Mistake` value. Every check of `activation.tla` is a value of an enum in
  `lib/formal_model/checks.dart`: an `ActivationWorld` (its constants and the invariants that
  hold there), a `Witness` it must reach, a `Mutant` with the invariant it breaks and the
  worlds it breaks it in, a `HandMistake`. Each prints as one config, and `check.sh` runs the
  list (`checks.tsv`), so a mutant that names no check does not compile. A check of a
  mutant or a witness checks only the invariant it expects violated: the world's own check
  holds the rest on every state. A mutant is planted in the code too: the runner takes its
  tables and definitions in place of the code's inside `Planted.run` (`planted`,
  `models.dart`), and `test/planted_mistakes_test.dart` names, per mutant, the schedule
  script the walk breaks with it planted and holds without it, or owes why no script
  reaches it, a list that only shrinks. The printed modules and configs are derivatives:
  `verify.sh` writes them under `build/formal/`, and nothing commits them.
- **`proxy_failclosed.tla`** + `proxy_failclosed*.cfg` — proxy fail-closed (specs: `proxy`,
  `ip-leakage`). `Inv_NoDirectWhenProxied` (a non-DEFAULT-proxy site blanks the load rather
  than falling back to a direct connection when the proxy can't be built); the `failopen`
  demonstrator falls back to direct (the empty-address / swallowed-throw / null→direct leak).
  Standalone. (Complements `proxy.tla`'s coherence invariant with the no-leak-egress one.)
- **`trace/`** — the model↔code conformance bridge (below). `trace/check_steps.sh` holds the
  code to `activation.tla` step for step: each step the engines mark (`ActivationStep`, whose
  names and outcomes the model's `Outcomes` is printed from) is recorded with the
  projected state after it, every schedule's marks are merged into one trie per page, and TLC
  walks the model in lockstep with the trie, requiring every node to be reached: each
  schedule is a run of the model, step for step. Reached, not followed from every matching
  state, since a choice the model makes before the code shows it (the cap's pick, named by
  the unload after it) leaves states no later step follows. Branches no schedule
  takes are listed in `trace/steps_uncovered.tsv` with their reasons; a copy of a trace whose
  first nuke leaves the jar full must be caught.
- **`proofs/`** — TLAPS deductive proofs for **unbounded N** (the bounded-TLC backstop). See
  [proofs/README.md](proofs/README.md): `Inv_CurrentLoaded` is proved for all `N >= 1`
  (51 obligations, machine-checked by tlapm).
- **`lean/`**: Lean 4 proofs, over any action well formed over its printed footprint, of
  when a check may be split (below, [What a footprint licenses](#what-a-footprint-licenses)).
- **`check.sh`** — fetches `tla2tools.jar` if absent and runs the full TLC matrix (good + the
  demonstrators + reachability witnesses + archive byte-identity + trace conformance), with
  the printed modules from `FORMAL_MODEL`. `FORMAL_ONLY=<SECTION>` runs one section. The
  runs are independent, so they go concurrently, `FORMAL_SLOTS` cores at a time (default:
  all), and report in the list's order; one that did not behave prints TLC's error and the
  rest still report, so each that did is remembered, and the suite fails at the end. A run
  takes the share of the cores its last time (kept under `FORMAL_CACHE`, default
  `~/.cache/webspace-formal`) is of all of theirs, and the longest start first, a run with
  no time yet counted as the mean. A run with no timing history gets half the cores
  (at least one); a sole uncached run gets all of them. The pool keeps their total
  within `FORMAL_SLOTS`. While waiting for a result, the report prints its workers,
  elapsed time and latest TLC progress every minute (`FORMAL_PROGRESS_SECONDS`).
- **`verify.sh`** — the one way to run all of it: prints the modules and writes the walk and
  step traces (`flutter test`), then `check.sh`, `trace/check_steps.sh` and the TLAPS
  proofs. CI's `validate` job runs it. The schedules record their traces in `FORMAL_SLOTS`
  shards side by side, each every nth test (`SCHEDULE_SHARD`, so the heavy worlds declared
  together spread out), each into its own directory, and the replay
  merges a configuration's shards into one trie, a node by its parent, label and state, so
  what it replays and counts does not depend on how many shards ran. The expanded test
  reporter is selected explicitly: the startup handshake waits for its loading line
  before starting the next shard, which GitHub's default reporter does not emit.

## Run it

```bash
./formal/verify.sh          # everything: needs Flutter, Java, Python 3, tlapm
./formal/verify.sh --fast   # the printed modules and activation.tla only
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

## Composition by footprint

The rule above, applied to the flows the code runs. A flow's footprint is the model's
variables it reads and writes. A table action's is a function of its declarations: every
leaf of a step table says what it reads (`Reads`), every operator unions its operands', a
hand-written string names what it reads, and the printer writes each action's as
`activation_footprints.tsv`, resolving the definitions the engines own through their
bodies. `footprint.py` reads every action's from its printed text as well (written:
primed; read: named unprimed, through every operator it calls) and which actions each
world takes from TLC's coverage of the world's holding check, which `check.sh` records.

- **Declared and printed agree:** a table action whose declarations read or write other
  than its text does fails, and a read dropped from a declaration is planted on every run.
  The base's operators a table calls (`BaseOp`) are read from their text until the base is
  printed too.
- **A flow's row is its own:** every action writes `fl` only at its own flow
  (`fl EXCEPT ![f]`), so two actions meet on `fl` only where one reads another flow's row
  (`Kinds`, `LiveTarget`), never by both writing their own.
- **A read of other rows names them:** `Expr.inFlight(kind)` (`"<kind>" \in Kinds`) reads
  the kind of the rows of that kind, `LiveTarget` the newest tap's version and site
  (`RowRead`). The printer follows every table's arms by place name to the kinds a row
  can hold at each place (an input gives it, an end leaves none) and prints each action's
  kinds and the fields of its own row it writes, so a reader meets only the steps that
  can write a field it reads in a row of a kind it reads. A table action whose text reads
  `fl` and declares no rows fails, and such a drop is planted on every run.
- **What an action needs is read off its guards:** each constant of the model is a
  `ModelConst`, and a leaf that reads one says what it needs (a set a world fills, a
  switch set or left); `/\` unions needs, `\/` and `IF` intersect them, an arm after a
  branch on a switch needs the other setting, and a place needs what every way there
  does, kind by kind: a branch on the flow's own kind (`isKind`) lets only that kind
  through, so the graph follows each kind of flow apart. Needs are necessary, never sufficient: every world that takes an action gives its
  needs (`activation_worlds.tsv` says which constants a world sets), and a need planted
  on an action a world takes without it fails every run. What a value needs to be false
  (`unless`) is carried too, so an arm needs the failing of every branch before it, and
  a choice of next place needs its condition.
- **Worlds are printed where two actions meet** (`lib/formal_model/worlds.dart`): for
  every pair that shares a variable and that no world written in `checks.dart` gives
  both their needs (for some kind of flow each runs in), the printer makes the smallest
  world that does: its constants from the needs (an operator set where one does, with
  what it needs beside it to matter: a route split with two routes contending), a
  warm start unless a need asks a launch (`WarmInit` leaves loaded only sites one
  route and one exit can hold), at most three inputs, and only the inputs that start
  the pair's kinds of flow (`Allowed`, which a written world leaves whole unless it
  names its own, and then hosts only the pairs whose inputs it allows). One world per
  setting takes every pair that needs it, and holds every invariant. The pairs the
  printer computes from the declarations (`activation_pairs.tsv`) are the gate's: the gate
  fails where they differ from what the text shares. The environment's actions declare
  their footprints (`EnvAction`) and the base's operators theirs (`BaseOp`), each held
  to its text.
- **Unreached actions are named:** a table action no world takes is checked by nothing,
  so it is taken in some world or listed in `untaken.tsv` with why none can; an
  unlisted one is planted on every run.
- **The gate:** two actions that share a variable are both taken in one checked world,
  or the pair is listed in `footprint_debt.tsv`, which only shrinks. A new pair no
  world takes together fails, and so does a listed pair one now does; both are
  planted on every run.

- **Disjoint footprints are checked apart:** no interleaving of the two can break what
  each holds alone, so neither model grows by the other.
- **Overlapping footprints are checked together,** in one model or against a
  rely/guarantee contract as `kernel.tla`'s modules are.
- **A new flow costs its own checks plus one per flow it overlaps,** not a larger
  monolith. A model that takes every flow into one `Next` has stopped scaling and
  is split.
- **Debt:** `activation.tla` holds every activation-side flow (taps, preloads, pressure,
  tabs, nested screens, wakes, the DNS lists, webspace switches) in one `Next`, so each
  added world multiplies the base config's time.

## What a footprint licenses

`lean/` proves, once, over a generic printed action (a read set, a write set, a step that
changes nothing off its writes and whose enabledness and writes depend only on its reads),
what the composition above may assume. `lean/check.sh` builds it, fails on an open proof,
and is `verify.sh`'s LEAN step, which skips without `lake` and fails without it in CI.

- **`commute`**: if neither action writes what the other reads or writes, `a ; b` and
  `b ; a` are one relation and neither enables or disables the other, so their
  interleavings need no joint check.
- **`frame_preserves`**: an action that writes nothing an invariant reads preserves it, so
  a TLAPS case `Inv /\ A => Inv'` for such an `A` need not be written.
- **`cone`**: an invariant holds in every state the system reaches iff it holds in every
  state its cone reaches (the actions that write what it reads, closed under writing what
  an action in the cone reads), from the same `Init`. A world that takes the cone checks
  the invariant in full. The reads must include the guards' (a removed writer could be
  what enabled a kept action), and the cone is closed over every action of the system.
- **`pairwise_unsound`**: three actions where every world of two holds an invariant the
  three break, so the footprint gate's pairs are coverage, not soundness.

`lib/formal_model/main.dart` prints the activation model's footprints as
`model/lean/Footprints.lean`: every action's declared reads and writes, each world's
constants, inputs and invariants, and what each way to an action needs. There
`every_invariant_licensed` decides that every invariant is checked in some world that takes
its whole cone among the actions its constants allow, so that world's result holds for
every input; a copy whose worlds allow no input must fail it. No invariant's reads are
declared in the code, so each is taken to read every variable; and the scheduler (`Calm`,
`Idle`, `Input`, `Did`) is read and written by every action, so every cone is all of a
world's actions and only a world that allows every input licenses an invariant. A smaller
world needs a lemma over the scheduler first: that dropping the flows of a kind only makes
`Calm` and `Idle` truer and leaves the input budget and flow numbers in step.

## Verification only grows

`levels.tsv` is the floor of what `verify.sh` checks: TLC configs that hold, planted
mistakes caught, witnesses reached, traces and steps replayed, proof obligations
discharged. `verify.sh` counts each in the run and fails when one falls below its line,
and prints the new count when one rises, to be committed as the new floor. A refactor
therefore cannot quietly check less: a flow rewritten in another form prints the same
model, and a check is retired only when its replacement has caught the same mistakes.

### Remembered runs

A TLC run's verdict is a function of its inputs: the config, every module the spec reads
(the hand-written ones here and the printed ones, found over `EXTENDS` and `INSTANCE` in
every directory TLC searches), the jar, and the line the run must print. `check.sh` keys
each run by a hash of exactly these (`key`), and keeps a run that behaved under its key in
`FORMAL_CACHE` (default `~/.cache/webspace-formal`, which CI restores between runs). A run
whose key is kept is not run again: its OK line comes from the kept output, marked
`(remembered)`, the footprint gate reads its coverage from it, and it counts in `TALLY` as
the check it is. Verification still only grows: a remembered check is the very run that
would print that verdict now, since not one byte it reads differs (TLC's fingerprint
collisions aside, at the odds the kept output printed), and a changed config, module, jar
or expected line is another key, so it runs. Only runs that behaved are kept, so a failure
always runs again. `FORMAL_RERUN=1` runs every check and keeps what
behaves; a kept run nothing has asked for in a fortnight is dropped.

CI restores and saves these caches separately, saving completed work even when a
later check fails. The verification step has a five-hour timeout inside the job's
six-hour limit so cache saving has time to run. Each attempt saves a new cache;
restoring an older one does not prevent saving newly completed checks. TLAPS uses
the same policy for its version-checked fingerprints and retries failed obligations
without them. A timeout still fails verification; it does not count unfinished work.

A run of `activation.tla` is keyed by what its world can reach instead
([world_key.py](world_key.py)): the hand-written modules whole, and of each printed
module its text outside the definitions and every definition reached from the config and
from that text, except the actions the world cannot take. An action needs what its guard
needs of the constants (`activation_footprints.tsv`, which the printer computes from the
guard it prints, as the footprint gate holds), so where the world's constants
(`activation_worlds.tsv`) do not give it, it is false in every state and a formula over
it reads the same whatever its text. A change to a table step only some worlds take reruns
those worlds: one to the wake's `Background` reruns the 15 that can wake, and the 24
mutant runs, whose tables print no needs and so cut nothing: 39 of the 111, the base
config not among them. A step every world takes (`Tap`) still reruns all. The text no
world reaches still parses in every full verify: the proofs extend the whole model. The script
checks itself on every run (a change to one such action must move the keys of exactly the
runs that load it and can take it), and two planted mistakes in the key, one cutting that
action everywhere and one keeping every module whole, must each fail that check.

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

The log bridge reads two fixed files and takes `jar` to equal `cur` rather than observing
it, so it says nothing about the code as it runs today. The step replay (`trace/check_steps.sh`,
above) does.

The replay checks the steps the code marks; what the code changes between them is held by
the walks' frame check (`test/helpers/walk/flows.dart`). Every stretch of a script's code
that runs without an await is a segment, opened by a zone handler both runners install, so
a listener another flow's future runs inline is its own segment. What the model's variables
(as the page and the fakes hold them) changed across a segment is charged to the step its
flow marks next, or to the last one it marked there, and must be among that step's declared
writes; the environment's actions and the rendered frames are exempt. A planted table that
leaves a write out (`FrameMistake` in `lib/formal_model/models.dart`) fails a schedule.

## Honest limits

- Verifies the **design composition**, and (via traces) **executed code** — never a
  whole-system code proof. No deductive verifier exists for Dart.
- The kernel is only the **coupled cluster**. Most specs are leaves and are better served by
  static cross-spec invariants (registry completeness, nested-webview field flow, keyspace
  disjointness) — relational checks with no temporal cost.
- Bounded domains (`N = 3` sites): TLC is exhaustive only within the bound. For properties
  that need to hold for *all* N, `proofs/` carries unbounded TLAPS proofs — every kernel
  safety invariant *and* the surface-repaint liveness `RepaintLiveness` are machine-checked
  for all N.
- The realistic deliverable: **design-level interference becomes a CI check** instead of a
  production incident discovered after N partial fixes.

## Bug ↔ spec ↔ model traceability

| Bug | Spec | Model property |
|-----|------|----------------|
| [BUG-001 white screen](../docs/bugs/001-white-screen.md) | `webview-pause-lifecycle` PAUSE-015..018 | `kernel.tla` `RepaintLiveness` |
| [BUG-002 black screen](../docs/bugs/002-black-screen.md) | `webview-pause-lifecycle` PAUSE-013/014 | `renderer.tla` `Recovered` |
| (visible site unloaded) | `lazy-webview-loading` | `kernel.tla` `Inv_CurrentLoaded` |
| (cross-site cookie leak) | `per-site-cookie-isolation` | `kernel.tla` `Inv_JarMatchesVisible` |
