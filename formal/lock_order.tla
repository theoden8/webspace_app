----------------------------- MODULE lock_order -----------------------------
(***************************************************************************)
(* Bounded bypass of a lock's turn: the one definition of a turn the       *)
(* activation model has (activation_lock.tla), of which the shared jar     *)
(* (ISO-003) and the DNS lists (DNS-019) are instances.                    *)
(*                                                                         *)
(* A flow that asks for the turn is served within as many grants as there *)
(* were flows ahead of it when it asked: each grant to another flow while  *)
(* it waits spends one of that budget, and none is ever spent past zero.   *)
(* An invariant, not liveness: it bounds how often a waiter is passed      *)
(* over, not that a holder ever lets go (the keepturn mistake, a           *)
(* deadlock, is activation.tla's).                                         *)
(*                                                                         *)
(*   Inv_Bounded   no waiter is passed over more often than the flows      *)
(*                 ahead of it when it asked                               *)
(*                                                                         *)
(* Mistakes that MUST be caught:                                           *)
(*   outoforder   the turn goes to any flow waiting, not the first         *)
(*                                                                         *)
(* Standalone: the turn's operators read and write only its holder and     *)
(* queue (activation_base_ops.tsv, held by footprint.py), so what holds of *)
(* them here holds of every instance in activation.tla, at no cost to its  *)
(* states or its proofs.                                                   *)
(***************************************************************************)
EXTENDS Naturals, Integers, Sequences, FiniteSets

CONSTANTS
    Flows,    \* the flows that may ask for the turn, numbered from 1
    MaxAsks,  \* asks in a behaviour, to bound it
    Mistake   \* "none" | "outoforder"

VARIABLES
    holder,   \* the flow holding the turn, 0 for none
    queue,    \* the flows waiting for it, in order
    seen,     \* activation_lock's witness ghost
    budget,   \* per flow: the grants to others it may still wait through
    ahead,    \* per flow: the flows ahead of it when it last asked (ghost)
    asks,     \* asks so far
    behind    \* the most flows ahead of one that was served (ghost)

vars == << holder, queue, seen, budget, ahead, asks, behind >>

Lock == INSTANCE activation_lock WITH Mistake <- "none", Witness <- "queued"

Waiting(q) == {q[i] : i \in 1..Len(q)}

Without(q, f) == SelectSeq(q, LAMBDA g : g # f)

\* The turn is f's: the lock's own rule, or under the mistake any waiter's.
Granted(f) ==
    IF Mistake = "outoforder"
    THEN holder = 0 /\ f \in Waiting(queue)
    ELSE Lock!Granted(f)

\* f is served: every other waiter spends one grant of its budget.
Served(f) ==
    /\ budget' = [g \in Flows |->
                    IF g # f /\ g \in Waiting(queue) THEN budget[g] - 1
                    ELSE budget[g]]
    /\ behind' = IF ahead[f] > behind THEN ahead[f] ELSE behind

Init ==
    /\ holder = 0
    /\ queue = << >>
    /\ seen = {}
    /\ budget = [f \in Flows |-> 0]
    /\ ahead = [f \in Flows |-> 0]
    /\ asks = 0
    /\ behind = 0

Ask(f) ==
    /\ asks < MaxAsks
    /\ f # holder
    /\ f \notin Waiting(queue)
    /\ Lock!Enqueue(f)
    /\ budget' = [budget EXCEPT ![f] = Len(queue)]
    /\ ahead' = [ahead EXCEPT ![f] = Len(queue)]
    /\ asks' = asks + 1
    /\ UNCHANGED << holder, behind >>

\* The granted flow holds the turn, or passes it on at once.
Take(f) ==
    /\ Granted(f)
    /\ IF Mistake = "outoforder"
       THEN holder' = f /\ queue' = Without(queue, f)
       ELSE Lock!TakeTurn(f)
    /\ Served(f)
    /\ UNCHANGED << seen, ahead, asks >>

Pass(f) ==
    /\ Granted(f)
    /\ IF Mistake = "outoforder"
       THEN holder' = 0 /\ queue' = Without(queue, f)
       ELSE Lock!PassTurn
    /\ Served(f)
    /\ UNCHANGED << seen, ahead, asks >>

Release ==
    /\ holder # 0
    /\ Lock!Release
    /\ UNCHANGED << queue, seen, budget, ahead, asks, behind >>

Finished ==
    /\ asks = MaxAsks
    /\ holder = 0
    /\ queue = << >>
    /\ UNCHANGED vars

Next ==
    \/ \E f \in Flows : Ask(f) \/ Take(f) \/ Pass(f)
    \/ Release
    \/ Finished

Spec == Init /\ [][Next]_vars

Inv_Bounded == \A f \in Waiting(queue) : budget[f] >= 0

\* Witness (expect violated): a flow is served from behind two others.
Reach_BehindTwo == behind < 2

=============================================================================
