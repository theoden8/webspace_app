--------------------------- MODULE switchguard ---------------------------
(***************************************************************************)
(* Site-switch version guard vs a concurrent structural mutation. An        *)
(* in-flight `_setCurrentIndex` captures a version at entry and, after each  *)
(* await, activates the site at a positional index. A concurrent structural  *)
(* mutation (`_deleteSite` / import / archive move) shifts that index and    *)
(* bumps the version. The fix bumps `_setCurrentIndexVersion` on every such  *)
(* mutation and re-checks it after each await, so a superseded switch bails  *)
(* instead of resuming against a shifted list and activating the wrong site  *)
(* (a cross-site cookie exposure in legacy mode).                            *)
(*                                                                          *)
(* This model abstracts the version counter as `dirty` (a mutation happened  *)
(* since the switch started, i.e. the captured index is now stale). The      *)
(* good commit is guarded by ~dirty (version unchanged) and otherwise bails; *)
(* the "noguard" demonstrator commits regardless and, after a mutation,      *)
(* latches a wrong activation.                                               *)
(*                                                                          *)
(*   Inv_NoWrongActivation == a committed switch never activated the wrong  *)
(*                            site (never committed against a stale index)   *)
(*                                                                          *)
(* Standalone model (a UI-orchestration state machine; no shared kernel     *)
(* state), like kiosk.tla and renderer.tla.                                  *)
(***************************************************************************)
EXTENDS Naturals

CONSTANT Conflict   \* "none" | "noguard"

VARIABLES
    phase,   \* "idle" | "running" | "committed" | "bailed"
    dirty,   \* a structural mutation occurred since this switch started
    wrong    \* latched: a switch committed against a stale index (wrong site)

vars == << phase, dirty, wrong >>

TypeOK ==
    /\ phase \in {"idle", "running", "committed", "bailed"}
    /\ dirty \in BOOLEAN
    /\ wrong \in BOOLEAN

Init ==
    /\ phase = "idle"
    /\ dirty = FALSE
    /\ wrong = FALSE

\* Begin an in-flight switch: capture the (clean) version at entry.
StartSwitch ==
    /\ phase = "idle"
    /\ phase' = "running"
    /\ dirty' = FALSE
    /\ wrong' = wrong

\* A structural mutation during the switch (delete / import / archive move):
\* it bumps the version, invalidating the captured index. Mutations outside a
\* running switch have no captured index to invalidate, so are not modelled.
Mutate ==
    /\ phase = "running"
    /\ dirty' = TRUE
    /\ phase' = phase
    /\ wrong' = wrong

\* GOOD commit: the version guard passed (no mutation since entry), so the
\* captured index still resolves to the intended site.
CommitGood ==
    /\ phase = "running"
    /\ ~dirty
    /\ phase' = "committed"
    /\ dirty' = dirty
    /\ wrong' = wrong

\* GOOD bail: the version was bumped -> the guard fires, the switch aborts
\* without activating anything.
Bail ==
    /\ phase = "running"
    /\ dirty
    /\ phase' = "bailed"
    /\ dirty' = dirty
    /\ wrong' = wrong

\* Allow another switch episode; a latched wrong activation persists.
Reset ==
    /\ phase \in {"committed", "bailed"}
    /\ phase' = "idle"
    /\ dirty' = FALSE
    /\ wrong' = wrong

\* Demonstrator (unguarded): commit without the version check. If a mutation
\* happened, the captured index is stale and the switch activates the wrong
\* site.
CommitNoGuard ==
    /\ phase = "running"
    /\ phase' = "committed"
    /\ dirty' = dirty
    /\ wrong' = wrong \/ dirty

GoodNext ==
    \/ StartSwitch
    \/ Mutate
    \/ CommitGood
    \/ Bail
    \/ Reset

Next == GoodNext \/ (Conflict = "noguard" /\ CommitNoGuard)

Spec == Init /\ [][Next]_vars

\* SAFETY: no switch ever committed against a stale index. Broken by "noguard".
Inv_NoWrongActivation == ~wrong

\* Anti-vacuity witness (expect violated): a switch CAN reach the guarded-bail
\* state -- i.e. the "mutation during an in-flight switch" scenario the guard
\* protects against is actually reachable and handled by bailing (not by a
\* wrong commit).
Reach_Bailed == phase # "bailed"
=============================================================================
