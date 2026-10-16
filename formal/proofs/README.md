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
  case per table step, by its action and the operators its acts call), which `check_proofs.sh`
  checks on its own, since tlapm takes an extended module's lemma as given; the hand-written
  cases are the inputs and the pressure plan.
  **54 obligations, all proved; `activation_tables_proof` 85.**
- **`activation_invariants_proof`** (printed, no hand-written module) — proves `[]Inv` for each
  invariant of `activation.tla` every step keeps as it stands (`Inv.inductive` in
  `lib/formal_model/checks.dart`), beside `IndInv`, whose preservation is `activation_turns`'s
  `StepInd`: a lemma per kind of step with a case per printed step, each closed by its
  definition, then `Next`'s cases, the environment's (`EnvAction`) by their definitions. An
  invariant is declared inductive only once its cases close; one that needs a strengthening is
  not yet. Today `Inv_ChecksOffScreen`.
  **287 obligations, all proved.**
- **`activation_types_proof` and its tables' modules** (printed from `FlowField` and the step
  tables, no hand-written module) — every step keeps `fl` a function of flow records, the flow
  rows' part of `TypeOK`. `activation_types_proof` holds the lemmas the rest stand on: a
  function of flow records updated in one field of one row, with a value in that field's range,
  is still one (`Fl_<field>`); a field read from one is in its range (`Rd_<field>`); `NoFlow` is
  a flow record; each place and each kind is a member of its set (`Places_<place>`,
  `FlowKinds_<kind>`); and what a world may set each constant to (`ConstantsType`), since a
  proof opens no default a world can replace. Then one module per table, or per twelve of its
  rows (`activation_types_<table>[<n>]_proof`), proves each row of `fl` an arm writes, a clause
  at a time over a named partial row, each value over only what it reads; and
  `activation_types_steps_proof` takes them to `TableStep` and `InputTableStep`.
  The provers do not take the flow record's set of 28 fields whole, SMT takes no string or
  record literal here, and tlapm holds a module's obligations until it ends, so each is split
  as it is. What some steps need of their flow beyond `TypeOK` (a site that indexes a site's
  history, a fresh tab id when the last tab closes) is `Supports`, assumed and owed: a proof
  that every step keeps it is the next step. `ConstantsType` is assumed too; TLC does not yet
  check it in each world.
  **`activation_types_proof` 312 obligations, the tables' 19 modules 3,849,
  `activation_types_steps_proof` 85; all proved.**

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
script passes `--stretch 5` to survive a loaded runner; override with `TLAPM_STRETCH`.

tlapm fingerprints every obligation it settles, here under `.tlacache/` (`TLAPM_CACHE_DIR`
moves it) and in CI between runs, so a run proves only what no earlier run proved. A
remembered failure is replayed as a proof is, without a retry, so a module that fails is
proved again ignoring the cache before it counts as failed.

The modules share nothing and tlapm gains little from threads within one, so
`TLAPM_JOBS` of them (default 2) prove side by side, each with its share of the cores,
the printed tables' proofs first as the longest; the report keeps the list's order.

## Why both TLC and TLAPS

TLC is automatic but bounded; TLAPS is unbounded but needs hand-written proofs. They are
complementary: model-check first to find counterexamples cheaply and to get the invariant
right, then prove the settled invariant for all N. TLAPS reuses `../kernel.tla` directly —
no re-modeling — which is why it (not Lean) is the natural next rung when bounded checking
isn't enough.
