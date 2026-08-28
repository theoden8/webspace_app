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
  share storage (inductive via `Inv_Identity`). **23 obligations, all proved.**
- **`proxy_coherent.tla`** — proves `[]Inv_EgressMatchesConfig` for all `N` and any proxy
  assignment: every loaded site egresses through the proxy IT was configured with. That is
  the user-facing property, and it holds under both Android designs. `[]Inv_ProxyCoherent`
  (every loaded site shares the *active* proxy) is only PROXY-008 serialisation's mechanism
  and is false under the PROXY-013 router, so it is proved under `Router = "off"`. One
  inductive invariant covers both: off-mode needs coherence as a conjunct to carry
  `Inv_EgressMatchesConfig` (there every site's egress is the visible site's proxy), on-mode
  carries it directly. Backs `proxy.tla`.
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

Together these prove every kernel *safety* invariant, the surface-repaint *liveness*
(`RepaintLiveness` — BUG-001 itself), and every standalone model's safety invariant
(archive byte-identity, container disjointness, proxy coherence, retention order,
secure-storage no-lost-update, site-switch version guard) for unbounded domains — not just at
TLC's `N = 3`. The only TLC-bounded model left is `renderer.tla`, which has no size parameter
(its state space is finite and fully enumerated), so an unbounded proof would be vacuous.

## Check

```bash
./check_proofs.sh            # runs tlapm over every *.tla here
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

## Why both TLC and TLAPS

TLC is automatic but bounded; TLAPS is unbounded but needs hand-written proofs. They are
complementary: model-check first to find counterexamples cheaply and to get the invariant
right, then prove the settled invariant for all N. TLAPS reuses `../kernel.tla` directly —
no re-modeling — which is why it (not Lean) is the natural next rung when bounded checking
isn't enough.
