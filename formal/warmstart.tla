---------------------------- MODULE warmstart ----------------------------
(***************************************************************************)
(* BUG-001 warm-start white screen, formalized (PAUSE-020, Attempt 8).     *)
(*                                                                         *)
(* The kernel models the surface repaint with `Resume == Attach` (the      *)
(* attach is ATOMIC with the resume event) plus `WF_vars(Nudge)` (a        *)
(* repaint is ALWAYS eventually available whenever one is owed). Under      *)
(* those two assumptions warm-start is trivially safe -- which is exactly   *)
(* why the kernel cannot see this bug (docs/bugs/001-white-screen.md gap    *)
(* #4). Both assumptions are false on a real warm start:                    *)
(*                                                                         *)
(*   1. The Android hybrid-composition SurfaceView is destroyed on          *)
(*      background and RE-CREATED on foreground. That re-attach is a         *)
(*      SEPARATE, asynchronous event -- it does not coincide with the       *)
(*      `resumed` lifecycle callback and can land a frame or more LATER.     *)
(*   2. `_nudgeSurfaceRepaint` is not a magic always-available repaint. It   *)
(*      is a ONE-SHOT tick loop fired by a specific trigger and then         *)
(*      drains. Once it drains it is gone.                                   *)
(*                                                                         *)
(* So the defect is an ORDERING: the resume one-shot nudge fires and drains  *)
(* BEFORE the async SurfaceReattach, leaving a blank surface with nothing    *)
(* left to repaint it. This module models the nudge realistically (an        *)
(* event-triggered one-shot, WF on the tick, NOT on an abstract Nudge) and   *)
(* the reattach as its own action, so the bad interleaving is reachable.     *)
(*                                                                         *)
(* Fix knob:                                                                *)
(*   "none"   = pre-fix. Only Resume schedules a nudge. A reattach after the *)
(*              resume nudge drains is never repainted -> RepaintLiveness     *)
(*              is VIOLATED (this is the reproduction).                       *)
(*   "attach" = Attempt 8. The reattach itself schedules a nudge (the        *)
(*              didChangeMetrics re-nudge within the post-resume window is a  *)
(*              proxy for the attach signal) -> RepaintLiveness HOLDS.        *)
(*                                                                         *)
(* This is the model counterpart of the durable fix in gap #3: nudge on the  *)
(* ATTACH, not on a lifecycle event that only approximates its timing.       *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    K,     \* nudge ticks per one-shot loop (bounds the state space; K >= 1)
    Fix    \* "none" | "attach" -- see header

VARIABLES
    surface,     \* visible site's Android surface: "painted" | "blank"
    owed,        \* a repaint is owed: a blank surface attached, not yet repainted
    nudging,     \* ticks remaining in the active one-shot nudge loop (0 = idle)
    resumed,     \* a foreground resume has occurred (arms the warm-start reattach)
    reattached   \* the warm-start SurfaceView reattach has fired (bounds the space)

vars == << surface, owed, nudging, resumed, reattached >>

TypeOK ==
    /\ surface \in {"painted", "blank"}
    /\ owed \in BOOLEAN
    /\ nudging \in 0..K
    /\ resumed \in BOOLEAN
    /\ reattached \in BOOLEAN

Init ==
    /\ surface = "painted"
    /\ owed = FALSE
    /\ nudging = 0
    /\ resumed = FALSE
    /\ reattached = FALSE

\* App returns to foreground. `_onResumed` fires its single tail nudge
\* (PAUSE-015): schedule a one-shot loop. The surface has NOT necessarily
\* re-attached yet -- that is the separate SurfaceReattach below.
Resume ==
    /\ ~resumed
    /\ resumed' = TRUE
    /\ nudging' = K
    /\ UNCHANGED << surface, owed, reattached >>

\* One nudge tick (`_nudgeSurfaceRepaint` toggling the 1px inset). A relayout
\* repaints whatever surface is currently attached, so it clears any owed
\* repaint. When owed is already false this is a harmless no-op tick.
Tick ==
    /\ nudging > 0
    /\ nudging' = nudging - 1
    /\ surface' = "painted"
    /\ owed' = FALSE
    /\ UNCHANGED << resumed, reattached >>

\* The warm-start SurfaceView re-attaches blank -- the real BUG-001 mechanism,
\* modeled as its own asynchronous event that can interleave anywhere after the
\* resume. Under Fix="attach" the attach signal (didChangeMetrics within the
\* post-resume window) schedules a nudge; under "none" it does not.
SurfaceReattach ==
    /\ resumed
    /\ ~reattached
    /\ reattached' = TRUE
    /\ surface' = "blank"
    /\ owed' = TRUE
    /\ nudging' = IF Fix = "attach" THEN K ELSE nudging
    /\ UNCHANGED << resumed >>

Next == Resume \/ Tick \/ SurfaceReattach

\* Weak fairness on the TICK, not on an abstract always-available repaint: a
\* scheduled nudge loop runs to completion. Crucially, when no nudge is
\* scheduled (nudging = 0) Tick is DISABLED, so fairness offers no rescue --
\* that is the whole point, and what the kernel's WF_vars(Nudge) papered over.
Spec == Init /\ [][Next]_vars /\ WF_vars(Tick)

\* LIVENESS (BUG-001): every blank-surface attach is eventually repainted.
\* Violated by Fix="none" (the warm-start reproduction); holds for "attach".
RepaintLiveness == [] (surface = "blank" => <> (surface = "painted"))

\* Anti-vacuity witness (expect violated): the bad ordering -- a reattach that
\* lands after the resume nudge has fully drained -- is actually reachable, so
\* the liveness check above is exercised against the real failure, not held
\* vacuously.
Reach_LateReattach == ~(owed = TRUE /\ nudging = 0 /\ reattached = TRUE)
=============================================================================
