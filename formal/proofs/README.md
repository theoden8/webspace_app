# TLAPS proofs (unbounded N)

TLC (`../check.sh`) model-checks the kernel and the standalone models at a **bounded**
domain (`N = 3` sites). These TLAPS proofs are the **unbounded backstop**: deductive,
machine-checked proofs that the invariants hold for **all N**. Each proof EXTENDS the
TLC model it backs (same definitions — no re-modeling).

- **`current_loaded.tla`** — proves `Spec_Good => []Inv_CurrentLoaded` (the visible site
  is always loaded) for the conflict-free kernel and every `N >= 1`, by the standard
  inductive-invariant argument (`IndInv == TypeOK /\ Inv_CurrentLoaded`; base case +
  case-split over all nine `GoodNext` actions). **51 obligations, all proved.**
- **`jar_matches.tla`** — proves `Spec_Good => []Inv_JarMatchesVisible` (the shared cookie
  jar always holds the visible site's cookies — no cross-site leak) for all `N >= 1`.
  **51 obligations, all proved.**
- **`archive_identity.tla`** — proves `[]ByteIdentity` for the no-leak archive system at
  **unbounded** `MaxSteps`/`MaxArch` (TLC checks 3/2): ARCH-001 byte-identity holds for any
  number of writes and archives. **25 obligations, all proved.**

- **`repaint_liveness.tla`** — BUG-001's liveness property in full, for all `N`. Proves the
  safety backbone (`NoFreeze`: the chokepoint is never wedged; `BlankOwed`: `surface="blank"
  ⟺ owed`) and then `THEOREM Liveness`: `surface="blank" ~> surface="painted"` via the WF1
  rule (the three WF1 obligations + `ExpandENABLED`, closed by `PTL` after unfolding
  `WF_vars(Nudge)`). **71 obligations, all proved.**

- **`containers_disjoint.tla`** — proves `[]Inv_Disjoint` for the per-site-containers engine
  and all `N`: the site → container binding is injective, so no two of *any* number of sites
  share storage (inductive via `Inv_Identity`). Also `[]Inv_PostureMatchesContainer`
  (LIR-018): a slot running a hosted tab binds the container of the site whose posture and
  cookie mirror it applies (inductive via `Inv_SlotRunsAsCreated`). **39 obligations, all
  proved.**
- **`proxy_coherent.tla`** — proves `[]Inv_EgressMatchesConfig` for all `N` and any proxy
  assignment: every loaded site egresses through the proxy IT was configured with. That is
  the user-facing property, and it holds under both Android designs. `[]Inv_ProxyCoherent`
  (every loaded site shares the *active* proxy) is only PROXY-008 serialisation's mechanism
  and is false under the PROXY-013 router, so it is proved under `Router = "off"`. One
  inductive invariant covers both: off-mode needs coherence as a conjunct to carry
  `Inv_EgressMatchesConfig` (there every site's egress is the visible site's proxy), on-mode
  carries it directly. Both read a slot's running identity, so the hosted-tab rebinds of
  LIR-024 are covered. **45 obligations, all proved.** Backs `proxy.tla`.
- **`retention_safety.tla`** — proves `[](Inv_CurrentKept /\ Inv_NotifLast)` for all `N` and
  any tier assignment: the visible site is never evicted, and notification sites are evicted
  last (inductive via the eviction guard + monotonicity). **22 obligations, all proved.**
- **`no_lost_update.tla`** — proves `[]Inv_NoLostUpdate` (every completed read-modify-write's
  key stays persisted — the secure-storage write serialisation) for all `N`: directly
  inductive, since the serialised (atomic) RMW makes the store grow monotonically, so a done
  op's key is never dropped. Backs `store_serial.tla`. **23 obligations, all proved.**
- **`switch_guarded.tla`** — proves `[]Inv_NoWrongActivation` (a version-guarded site switch
  never commits against a stale index) for the good orchestration: directly inductive, since
  every good action leaves `wrong` unchanged while the `noguard` demonstrator latches it.
  Backs `switchguard.tla` (which has no size parameter, so this is the deductive companion
  rather than an N-generalisation). **34 obligations, all proved.**
- **`jar_repopulated.tla`** — proves `[]Inv_JarRepopulated` (the legacy shared cookie jar is
  never left empty when the engine returns to rest): directly inductive, since only the good
  restore reaches the rest state and it repopulates the jar. Backs `jar_nonempty.tla`.
  **28 obligations, all proved.**
- **`proxy_failclosed_safe.tla`** — proves `[]Inv_NoDirectWhenProxied` (a proxied site never
  egresses directly): directly inductive, since a config change clears egress and a good load
  never sets `direct` while the type is proxied. Backs `proxy_failclosed.tla`.
  **28 obligations, all proved.**
- **`activation_turns.tla`** — proves `[]Inv_Places` (a flow at one of the jar's places holds
  the jar's turn, so no two are there at once: ISO-003) for any number of inputs. It is over
  the jar's actions and the invariant printed from `CookieIsolationEngine`'s step tables (each
  step's `holds`, which the code asserts as a flow moves in), so it needs the modules
  `../verify.sh` prints (`FORMAL_MODEL`): a table that lets a flow into a jar place without
  the turn fails it. Inductive with two helpers: the flow records keep their fields, and a flow
  no input has started is idle. It covers the launch too: the cold start's preloads and the jar
  clear queued for the first turn. Every flow step (the activation's own, the unload loop's and
  the jar's turns) is one case, `TableStep`, proved by the printed `activation_tables_proof` (a
  case per table step, by that step's lemma), which `check_proofs.sh` checks on its own, since
  tlapm takes an extended module's lemma as given. Each step's lemma unfolds its action once and
  closes it an arm at a time, eight steps a module (`activation_tables_<n>_proof`), so the
  modules prove side by side. A case reads `NoFlow` only through `NoFlowPc`, its place
  field, proved once in the printed `activation_tables_facts_proof`: a case that unfolds the
  record spends minutes in tlapm's preparation for SMT. An arm that can spawn another input proves the row's fields,
  freshness and place requirements separately, for its own row, the next input's row and
  every untouched row. Possible next places come from the table's footprints and are
  proved from its action before checking the place requirements. This keeps nested
  record updates from exhausting the proof backends;
  the invariant and the actions being proved are unchanged. The hand-written cases are
  the inputs and the pressure plan.
  The step modules are pinned by their sum (`TABLE_PARTS` in `check_proofs.sh`), not one by
  one: a step added before others moves them to the next module.
  **49 obligations, all proved; `activation_tables_proof` as pinned in `check_proofs.sh`.**
- **`activation_invariants_proof`** (printed, no hand-written module) — proves `[]Inv` for each
  invariant of `activation.tla` every step keeps as it stands (`Inv.inductive` in
  `test/formal_model/checks.dart`), beside `IndInv`, whose preservation is `activation_turns`'s
  `StepInd`: a lemma per kind of step with a case per printed step, each closed by its
  definition, then `Next`'s cases, the environment's (`EnvAction`) by their definitions. An
  invariant is declared inductive only once its cases close; one that needs a strengthening is
  not yet. Today `Inv_ChecksOffScreen`.
  **All proved, as pinned in `check_proofs.sh`.**
- **`activation_types_proof` and its tables' modules** (printed from `FlowField` and the step
  tables, no hand-written module) — every step keeps `fl` a function of flow records, the flow
  rows' part of `TypeOK`. `activation_types_proof` holds the lemmas the rest stand on: a
  function of flow records updated in one field of one row, with a value in that field's range,
  is still one (`Fl_<field>`); a field read from one is in its range (`Rd_<field>`); `NoFlow` is
  a flow record; each place and each kind is a member of its set (`Places_<place>`,
  `FlowKinds_<kind>`); what a world may set each constant to (`ConstantsType`), since a
  proof opens no default a world can replace; and each fact a row lemma reads of `TypeOK` or
  of a row's fields (`TypeFl`, `Type_<variable>`, `Dom_<field>`), which the row lemmas cite
  instead of unfolding `TypeOK` or the row's fields. It proves `Pick`, `TypeFl`, `NoFlowType`
  and `Fl_row` and states the rest omitted, each family proved in a module of its own
  (`activation_facts_<family>_proof`: `vars`, `domains`, `members`, `fields`) over
  `activation_ops`, which defines every name they read. Each obligation carries all its module
  extends: over the whole model the families took 8.7 GB cold, more with every field, and the
  members family alone 4.4 GB, where over `activation_ops` it takes 336 MB. Then one module per
  table, or per six of its
  rows (`activation_types_<table>[<n>]_proof`), proves each row of `fl` an arm writes, a clause
  at a time over a named partial row, each value over only what it reads; and
  `activation_types_steps_proof` takes them to `TableStep` and `InputTableStep`. The
  provers do not take the flow record's set of fields whole, SMT takes no
  string or record literal here, and tlapm holds every obligation it proves afresh until the
  module ends (twelve held rows took 6.4 GB cold, four such modules side by side more than a
  16 GB runner holds), so each is split as it is. What some steps need of their flow beyond `TypeOK` (a site that indexes a
  site's history, a tab where one is read, a fresh tab id when the last tab closes) is
  `Supports`; it stands on `Held` (each place a field is read at, and every place an arm
  reaches it from, holds the field set: `Held_site`, `Held_tab`, `Held_kind`) and
  `Alone` (at most one tab flow, the tab gate). The `held` and `supports` families prove every
  row keeps them, module for module beside the types family, the held family a module per field
  (`activation_held_<field>_<table>[<n>]_proof`, `activation_supports_<table>[<n>]_proof`). Each
  family's steps module restates the steps' lemmas it cites, `PROOF OMITTED`, over
  `activation_types_proof` alone: extending the tables' modules put every row's lemma in each
  obligation's context, which cost tlapm about 12 s an obligation, the trivial ones too (the
  held family's steps module, 3,042 s; restated, 507 s). tlapm takes an extended module's
  lemmas as given too, so the restatement is no weaker as long as each is the lemma proved:
  [omitted.py](omitted.py), which `check_proofs.sh` runs first, fails on an omitted lemma that
  no module of the run proves in the same words (`test/js/formal_omitted.test.js`).
  `ConstantsType` is still assumed; TLC does not yet check it in each world.
  **All proved. `check_proofs.sh` pins `activation_types_proof`, its facts' modules and the
  three steps modules by name; the tables' modules are as many as their rows need, and
  `formal/levels.tsv` holds their sum with every other module's.**

Together these prove every kernel *safety* invariant, the surface-repaint *liveness*
(`RepaintLiveness` — BUG-001 itself), and every standalone model's safety invariant
(archive byte-identity, container disjointness, proxy coherence, retention order,
secure-storage no-lost-update, site-switch version guard) for unbounded domains — not just at
TLC's `N = 3`. The only TLC-bounded model left is `renderer.tla`, which has no size parameter
(its state space is finite and fully enumerated), so an unbounded proof would be vacuous.

## Check

```bash
../verify.sh                 # prints the modules, then runs tlapm over every *.tla here
FORMAL_MODEL=<dir> ./check_proofs.sh   # with modules printed already
```

Requires **tlapm** (the TLA+ Proof Manager), installed from the prebuilt tarball:

```bash
curl -fsSL -o /tmp/tlapm.tar.gz \
  https://github.com/tlaplus/tlapm/releases/download/1.6.0-pre/tlapm-1.6.0-pre-x86_64-linux-gnu.tar.gz
tar -xzf /tmp/tlapm.tar.gz -C "$HOME"     # -> $HOME/tlapm/bin/tlapm
export PATH="$HOME/tlapm/bin:$PATH"
```

Use the tarball, **not** the 1.5.0 `-inst.bin` installer: that installer compiles
Isabelle/Pure with its bundled Poly/ML 5.4.0, which aborts on current Linux
(`scanaddrs.cpp:107: Assertion 'val.IsDataPtr()' failed`,
[tlaplus/tlapm#88](https://github.com/tlaplus/tlapm/issues/88)). The tarball ships
prebuilt Isabelle heaps, so nothing is compiled on install. `1.6.0-pre` is a rolling tag
reattached on every upstream `main` commit; it is the only prebuilt release upstream
publishes, and it is what `tlaplus/Examples`' own CI installs. On macOS swap in
`tlapm-1.6.0-pre-arm64-darwin.tar.gz`.

The obligation count listed per module above is **asserted** by `check_proofs.sh`, not just
documentation: matching "all obligations proved" alone is not a gate, because
`All 0 obligations proved.` matches it too, so a tlapm that silently checks nothing would
read as green. If you add or remove proof steps, update the count here *and* in
`min_obligations()`.

`check_proofs.sh` skips (exit 0) when `tlapm` is not on `PATH`, so a workstation without
it still runs the rest of the suite. CI installs it in the `validate` job, where the
proofs are a hard gate alongside the TLC suite. Backend timeouts are wall-clock, so the
script passes `--stretch 30`; override with `TLAPM_STRETCH`. This also gives SMT
input preparation 150 seconds. In a cold `Plan_Ind` check with two preparations
sharing one CPU, the old 50-second limit expired before the solver ran. With
the larger limit, the same obligations proved after 90 seconds, with only
0.2 seconds in Z3. The allowance avoids slow fallback methods and whole-module
retries; the proof statements and obligation counts are unchanged.

Most of a cold run is tlapm preparing obligations for SMT, which it tries first; the
solvers take almost none of it. So the printed proofs unfold a large definition (`NoFlow`,
`TypeOK`, `FlowRecord`) only in the lemma that states what is read of it, cite that lemma
everywhere else, and give a step that only cites facts to Zenon. `ZenonFirst` gives Zenon a
moment before SMT on the lemmas that join an action's rows, where SMT can spend its whole
timeout on a long action. Zenon does no arithmetic, so a step over an integer range stays
with SMT.

tlapm fingerprints every obligation it settles, here under `.tlacache/` (`TLAPM_CACHE_DIR`
moves it) and in CI between runs, so a run proves only what no earlier run proved. A
remembered failure is replayed as a proof is, without a retry, so a module that fails is
proved again ignoring the cache before it counts as failed.

A fingerprint is looked up only once its obligation is prepared, which is most of a run, so
a module whose inputs match a run that proved it is not handed to tlapm at all: its output
is kept under `memo/` beside the fingerprints and read back, marked `(remembered)`
(formal/README.md, "Remembered runs").

The modules share nothing, and tlapm prepares each obligation on one thread, which is
most of a run, so `TLAPM_JOBS` of them (default one a core) prove side by side,
the printed tables' proofs first as the longest; the report keeps the list's order.
tlapm holds every obligation it proves afresh until the module ends, so the modules beside
one can take the memory it needs, and the kernel kills it. A module that falls short is
proved again once the rest have ended, one at a time, so a module counts as failed only
where it fails alone.

## Why both TLC and TLAPS

TLC is automatic but bounded; TLAPS is unbounded but needs hand-written proofs. They are
complementary: model-check first to find counterexamples cheaply and to get the invariant
right, then prove the settled invariant for all N. TLAPS reuses `../kernel.tla` directly —
no re-modeling — which is why it (not Lean) is the natural next rung when bounded checking
isn't enough.
