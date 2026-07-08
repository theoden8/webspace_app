-------------------------- MODULE store_serial --------------------------
(***************************************************************************)
(* Secure-storage write serialisation (no lost update). The proxy-password  *)
(* and cookie stores keep a single at-rest entry (a `key -> value` map) and  *)
(* mutate it by read-modify-write. Several call sites -- and two separate    *)
(* store instances that share the same storage key -- issue these           *)
(* concurrently. Without serialisation a full-map write built from a stale   *)
(* read snapshot clobbers a key another op just committed (a lost update:    *)
(* a just-saved proxy password silently vanishes; an archive-tier cookie is  *)
(* re-persisted into app-tier storage).                                      *)
(*                                                                          *)
(* The fix routes every mutation through a static write lock: each          *)
(* read-modify-write runs as one atomic critical section. This model        *)
(* abstracts that as an atomic `Rmw`. The "interleave" demonstrator splits   *)
(* the read and the write (the unlocked path) and reaches a lost update.     *)
(*                                                                          *)
(*   Inv_NoLostUpdate == every completed op's key is still persisted        *)
(*                                                                          *)
(* Standalone model (a fixed N-op scenario; no shared kernel state), like   *)
(* proxy.tla and archive.tla. Each op owns a distinct key (its own id), so  *)
(* a dropped key is observable.                                             *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    N,         \* number of concurrent read-modify-write ops (TLC sets 3)
    Conflict   \* "none" | "interleave"

Ops == 1..N

\* Each op persists its own id as a key. `store` is the set of keys currently
\* committed to the shared entry; `done` the ops that have finished; `reading`
\* + `snap` are the unlocked demonstrator's read snapshots.
VARIABLES
    store,     \* SUBSET Ops -- keys currently persisted
    done,      \* SUBSET Ops -- ops that have completed their write
    reading,   \* SUBSET Ops -- ops mid-way through an unlocked RMW
    snap       \* Ops -> SUBSET Ops -- each mid-flight op's read snapshot

vars == << store, done, reading, snap >>

TypeOK ==
    /\ store \subseteq Ops
    /\ done \subseteq Ops
    /\ reading \subseteq Ops
    /\ snap \in [Ops -> SUBSET Ops]

Init ==
    /\ store = {}
    /\ done = {}
    /\ reading = {}
    /\ snap = [o \in Ops |-> {}]

\* GOOD path: the write lock makes read-modify-write one critical section.
\* Modelled as an atomic add of this op's key -- the store only ever grows,
\* so no committed key is dropped. Unguarded (a done op may idempotently
\* re-save), so the action is perpetually enabled and the good model never
\* deadlocks in a terminal all-done state (cf. proxy.tla's Activate).
Rmw(o) ==
    /\ store' = store \cup {o}
    /\ done' = done \cup {o}
    /\ UNCHANGED << reading, snap >>

\* Demonstrator (unlocked): read the current key set into a snapshot, ...
Read(o) ==
    /\ o \notin done
    /\ o \notin reading
    /\ reading' = reading \cup {o}
    /\ snap' = [snap EXCEPT ![o] = store]
    /\ UNCHANGED << store, done >>

\* ... then later write back the whole snapshot plus this op's key. A key
\* another op committed after this op's read is not in `snap[o]`, so it is
\* dropped -- the lost update.
Write(o) ==
    /\ o \in reading
    /\ store' = snap[o] \cup {o}
    /\ done' = done \cup {o}
    /\ reading' = reading \ {o}
    /\ UNCHANGED snap

GoodNext == \E o \in Ops : Rmw(o)

Next ==
    \/ GoodNext
    \/ (Conflict = "interleave" /\ \E o \in Ops : (Read(o) \/ Write(o)))

Spec == Init /\ [][Next]_vars

\* SAFETY: every op that finished still has its key persisted -- no committed
\* write was lost. Broken by "interleave".
Inv_NoLostUpdate == \A o \in Ops : o \in done => o \in store

\* Anti-vacuity witness (expect violated): two ops can both complete, so the
\* invariant is checked against real concurrent completion, not vacuously.
Reach_TwoDone == ~(Cardinality(done) >= 2)
=============================================================================
