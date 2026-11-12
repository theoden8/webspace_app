---
name: inductive-invariant-check
description: Try a candidate inductive invariant with TLC before writing its TLAPS proof. Use when designing, strengthening or debugging an invariant for a formal/ model, above all before TLAPS work on an activation invariant still unproved.
metadata:
  adapted-from: TLAPS-Bench, skills/tla-inductive-invariant-validation (specula-org/TLAPS-Bench, MIT)
---

# Try an inductive invariant before proving it

A model checker can show a candidate is wrong in seconds; TLAPS takes hours to
say the same less clearly. A pass is evidence for one small world. Nothing
counts it, no TLAPS step cites it, and the proof is still owed.

## Shape the candidate

`IndInv == TypeE /\ H /\ Inv`:

- `TypeE` bounds every variable to a finite set with `\in`: `loaded \in
  SUBSET Sites`, not `loaded \subseteq Sites`. TLC builds the states that
  satisfy it and then filters them, so it must enumerate.
- `H` is the facts the induction needs.
- `Inv` is the invariant you mean to prove, so the candidate implies it.

Put `TypeE` and `IndInv` in a wrapper module that EXTENDS the target. Never
edit the target or a printed module for this.

## Run the three checks

```sh
TLA2TOOLS_JAR=build/formal/model/tla2tools.jar \
  formal/indcheck.sh Wrapper.tla --ind IndInv --inv Inv --next GoodNext \
    --constants world.cfg --search formal --search formal/proofs
```

`world.cfg` holds the world's CONSTANT lines. Start with the smallest world
that can show the bug: a few dozen initial states. The script runs:

| Check | Fails when |
|---|---|
| `init`: `Init => IndInv` | the candidate excludes a real initial state |
| `step`: `IndInv /\ Next => IndInv'` | a state the candidate admits steps out of it; the trace names the conjunct, and the missing fact is usually there |
| `safe`: `IndInv => Inv` | the candidate is too weak to give the goal |

After a `step` failure, rerun `step` alone on the repair. Run all three once
the candidate settles. Widen a bound before trusting a counterexample that
may depend on it.

`formal/indcheck.sh --plant` shows each check failing on its own planted
candidate. Apalache is not used: it would need type annotations our printed
modules do not carry.

## Then prove it, an arm at a time

- Prove one action's arm, or one table row, per step. Handing the whole
  `IndInv /\ Next => IndInv'` to a solver is the most common way TLAPS work
  fails.
- State the invariant at the places a flow can be (`holds`) before adding a
  lemma per row: one compact statement does more than many small ones.
- `formal/proofs/integrity.py` fails any new ASSUME or AXIOM, any statement
  left unproved, any bare step and any lemma taken from a module the run does
  not prove. A candidate that holds only under an extra assumption is not
  proved.

The method is Lamport's "Using TLC to Check Inductive Invariance".
