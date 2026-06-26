# TLAPS proofs (unbounded N)

TLC (`../check.sh`) model-checks the kernel at a **bounded** domain (`N = 3` sites).
These TLAPS proofs are the **unbounded backstop**: deductive, machine-checked proofs
that a kernel invariant holds for **all N**.

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

- **`repaint_liveness.tla`** — the safety backbone of BUG-001's liveness property, for all
  `N`: `NoFreeze` (the repaint chokepoint is never wedged in the conflict-free system) and
  `BlankOwed` (`surface="blank" ⟺ owed`), and the corollary `BlankEnablesNudge` (a blank
  surface always enables the Nudge action). **54 obligations, all proved.**

Together these prove every kernel *safety* invariant for unbounded domains, and reduce the
liveness property `RepaintLiveness` (`surface="blank" ~> surface="painted"`) to a single WF1
application on top of `BlankEnablesNudge` + `WF_vars(Nudge)`. That last temporal step needs
`ENABLED`-expansion reasoning beyond TLAPS's propositional (PTL) backend, so it stays
TLC-checked at `N = 3` and documented as the remainder — the safety backbone it rests on is
proved unbounded.

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
