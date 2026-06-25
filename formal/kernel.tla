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
(* interleaving. The Conflict knob below demonstrates BOTH failure kinds:  *)
(* a liveness non-mix ("bypass") and a safety non-mix ("evict").           *)
(*                                                                         *)
(* Modules currently composed:                                             *)
(*   - webview-pause-lifecycle  (PAUSE-013..018; surface repaint)          *)
(*   - navigation               (back/forward; bfcache re-attach)          *)
(*   - lazy-webview-loading     (on-demand load + memory-pressure evict)   *)
(*                                                                         *)
(* Requirement IDs are cited on the actions/properties that encode them so *)
(* spec <-> model traceability is grep-able.                               *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    N,         \* bounded number of sites (keeps the state space finite)
    Conflict   \* "none" | "bypass" | "evict" -- selects a demonstrator non-mix

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
(* Module: lazy-webview-loading   (owns: loaded)                          *)
(***************************************************************************)

\* On-demand background load: add a site to the loaded set (no surface yet;
\* the visible site's surface is the lifecycle module's concern).
LoadSite(s) ==
    /\ s \notin loaded
    /\ loaded' = loaded \cup {s}
    /\ UNCHANGED << surface, owed, currentIndex, frozen >>

\* Memory-pressure eviction of a NON-visible loaded site. Guarantee: never
\* the visible site -- that guarantee is what keeps Inv_CurrentLoaded true,
\* and what navigation/pause-lifecycle rely on.
Evict(s) ==
    /\ s \in loaded
    /\ s # currentIndex
    /\ loaded' = loaded \ {s}
    /\ UNCHANGED << surface, owed, currentIndex, frozen >>

(***************************************************************************)
(* Conflict demonstrators (gated by Conflict).                            *)
(***************************************************************************)

\* (bypass) A back route that re-attaches the surface but is NOT wired to the
\* repaint chokepoint -- the literal BUG-001 failure (attempts 2-5 each left
\* one such path). Preserves every SAFETY invariant, yet wedges the surface
\* blank: a LIVENESS non-mix against pause-lifecycle's RepaintLiveness.
BackBypass ==
    /\ surface' = "blank"
    /\ owed' = TRUE
    /\ frozen' = TRUE
    /\ UNCHANGED << currentIndex, loaded >>

\* (evict) An eviction that drops the VISIBLE site -- lazy-loading forgetting
\* its "never evict current" guarantee. A SAFETY non-mix: violates
\* Inv_CurrentLoaded, the invariant navigation/lifecycle assume.
EvictCurrent ==
    /\ currentIndex \in loaded
    /\ loaded' = loaded \ {currentIndex}
    /\ UNCHANGED << surface, owed, currentIndex, frozen >>

GoodNext ==
    \/ \E s \in Sites : Activate(s)
    \/ Resume
    \/ ControllerAttach
    \/ Back
    \/ Forward
    \/ Nudge
    \/ \E s \in Sites : LoadSite(s)
    \/ \E s \in Sites : Evict(s)

Next == GoodNext
        \/ (Conflict = "bypass" /\ BackBypass)
        \/ (Conflict = "evict"  /\ EvictCurrent)

\* Weak fairness on Nudge: a continuously-owed, non-frozen repaint must
\* eventually fire. This is the formal counterpart of "_nudgeSurfaceRepaint
\* runs its tick loop to completion."
Spec == Init /\ [][Next]_vars /\ WF_vars(Nudge)

(***************************************************************************)
(* Properties                                                             *)
(***************************************************************************)

\* SAFETY (cross-module: navigation x lazy-loading): the visible site is
\* always loaded. Broken by the "evict" demonstrator.
Inv_CurrentLoaded == currentIndex \in loaded

\* LIVENESS (pause-lifecycle PAUSE-013..018): every blank-surface attach is
\* eventually repainted. Broken by the "bypass" demonstrator. This is the
\* formal statement of BUG-001's fix.
RepaintLiveness == [] (surface = "blank" => <> (surface = "painted"))
=============================================================================
