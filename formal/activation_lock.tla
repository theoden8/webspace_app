-------------------------- MODULE activation_lock --------------------------
(* A lock whose turn a flow waits on: a platform object whose operations *)
(* a SerialQueue serialises, one flow holding it at a time. Each lock of   *)
(* the Lock enum (lib/services/step_table.dart) is an instance over its    *)
(* own holder and queue, printed into activation_ops; a step the turn      *)
(* grants waits on Granted, and the queue hands the turn on in a          *)
(* microtask, unordered with the continuation of the flow that passed it  *)
(* and with whatever else is due. Hand-written.                            *)

EXTENDS Sequences

CONSTANTS
    Mistake,  \* activation_base's: "noturns" serialises nothing, "keepturn"
              \* never lets the turn go
    Witness   \* what a flow queued behind a holder adds to seen

VARIABLES
    holder,   \* the flow holding the turn, 0 for none
    queue,    \* the flows waiting for it, in order
    seen      \* activation_base's reachability witnesses (ghost)

\* The turn is f's: nobody holds it and f is first in the queue.
Granted(f) ==
    \/ Mistake = "noturns"
    \/ holder = 0 /\ queue # << >> /\ Head(queue) = f

Enqueue(f) ==
    IF Mistake = "noturns"
    THEN UNCHANGED << queue, seen >>
    ELSE /\ queue' = Append(queue, f)
         /\ seen' = seen \cup (IF holder # 0 THEN {Witness} ELSE {})

\* The granted flow holds the turn, or passes it on at once.
TakeTurn(f) ==
    IF Mistake = "noturns" THEN UNCHANGED << holder, queue >>
    ELSE /\ holder' = f
         /\ queue' = Tail(queue)
PassTurn ==
    IF Mistake = "noturns" THEN UNCHANGED << holder, queue >>
    ELSE /\ holder' = 0
         /\ queue' = Tail(queue)

Release == IF Mistake \in {"noturns", "keepturn"} THEN UNCHANGED holder ELSE holder' = 0

=============================================================================
