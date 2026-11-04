---------------------------- MODULE relay_routes ----------------------------
(***************************************************************************)
(* The router relay's route tables and the challenges they answer          *)
(* (PROXY-034), as lib/services/proxy_router_service.dart runs them.       *)
(*                                                                         *)
(* A proxy change asks for a table: which sites the relay routes. Tables   *)
(* install through one FIFO queue (a SerialQueue), each one a call out to  *)
(* the relay that returns some time later. A webview's credential the      *)
(* relay challenges takes its place in the same queue, so it is answered   *)
(* once every table asked before it has landed: yes when the relay routes  *)
(* the site, no otherwise.                                                 *)
(*                                                                         *)
(*   Inv_Latest     once nothing is queued or out, the relay holds the     *)
(*                  last table asked for                                   *)
(*   Inv_Refused    a challenge is refused only for a site the last table  *)
(*                  asked before it does not route                         *)
(*                                                                         *)
(* Mistakes that MUST be caught:                                           *)
(*   unordered  installs do not wait for each other, so an older table     *)
(*              can land after a newer one                                 *)
(*   nowait     a challenge is answered from the table the relay holds     *)
(*              as it arrives: the code before PROXY-034, which refused a  *)
(*              site whose route was a moment away (a device log,          *)
(*              "rejecting connection bearing an unknown proxy             *)
(*              credential")                                               *)
(*                                                                         *)
(* Standalone, like process_route.tla: who asks for which table, and when, *)
(* is the app's; this module is the primitive under it.                    *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Sites,          \* the sites whose credentials the relay may route
    MaxAsks,        \* tables asked for in a behaviour, to bound it
    MaxChallenges,  \* challenges in a behaviour, to bound it
    Mistake         \* "none" | "unordered" | "nowait"

Tables == SUBSET Sites
Installs == [kind : {"install"}, table : Tables]
Waits == [kind : {"challenge"}, site : Sites, latest : Tables, routed : BOOLEAN]

VARIABLES
    queue,       \* the SerialQueue: installs and challenges, oldest first
    out,         \* installs whose call to the relay has not returned
    held,        \* the table the relay routes (the code's _routed)
    latest,      \* the last table asked for
    asks,        \* tables asked for so far
    challenges,  \* challenges made so far
    refused,     \* challenges answered no: [site, latest when challenged]
    waited       \* challenges answered yes for a site the relay did not
                 \* route when challenged (a witness, nothing reads it)

vars == << queue, out, held, latest, asks, challenges, refused, waited >>

TypeOK ==
    /\ queue \in Seq(Installs \cup Waits)
    /\ out \subseteq Installs
    /\ held \in Tables
    /\ latest \in Tables
    /\ asks \in 0..MaxAsks
    /\ challenges \in 0..MaxChallenges
    /\ refused \subseteq Waits
    /\ waited \subseteq Sites

Init ==
    /\ queue = << >>
    /\ out = {}
    /\ held = {}
    /\ latest = {}
    /\ asks = 0
    /\ challenges = 0
    /\ refused = {}
    /\ waited = {}

\* A proxy change, a site joining or leaving, Tor up or down: the sites'
\* settings now imply table [t], which is queued for the relay.
Ask(t) ==
    /\ asks < MaxAsks
    /\ latest' = t
    /\ queue' = Append(queue, [kind |-> "install", table |-> t])
    /\ asks' = asks + 1
    /\ UNCHANGED << out, held, challenges, refused, waited >>

\* A challenge answered from the table the relay holds now: yes when it
\* routes the site, no otherwise.
Answer(e) ==
    IF e.site \in held
    THEN /\ waited' = IF e.routed THEN waited ELSE waited \cup {e.site}
         /\ refused' = refused
    ELSE /\ refused' = refused \cup {e}
         /\ waited' = waited

\* The relay challenges [s]'s credential. In order, the answer waits behind
\* every table already queued; with the mistake it is given at once.
Challenge(s) ==
    /\ challenges < MaxChallenges
    /\ challenges' = challenges + 1
    /\ LET e == [kind |-> "challenge", site |-> s, latest |-> latest,
                 routed |-> s \in held] IN
        IF Mistake = "nowait"
        THEN /\ Answer(e)
             /\ UNCHANGED queue
        ELSE /\ queue' = Append(queue, e)
             /\ UNCHANGED << refused, waited >>
    /\ UNCHANGED << out, held, latest, asks >>

\* The head of the queue takes its turn once nothing is out: an install
\* goes out to the relay, a challenge is answered from the table it holds.
Turn ==
    /\ queue # << >>
    /\ out = {} \/ Mistake = "unordered"
    /\ LET e == Head(queue) IN
        IF e.kind = "install"
        THEN /\ out' = out \cup {e}
             /\ UNCHANGED << refused, waited >>
        ELSE /\ out = {}
             /\ Answer(e)
             /\ UNCHANGED out
    /\ queue' = Tail(queue)
    /\ UNCHANGED << held, latest, asks, challenges >>

\* An install's call returns: the relay routes its table.
Land(e) ==
    /\ held' = e.table
    /\ out' = out \ {e}
    /\ UNCHANGED << queue, latest, asks, challenges, refused, waited >>

\* The bounds reached and everything through: nothing left to happen.
Done ==
    /\ asks = MaxAsks
    /\ challenges = MaxChallenges
    /\ queue = << >>
    /\ out = {}
    /\ UNCHANGED vars

Next ==
    \/ \E t \in Tables : Ask(t)
    \/ \E s \in Sites : Challenge(s)
    \/ Turn
    \/ \E e \in out : Land(e)
    \/ Done

Spec == Init /\ [][Next]_vars

Inv_Latest == (queue = << >> /\ out = {}) => held = latest
Inv_Refused == \A r \in refused : r.site \notin r.latest

\* Witnesses: a challenge refused for a site no table routes, and one that
\* waited for the table routing its site, are reachable (the invariants are
\* not vacuous).
Reach_Refused == refused = {}
Reach_Waited == waited = {}

=============================================================================
