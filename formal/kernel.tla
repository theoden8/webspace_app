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
(* interleaving. The Conflict knob below demonstrates three non-mix kinds: *)
(* a liveness break ("bypass") and two safety breaks ("evict",             *)
(* "contaminate").                                                         *)
(*                                                                         *)
(* Modules currently composed:                                             *)
(*   - webview-pause-lifecycle  (PAUSE-013..018; surface repaint)          *)
(*   - navigation               (back/forward; bfcache re-attach)          *)
(*   - lazy-webview-loading     (on-demand load + memory-pressure evict)   *)
(*   - per-site-cookie-isolation (legacy shared-jar; no cross-site leak)   *)
(*                                                                         *)
(* Requirement IDs are cited on the actions/properties that encode them so *)
(* spec <-> model traceability is grep-able.                               *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    N,         \* bounded number of sites (keeps the state space finite)
    Conflict   \* "none" | "bypass" | "evict" | "contaminate" -- demonstrator selector

Sites == 1..N

VARIABLES
    surface,       \* visible site's Android surface: "painted" | "blank"
    owed,          \* a repaint is owed: a blank surface attached, not yet nudged
    currentIndex,  \* visible site
    loaded,        \* set of loaded site indices
    frozen,        \* repaint chokepoint wedged (set only by the conflict module)
    jarOwner       \* site whose cookies are materialized in the shared native jar

vars == << surface, owed, currentIndex, loaded, frozen, jarOwner >>

TypeOK ==
    /\ surface \in {"painted", "blank"}
    /\ owed \in BOOLEAN
    /\ currentIndex \in Sites
    /\ loaded \subseteq Sites
    /\ frozen \in BOOLEAN
    /\ jarOwner \in Sites

Init ==
    /\ surface = "painted"
    /\ owed = FALSE
    /\ currentIndex = 1
    /\ loaded = {1}
    /\ frozen = FALSE
    /\ jarOwner = 1

\* A fresh or re-parented hybrid-composition SurfaceView attaches without a
\* paint: the renderer is alive but the surface is blank until something
\* forces a relayout. This is the shared mechanism behind BUG-001.
Attach ==
    /\ surface' = "blank"
    /\ owed' = TRUE

(***************************************************************************)
(* Module: webview-pause-lifecycle   (owns: surface, owed)                 *)
(***************************************************************************)

\* Bring a site onstage (_setCurrentIndex). The legacy cookie engine runs
\* capture-nuke-restore so the shared jar now holds the activated site's
\* cookies: jarOwner' = s (see per-site-cookie-isolation below).
Activate(s) ==
    /\ currentIndex' = s
    /\ loaded' = loaded \cup {s}
    /\ jarOwner' = s
    /\ Attach
    /\ frozen' = frozen

\* App returns to foreground (_onResumed).  PAUSE-015.
Resume ==
    /\ Attach
    /\ UNCHANGED << currentIndex, loaded, frozen, jarOwner >>

\* A from-scratch controller mounts a brand-new SurfaceView.  PAUSE-017.
ControllerAttach ==
    /\ Attach
    /\ UNCHANGED << currentIndex, loaded, frozen, jarOwner >>

\* The repaint chokepoint (_nudgeSurfaceRepaint). Clears the owed repaint.
\* PAUSE-015 / PAUSE-017 / PAUSE-018.
Nudge ==
    /\ owed
    /\ ~frozen
    /\ surface' = "painted"
    /\ owed' = FALSE
    /\ UNCHANGED << currentIndex, loaded, frozen, jarOwner >>

(***************************************************************************)
(* Module: navigation   (back/forward; reuses controller, re-attaches)    *)
(***************************************************************************)

\* Back/forward with bfcache enabled restores onto a fresh SurfaceView.
\* PAUSE-018 routes these through the chokepoint (Nudge). Same site, so the
\* shared jar is unchanged.
Back ==
    /\ Attach
    /\ UNCHANGED << currentIndex, loaded, frozen, jarOwner >>

Forward ==
    /\ Attach
    /\ UNCHANGED << currentIndex, loaded, frozen, jarOwner >>

(***************************************************************************)
(* Module: lazy-webview-loading   (owns: loaded)                          *)
(***************************************************************************)

\* On-demand background load: add a site to the loaded set (no surface, no
\* jar change -- only the visible site's cookies are in the shared jar).
LoadSite(s) ==
    /\ s \notin loaded
    /\ loaded' = loaded \cup {s}
    /\ UNCHANGED << surface, owed, currentIndex, frozen, jarOwner >>

\* Memory-pressure eviction of a NON-visible loaded site. Guarantee: never
\* the visible site -- that guarantee is what keeps Inv_CurrentLoaded true,
\* and what navigation/pause-lifecycle rely on.
Evict(s) ==
    /\ s \in loaded
    /\ s # currentIndex
    /\ loaded' = loaded \ {s}
    /\ UNCHANGED << surface, owed, currentIndex, frozen, jarOwner >>

(***************************************************************************)
(* Module: per-site-cookie-isolation  (legacy shared-jar engine)          *)
(*                                                                         *)
(* The legacy (non-container) engine keeps ONE site's cookies in the       *)
(* shared native jar at a time; activation runs capture-nuke-restore so    *)
(* the jar tracks the visible site. The container engine gives each site   *)
(* its own jar and trivially satisfies the same invariant. No standalone   *)
(* action: jarOwner is driven by Activate above; the invariant is below.   *)
(***************************************************************************)

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
    /\ UNCHANGED << currentIndex, loaded, jarOwner >>

\* (evict) An eviction that drops the VISIBLE site -- lazy-loading forgetting
\* its "never evict current" guarantee. A SAFETY non-mix: violates
\* Inv_CurrentLoaded, the invariant navigation/lifecycle assume.
EvictCurrent ==
    /\ currentIndex \in loaded
    /\ loaded' = loaded \ {currentIndex}
    /\ UNCHANGED << surface, owed, currentIndex, frozen, jarOwner >>

\* (contaminate) An activation that switches the visible site but forgets the
\* legacy capture-nuke-restore, leaving another site's cookies in the shared
\* jar. A SAFETY non-mix: violates Inv_JarMatchesVisible (cross-site leak).
Contaminate ==
    /\ \E s \in Sites :
        /\ s # currentIndex
        /\ currentIndex' = s
        /\ loaded' = loaded \cup {s}
    /\ Attach
    /\ frozen' = frozen
    /\ jarOwner' = jarOwner

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
        \/ (Conflict = "bypass"      /\ BackBypass)
        \/ (Conflict = "evict"       /\ EvictCurrent)
        \/ (Conflict = "contaminate" /\ Contaminate)

\* Weak fairness on Nudge: a continuously-owed, non-frozen repaint must
\* eventually fire. This is the formal counterpart of "_nudgeSurfaceRepaint
\* runs its tick loop to completion."
Spec == Init /\ [][Next]_vars /\ WF_vars(Nudge)

(***************************************************************************)
(* Properties                                                             *)
(***************************************************************************)

\* SAFETY (navigation x lazy-loading): the visible site is always loaded.
\* Broken by the "evict" demonstrator.
Inv_CurrentLoaded == currentIndex \in loaded

\* SAFETY (cookie-isolation x navigation): the shared jar always holds the
\* visible site's cookies -- never another site's. Broken by "contaminate".
Inv_JarMatchesVisible == jarOwner = currentIndex

\* LIVENESS (pause-lifecycle PAUSE-013..018): every blank-surface attach is
\* eventually repainted. Broken by the "bypass" demonstrator. This is the
\* formal statement of BUG-001's fix.
RepaintLiveness == [] (surface = "blank" => <> (surface = "painted"))

(***************************************************************************)
(* Model tests -- reachability witnesses (anti-vacuity).                   *)
(*                                                                         *)
(* A green safety/liveness check is only meaningful if the legal behavior  *)
(* it constrains is actually REACHABLE -- otherwise the invariant holds    *)
(* vacuously because nothing happens. Each witness below is used as an     *)
(* INVARIANT in a config that EXPECTS A VIOLATION: TLC's counterexample is *)
(* the scenario trace proving the behavior is reachable. If one of these   *)
(* ever passes, the model has gone inert and its green checks are hollow.  *)
(***************************************************************************)

\* pause-lifecycle: a blank surface attach actually occurs (else RepaintLiveness
\* is vacuous). Expect violated.
Reach_SurfaceAttach == surface = "painted"

\* navigation/lifecycle: a site other than the initial one can be activated.
\* Expect violated.
Reach_SiteSwitch == currentIndex = 1

\* lazy-loading: a backgrounded (non-visible) site can be evicted while a
\* different site is visible. Expect violated.
Reach_EvictBackground == ~(currentIndex = 2 /\ 1 \notin loaded)
=============================================================================
