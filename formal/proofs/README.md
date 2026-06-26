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
- **`proxy_coherent.tla`** — proves `[]Inv_ProxyCoherent` for all `N` and any proxy
  assignment: every loaded site shares the active proxy (directly inductive — serialisation
  rebuilds a homogeneous loaded set on each activation). **29 obligations, all proved.**
- **`retention_safety.tla`** — proves `[](Inv_CurrentKept /\ Inv_NotifLast)` for all `N` and
  any tier assignment: the visible site is never evicted, and notification sites are evicted
  last (inductive via the eviction guard + monotonicity). **22 obligations, all proved.**

Together these prove every kernel *safety* invariant, the surface-repaint *liveness*
(`RepaintLiveness` — BUG-001 itself), and every standalone model's safety invariant
(archive byte-identity, container disjointness, proxy coherence, retention order) for
unbounded domains — not just at TLC's `N = 3`. The only TLC-bounded model left is
`renderer.tla`, which has no size parameter (its state space is finite and fully
enumerated), so an unbounded proof would be vacuous.

## Check

```bash
./check_proofs.sh            # runs tlapm over every *.tla here
```

Requires **tlapm** (the TLA+ Proof Manager). It is heavy (~145 MB, bundles Isabelle), so
it is deliberately **not** in the default CI gate — the TLC suite is the fast gate; these
proofs are the high-assurance backstop run on demand. Install: download
`tlaps-1.5.0-x86_64-linux-gnu-inst.bin` from
[github.com/tlaplus/tlapm/releases](https://github.com/tlaplus/tlapm/releases), run it
with `-d <prefix>`, and add `<prefix>/bin` to `PATH`.

## Why both TLC and TLAPS

TLC is automatic but bounded; TLAPS is unbounded but needs hand-written proofs. They are
complementary: model-check first to find counterexamples cheaply and to get the invariant
right, then prove the settled invariant for all N. TLAPS reuses `../kernel.tla` directly —
no re-modeling — which is why it (not Lean) is the natural next rung when bounded checking
isn't enough.
