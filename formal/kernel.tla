---------------------------- MODULE kernel ----------------------------
(***************************************************************************)
(* WebSpace cross-spec verification kernel.                                *)
(*                                                                         *)
(* Each spec that mutates SHARED runtime/persisted state contributes a     *)
(* module here: the variables it touches, its actions (transitions), and   *)
(* the invariant it must preserve. Independent (leaf) specs do NOT belong  *)
(* here -- they share no state, so they compose for free.                  *)
(*                                                                         *)
(* "Does a new spec mix?" is mechanical: add its actions to Next and its   *)
(* invariant/property to the checked list, then re-run TLC. A reachable    *)
(* violation = it does not mix, and the counterexample names the breaking  *)
(* interleaving. The IncludeConflict knob below demonstrates exactly that. *)
(*                                                                         *)
(* Modules currently composed:                                             *)
(*   - webview-pause-lifecycle  (PAUSE-013..018; surface repaint)          *)
(*   - navigation               (back/forward; bfcache re-attach)          *)
(*                                                                         *)
(* Requirement IDs are cited on the actions/properties that encode them so *)
(* spec <-> model traceability is grep-able.                               *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    N,                \* bounded number of sites (keeps the state space finite)
    IncludeConflict   \* TRUE pulls in the demonstrator non-mixing module

Sites == 1..N

VARIABLES
    surface,       \* visible site's Android surface: "painted" | "blank"
    owed,          \* a repaint is owed: a blank surface attached, not yet nudged
    currentIndex,  \* visible site
    loaded,        \* set of loaded site indices
    frozen         \* repaint chokepoint wedged (set only by the conflict module)

vars == << surface, owed, currentIndex, loaded, frozen >>

TypeOK ==
    /\ surface \in {"painted", "blank"}
    /\ owed \in BOOLEAN
    /\ currentIndex \in Sites
    /\ loaded \subseteq Sites
    /\ frozen \in BOOLEAN

Init ==
    /\ surface = "painted"
    /\ owed = FALSE
    /\ currentIndex = 1
    /\ loaded = {1}
    /\ frozen = FALSE

\* A fresh or re-parented hybrid-composition SurfaceView attaches without a
\* paint: the renderer is alive but the surface is blank until something
\* forces a relayout. This is the shared mechanism behind BUG-001.
Attach ==
    /\ surface' = "blank"
    /\ owed' = TRUE

(***************************************************************************)
(* Module: webview-pause-lifecycle   (owns: surface, owed)                 *)
(***************************************************************************)

\* Bring a site onstage (_setCurrentIndex).
Activate(s) ==
    /\ currentIndex' = s
    /\ loaded' = loaded \cup {s}
    /\ Attach
    /\ frozen' = frozen

\* App returns to foreground (_onResumed).  PAUSE-015.
Resume ==
    /\ Attach
    /\ UNCHANGED << currentIndex, loaded, frozen >>

\* A from-scratch controller mounts a brand-new SurfaceView.  PAUSE-017.
ControllerAttach ==
    /\ Attach
    /\ UNCHANGED << currentIndex, loaded, frozen >>

\* The repaint chokepoint (_nudgeSurfaceRepaint). Clears the owed repaint.
\* PAUSE-015 / PAUSE-017 / PAUSE-018.
Nudge ==
    /\ owed
    /\ ~frozen
    /\ surface' = "painted"
    /\ owed' = FALSE
    /\ UNCHANGED << currentIndex, loaded, frozen >>

(***************************************************************************)
(* Module: navigation   (back/forward; reuses controller, re-attaches)    *)
(***************************************************************************)

\* Back/forward with bfcache enabled restores onto a fresh SurfaceView.
\* PAUSE-018 routes these through the chokepoint (Nudge).
Back ==
    /\ Attach
    /\ UNCHANGED << currentIndex, loaded, frozen >>

Forward ==
    /\ Attach
    /\ UNCHANGED << currentIndex, loaded, frozen >>

(***************************************************************************)
(* Conflict demonstrator (gated by IncludeConflict).                      *)
(*                                                                         *)
(* A back-navigation route that re-attaches the surface but is NOT wired   *)
(* to the repaint chokepoint -- the literal BUG-001 failure (attempts 2-5  *)
(* each left one such path). It preserves every SAFETY invariant, yet it   *)
(* breaks the RepaintLiveness guarantee that pause-lifecycle relies on:    *)
(* once it fires, the surface is wedged blank. This is what "does not mix" *)
(* looks like for a liveness contract.                                     *)
(***************************************************************************)
BackBypass ==
    /\ surface' = "blank"
    /\ owed' = TRUE
    /\ frozen' = TRUE
    /\ UNCHANGED << currentIndex, loaded >>

GoodNext ==
    \/ \E s \in Sites : Activate(s)
    \/ Resume
    \/ ControllerAttach
    \/ Back
    \/ Forward
    \/ Nudge

Next == GoodNext \/ (IncludeConflict /\ BackBypass)

\* Weak fairness on Nudge: a continuously-owed, non-frozen repaint must
\* eventually fire. This is the formal counterpart of "_nudgeSurfaceRepaint
\* runs its tick loop to completion."
Spec == Init /\ [][Next]_vars /\ WF_vars(Nudge)

(***************************************************************************)
(* Properties                                                             *)
(***************************************************************************)

\* SAFETY (cross-module: navigation x lazy-loading): the visible site is
\* always loaded. Holds in BOTH configs -- the conflict is a liveness, not
\* a safety, non-mix.
Inv_CurrentLoaded == currentIndex \in loaded

\* LIVENESS (pause-lifecycle PAUSE-013..018): every blank-surface attach is
\* eventually repainted. This is the formal statement of BUG-001's fix.
RepaintLiveness == [] (surface = "blank" => <> (surface = "painted"))
=============================================================================
