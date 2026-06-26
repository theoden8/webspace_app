---------------------------- MODULE renderer ----------------------------
(***************************************************************************)
(* BUG-002 dead-renderer recovery, formalized (PAUSE-013 + PAUSE-014).     *)
(*                                                                         *)
(* The OS can kill a webview's renderer process. The recovery property is: *)
(* the user is never stuck looking at a dead renderer --                   *)
(*   Recovered == [] ((visible /\ renderer="dead") ~> renderer="alive")     *)
(*                                                                         *)
(* Two recovery mechanisms:                                                *)
(*   PAUSE-013 (event): a kill WHILE VISIBLE arms a termination event that  *)
(*             drives destroy-and-rebuild.                                  *)
(*   PAUSE-014 (probe): becoming visible (activation) probes the renderer   *)
(*             and rebuilds if dead -- this is what catches a kill that      *)
(*             happened OFFSCREEN, where the event does NOT fire.            *)
(*                                                                         *)
(* The Probe constant gates PAUSE-014. With Probe=FALSE (the noProbe        *)
(* demonstrator = Attempt 1 alone) an offscreen kill leaves the renderer    *)
(* dead when the site is next shown, with no event armed -- the user is     *)
(* stuck on a black screen and Recovered is violated.                       *)
(***************************************************************************)
EXTENDS Naturals

CONSTANT Probe   \* TRUE = PAUSE-014 proactive probe-on-activation is active

VARIABLES
    renderer,    \* "alive" | "dead"
    visible,     \* is the site currently on screen / active
    eventArmed   \* a termination event is pending (only set by a visible kill)

vars == << renderer, visible, eventArmed >>

TypeOK ==
    /\ renderer \in {"alive", "dead"}
    /\ visible \in BOOLEAN
    /\ eventArmed \in BOOLEAN

Init ==
    /\ renderer = "alive"
    /\ visible = TRUE
    /\ eventArmed = FALSE

\* The visible site goes offscreen (user switches away / app backgrounds).
Hide ==
    /\ visible
    /\ visible' = FALSE
    /\ UNCHANGED << renderer, eventArmed >>

\* OS kills the renderer while the site is VISIBLE: the platform termination
\* event fires reliably (arms the event-driven recovery).  PAUSE-013.
KillVisible ==
    /\ renderer = "alive"
    /\ visible
    /\ renderer' = "dead"
    /\ eventArmed' = TRUE
    /\ UNCHANGED visible

\* OS kills the renderer while OFFSCREEN: the event frequently does NOT fire,
\* so no recovery is armed -- the partial that PAUSE-013 alone misses.
KillHidden ==
    /\ renderer = "alive"
    /\ ~visible
    /\ renderer' = "dead"
    /\ eventArmed' = FALSE
    /\ UNCHANGED visible

\* Event-driven destroy-and-rebuild (PAUSE-013): fires when an event is armed.
EventRecover ==
    /\ eventArmed
    /\ renderer = "dead"
    /\ renderer' = "alive"
    /\ eventArmed' = FALSE
    /\ UNCHANGED visible

\* The site becomes visible (activation / _setCurrentIndex). With the probe
\* (PAUSE-014), a dead renderer is rebuilt on the way in; without it, the site
\* comes up still dead.
Activate ==
    /\ ~visible
    /\ visible' = TRUE
    /\ eventArmed' = eventArmed
    /\ IF Probe /\ renderer = "dead" THEN renderer' = "alive"
                                     ELSE renderer' = renderer

Next == Hide \/ KillVisible \/ KillHidden \/ EventRecover \/ Activate

\* Weak fairness on the event-driven recovery; the probe recovery rides
\* Activate (atomic with becoming visible), so it needs no separate fairness.
Spec == Init /\ [][Next]_vars /\ WF_vars(EventRecover)

\* The recovery property: a visible dead renderer is always eventually alive.
Recovered == [] ((visible /\ renderer = "dead") => <> (renderer = "alive"))

\* Anti-vacuity witness (expect violated): a visible dead renderer is reachable,
\* so Recovered is checked against the real failure, not held vacuously.
Reach_VisibleDead == ~(visible /\ renderer = "dead")
=============================================================================
