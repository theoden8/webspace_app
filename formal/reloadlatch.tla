--------------------------- MODULE reloadlatch ---------------------------
(***************************************************************************)
(* BUG-001 rapid-refresh white screen, formalized (PAUSE-027, Attempt 11). *)
(*                                                                         *)
(* warmstart.tla established that the repaint has to land on the ATTACH,   *)
(* not on the event that triggered it. PAUSE-021/025 applied that to a     *)
(* document commit: latch at issue time, repaint when the load settles.    *)
(* The latch was ONE-SHOT -- the first settle after an issue spent it --    *)
(* and that is a second ordering defect, one the settle-side fix hid.       *)
(*                                                                         *)
(* A single document can settle more than once (a redirect chain commits    *)
(* an interstitial first), and a refresh issued while another is in flight  *)
(* settles twice: the aborted load, then its replacement. Under a one-shot  *)
(* latch the first settle repaints a document that is already discarded and *)
(* the one the user is actually looking at gets nothing. Reported as: "if I *)
(* hit refresh often it's still there; hitting refresh again helps".        *)
(*                                                                         *)
(* Fix knob:                                                               *)
(*   "oneshot" = pre-fix. A settle consumes the latch -> RepaintLiveness    *)
(*               VIOLATED (this is the reproduction).                       *)
(*   "window"  = Attempt 11. Arming opens a window the HOST closes on a     *)
(*               timer; every settle inside it repaints -> holds.           *)
(*                                                                         *)
(* MODELING ASSUMPTION (the same shape as Attempt 8's didChangeMetrics and  *)
(* Attempt 9's load-stop proxy, and the same limit): CloseWindow is enabled *)
(* only when nothing is in flight. That encodes the design premise that the *)
(* real 15s window outlasts the commits it is meant to cover. A device on   *)
(* which a commit lands later than the window is outside this model, and    *)
(* the SurfaceDiag trace is what would show it.                             *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    K,       \* nudge ticks per one-shot loop (bounds the state space; K >= 1)
    MaxIssue,\* how many reloads the user gets to issue (>= 2 to reach the bug)
    Fix      \* "oneshot" | "window" -- see header

VARIABLES
    surface,  \* visible site's Android surface: "painted" | "blank"
    owed,     \* a repaint is owed: a blank surface attached, not yet repainted
    nudging,  \* ticks remaining in the active one-shot nudge loop (0 = idle)
    latch,    \* commit latch armed (SurfaceRepaintEngine.commitPending)
    issued,   \* reloads issued so far (bounds the space)
    inflight  \* documents issued whose commit has not settled yet

vars == << surface, owed, nudging, latch, issued, inflight >>

TypeOK ==
    /\ surface \in {"painted", "blank"}
    /\ owed \in BOOLEAN
    /\ nudging \in 0..K
    /\ latch \in BOOLEAN
    /\ issued \in 0..MaxIssue
    /\ inflight \in 0..MaxIssue

Init ==
    /\ surface = "painted"
    /\ owed = FALSE
    /\ nudging = 0
    /\ latch = FALSE
    /\ issued = 0
    /\ inflight = 0

\* The user taps Refresh. reload() discards the painted frame NOW and commits
\* the replacement an unbounded time later, so the surface goes blank here and
\* the issue-time nudge (PAUSE-021) is scheduled against it. Arms the latch.
Issue ==
    /\ issued < MaxIssue
    /\ issued' = issued + 1
    /\ inflight' = inflight + 1
    /\ surface' = "blank"
    /\ owed' = TRUE
    /\ nudging' = K
    /\ latch' = TRUE

\* One nudge tick (`_nudgeSurfaceRepaint` toggling the 1px inset). A relayout
\* repaints whatever surface is currently attached, so it clears any owed
\* repaint. When owed is already false this is a harmless no-op tick.
Tick ==
    /\ nudging > 0
    /\ nudging' = nudging - 1
    /\ surface' = "painted"
    /\ owed' = FALSE
    /\ UNCHANGED << latch, issued, inflight >>

\* A document commits onto the surface (onLoadingChanged(false)). THIS is the
\* attach: the new document lands unpainted. It repaints only if the latch is
\* still armed. Under "oneshot" this settle also disarms it, which is the
\* defect -- the next commit, the one left on screen, finds nothing armed.
Settle ==
    /\ inflight > 0
    /\ inflight' = inflight - 1
    /\ surface' = "blank"
    /\ owed' = TRUE
    /\ nudging' = IF latch THEN K ELSE nudging
    /\ latch' = IF Fix = "oneshot" THEN FALSE ELSE latch
    /\ UNCHANGED << issued >>

\* The host's bounded window elapses (_armCommitLatch's timer). See the
\* modeling assumption in the header for the inflight = 0 guard.
CloseWindow ==
    /\ Fix = "window"
    /\ latch
    /\ inflight = 0
    /\ latch' = FALSE
    /\ UNCHANGED << surface, owed, nudging, issued, inflight >>

Next == Issue \/ Tick \/ Settle \/ CloseWindow

\* Weak fairness on the TICK and on SETTLE: a scheduled nudge loop runs to
\* completion, and an issued document eventually commits. Fairness is NOT on an
\* abstract always-available repaint -- when nudging = 0 Tick is disabled and
\* nothing rescues a blank surface, which is the whole point.
Spec == Init /\ [][Next]_vars /\ WF_vars(Tick) /\ WF_vars(Settle)

\* LIVENESS (BUG-001): every blank-surface attach is eventually repainted.
\* Violated by Fix="oneshot" (the rapid-refresh reproduction); holds for
\* "window".
RepaintLiveness == [] (surface = "blank" => <> (surface = "painted"))

\* Anti-vacuity witness (expect violated): the bad ordering -- every issued
\* document has settled, the surface is still owed and no nudge is scheduled --
\* is actually reachable, so the liveness check above is exercised against the
\* real failure rather than held vacuously.
Reach_SpentLatch ==
    ~(owed = TRUE /\ nudging = 0 /\ inflight = 0 /\ issued = MaxIssue)
=============================================================================
