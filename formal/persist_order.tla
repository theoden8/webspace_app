------------------------- MODULE persist_order -------------------------
(***************************************************************************)
(* The page's saves of its own state (WEBSPACE-005): the webspaces, the    *)
(* selection, the theme, the site list. Each edit fires a save and does   *)
(* not wait for it (`unawaited(_shell.saveWebspaces())`), so saves overlap *)
(* and nothing orders them. They stay correct because each one awaits     *)
(* first (`SharedPreferences.getInstance()`, a store's lock) and only then *)
(* reads the live state and hands it to the write in the same turn: the    *)
(* save that writes last read last, so once none is in flight what is      *)
(* stored is what the page holds.                                          *)
(*                                                                         *)
(*   Inv_StoredLatest == no save in flight => stored = state               *)
(*                                                                         *)
(* The "snapshot" demonstrator reads before the await, as a save that      *)
(* builds its JSON first would: an older save that lands after a newer one *)
(* writes the older state back, and the restart restores it.               *)
(*                                                                         *)
(* `test/js/persist_order.test.js` holds the stores to the "live" save:    *)
(* in each save, no await between the read of what it writes and the       *)
(* write. Standalone (no shared kernel state), like store_serial.tla.      *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Saves,   \* the saves the edits fire, one per edit
    Mode     \* "live": read after the await; "snapshot": read before it

ASSUME Mode \in {"live", "snapshot"}

VARIABLES
    state,   \* the page's version of what it saves: one more per edit
    stored,  \* the version the store holds
    pc,      \* each save: "idle" (not fired), "await", or "done"
    snap     \* what a "snapshot" save read before its await

vars == << state, stored, pc, snap >>

TypeOK ==
    /\ state \in 0..Cardinality(Saves)
    /\ stored \in 0..Cardinality(Saves)
    /\ pc \in [Saves -> {"idle", "await", "done"}]
    /\ snap \in [Saves -> 0..Cardinality(Saves)]

Init ==
    /\ state = 0
    /\ stored = 0
    /\ pc = [s \in Saves |-> "idle"]
    /\ snap = [s \in Saves |-> 0]

\* An edit changes the page's state and fires its save, which is not
\* awaited. A "snapshot" save reads here, before its await.
Edit(s) ==
    /\ pc[s] = "idle"
    /\ state' = state + 1
    /\ pc' = [pc EXCEPT ![s] = "await"]
    /\ snap' = [snap EXCEPT ![s] = state + 1]
    /\ UNCHANGED stored

\* The save's await returns: it reads what it writes and writes it in one
\* turn, the live state or, in the demonstrator, what it read before.
Write(s) ==
    /\ pc[s] = "await"
    /\ stored' = IF Mode = "live" THEN state ELSE snap[s]
    /\ pc' = [pc EXCEPT ![s] = "done"]
    /\ UNCHANGED << state, snap >>

Done == \A s \in Saves : pc[s] = "done"

Next ==
    \/ \E s \in Saves : Edit(s) \/ Write(s)
    \/ (Done /\ UNCHANGED vars)

Spec == Init /\ [][Next]_vars

\* SAFETY (WEBSPACE-005): with no save in flight, the store holds what the
\* page holds, so a restart restores the newest edit. Broken by "snapshot".
Inv_StoredLatest == (\A s \in Saves : pc[s] # "await") => stored = state

\* Anti-vacuity witness (expect violated): two saves are in flight at once,
\* so the invariant is checked against saves that overlap.
Reach_Overlap == ~(Cardinality({s \in Saves : pc[s] = "await"}) >= 2)
=============================================================================
