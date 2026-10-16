--------------------------- MODULE process_route ---------------------------
(***************************************************************************)
(* The process-wide proxy rule's own timing (PROXY-008, BUG-037), as       *)
(* lib/services/process_route.dart runs it where one rule covers every     *)
(* webview (Android outside router mode, Linux).                           *)
(*                                                                         *)
(* A claim takes a ticket as it is made and waits for the rule's turn (a  *)
(* FIFO SerialQueue). At its turn, a claim whose ticket a release voided   *)
(* does nothing; one still current takes its occupant off, writes the     *)
(* rule, and lists the occupant again once the write returns, if its       *)
(* ticket is still current. A release (a webview disposed, a screen        *)
(* popped, a check closed) can land at any moment and voids the ticket.    *)
(*                                                                         *)
(* The callers' contract, which activation.tla's Inv_OneRoute holds them   *)
(* to: an occupant claims only when every live occupant needs its route.   *)
(* A page sends traffic once its own claim has returned, until it is       *)
(* released.                                                               *)
(*                                                                         *)
(*   Inv_Covers    every page sending traffic has the rule on its route    *)
(*   Inv_NoGhost   the rule lists only live occupants                      *)
(*   Inv_Assert    the code's assert never fails: whoever holds the turn   *)
(*                 shares the route of everything the rule lists           *)
(*                                                                         *)
(* Mistakes that MUST be caught:                                           *)
(*   readd     no ticket: a claim always writes and lists its occupant,    *)
(*             the code before BUG-037 attempt 11                          *)
(*   midwrite  a turn renews its claim's ticket, so only a release during  *)
(*             the write voids it: attempt 11's first fix, which TLC       *)
(*             caught here with a release while the claim waited           *)
(*   noturn    writes do not wait for each other's turn                    *)
(*                                                                         *)
(* Standalone (no shared kernel state), like proxy.tla. Its callers'       *)
(* timing, which sites run when, is activation.tla's; this module is the   *)
(* primitive under them.                                                   *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Occupants,  \* what runs on the rule: webviews, nested screens, checks
    RouteOf,    \* the route each needs (a function Occupants -> routes)
    MaxClaims,  \* how many claims a behaviour makes, to bound it
    Mistake     \* "none" | "readd" | "midwrite" | "noturn"

None == "none"

\* The configs' routes: "c" on one proxy, the rest on another.
RouteOfDef == [o \in Occupants |-> IF o = "c" THEN "p2" ELSE "p1"]

VARIABLES
    queue,    \* claims waiting for the rule's turn, oldest first: [o, n]
    out,      \* the claims whose writes are out: one at a time, by the turn
    ticket,   \* the code's _claims: each occupant's current claim, 0 for none
    rule,     \* the route the rule is set to, None before the first write
    on,       \* the code's _on: what the rule lists as running on it
    live,     \* occupants the app runs (environment): claimed, not released
    traffic,  \* live occupants whose page sends traffic
    claims    \* claims made so far, which number them

vars == << queue, out, ticket, rule, on, live, traffic, claims >>

Routes == {RouteOf[o] : o \in Occupants}
Entries == [o : Occupants, n : 1..MaxClaims]

TypeOK ==
    /\ queue \in Seq(Entries)
    /\ out \subseteq Entries
    /\ ticket \in [Occupants -> 0..MaxClaims]
    /\ rule \in Routes \cup {None}
    /\ on \subseteq Occupants
    /\ live \subseteq Occupants
    /\ traffic \subseteq live
    /\ claims \in 0..MaxClaims

Init ==
    /\ queue = << >>
    /\ out = {}
    /\ ticket = [o \in Occupants |-> 0]
    /\ rule = None
    /\ on = {}
    /\ live = {}
    /\ traffic = {}
    /\ claims = 0

Current(e) == Mistake = "readd" \/ ticket[e.o] = e.n

\* An occupant starts running and claims the rule, which its caller allows
\* only when everything running needs its route.
Claim(o) ==
    /\ claims < MaxClaims
    /\ o \notin live
    /\ \A p \in live : RouteOf[p] = RouteOf[o]
    /\ live' = live \cup {o}
    /\ ticket' = [ticket EXCEPT ![o] = claims + 1]
    /\ queue' = Append(queue, [o |-> o, n |-> claims + 1])
    /\ claims' = claims + 1
    /\ UNCHANGED << out, rule, on, traffic >>

\* The claim at the head gets the rule's turn once no write is out. Still
\* current, its occupant comes off and its write goes out; voided, it does
\* nothing.
Turn ==
    /\ queue # << >>
    /\ out = {} \/ Mistake = "noturn"
    /\ LET e == Head(queue) IN
        IF Current(e) \/ Mistake = "midwrite"
        THEN /\ out' = out \cup {e}
             /\ on' = on \ {e.o}
             /\ ticket' = IF Mistake = "midwrite"
                          THEN [ticket EXCEPT ![e.o] = e.n] ELSE ticket
        ELSE UNCHANGED << out, on, ticket >>
    /\ queue' = Tail(queue)
    /\ UNCHANGED << rule, live, traffic, claims >>

\* A write returns: the rule names its route, and a claim still current
\* lists its occupant again, whose page starts sending.
Reply(e) ==
    /\ rule' = RouteOf[e.o]
    /\ IF Current(e)
       THEN /\ on' = on \cup {e.o}
            /\ traffic' = IF e.o \in live THEN traffic \cup {e.o} ELSE traffic
            /\ ticket' = IF ticket[e.o] = e.n
                         THEN [ticket EXCEPT ![e.o] = 0] ELSE ticket
       ELSE UNCHANGED << on, traffic, ticket >>
    /\ out' = out \ {e}
    /\ UNCHANGED << queue, live, claims >>

\* A webview disposed, a screen popped, a check closed: at any moment.
Release(o) ==
    /\ o \in live
    /\ live' = live \ {o}
    /\ traffic' = traffic \ {o}
    /\ on' = on \ {o}
    /\ ticket' = [ticket EXCEPT ![o] = 0]
    /\ UNCHANGED << queue, out, rule, claims >>

\* The bound reached and every claim through: nothing left to happen.
Done ==
    /\ claims = MaxClaims
    /\ queue = << >>
    /\ out = {}
    /\ UNCHANGED vars

Next ==
    \/ \E o \in Occupants : Claim(o) \/ Release(o)
    \/ Turn
    \/ \E e \in out : Reply(e)
    \/ Done

Spec == Init /\ [][Next]_vars

Inv_Covers == \A o \in traffic : RouteOf[o] = rule
Inv_NoGhost == on \subseteq live
Inv_Assert == \A e \in out : \A p \in on : RouteOf[p] = RouteOf[e.o]

\* Witnesses: a release during a write, a turn that finds its claim voided,
\* and an occupant claiming again while its old claim waits, are all
\* reachable (the invariants are not vacuous).
Reach_ReleasedMidWrite == ~(\E e \in out : ticket[e.o] # e.n)
Reach_VoidedTurn ==
    ~(queue # << >> /\ out = {} /\ ~Current(Head(queue))
      /\ Len(queue) = 1)
Reach_ClaimedAgain ==
    ~(\E i, j \in 1..Len(queue) : i < j /\ queue[i].o = queue[j].o)

=============================================================================
