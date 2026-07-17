-------------------------- MODULE jar_nonempty --------------------------
(***************************************************************************)
(* Legacy cookie engine: the shared jar is never left empty across a        *)
(* superseded restore. The capture-nuke-restore sequence empties the shared  *)
(* native jar (step 3) before repopulating it (step 4). The old code checked *)
(* the activation version guard *between* the nuke and the restore and       *)
(* bailed if superseded, leaving the jar empty -- the next activation then   *)
(* captured that emptiness and persisted `[]`, wiping every loaded site's    *)
(* stored session. The fix removes the post-nuke bail: once nuked, the jar   *)
(* is always fully repopulated before returning.                            *)
(*                                                                          *)
(*   Inv_JarRepopulated == whenever the engine is back at rest, the jar is  *)
(*                         full (never left empty)                          *)
(*                                                                          *)
(* The "bail" demonstrator restores-with-bail: a superseded restore returns  *)
(* to rest with the jar still empty, and is caught. Standalone model.        *)
(***************************************************************************)
EXTENDS Naturals

CONSTANT Conflict   \* "none" | "bail"

VARIABLES
    phase,       \* "idle" (at rest) | "nuked" (jar emptied, mid-restore)
    jarFull,     \* whether the shared jar currently holds the loaded sessions
    superseded   \* a newer activation bumped the version during this restore

vars == << phase, jarFull, superseded >>

TypeOK ==
    /\ phase \in {"idle", "nuked"}
    /\ jarFull \in BOOLEAN
    /\ superseded \in BOOLEAN

Init ==
    /\ phase = "idle"
    /\ jarFull = TRUE
    /\ superseded = FALSE

\* Steps 1-3: capture the loaded sessions to storage, then nuke the shared
\* jar. Perpetually enabled from rest, so the model never deadlocks.
Nuke ==
    /\ phase = "idle"
    /\ phase' = "nuked"
    /\ jarFull' = FALSE
    /\ superseded' = FALSE

\* A newer activation supersedes this restore mid-flight (bumps the version).
Supersede ==
    /\ phase = "nuked"
    /\ superseded' = TRUE
    /\ phase' = phase
    /\ jarFull' = jarFull

\* Step 4 (the fix): always repopulate before returning to rest, regardless
\* of supersession.
RestoreGood ==
    /\ phase = "nuked"
    /\ phase' = "idle"
    /\ jarFull' = TRUE
    /\ superseded' = FALSE

\* Demonstrator: the old post-nuke bail. A superseded restore returns to rest
\* with the jar still empty.
RestoreBail ==
    /\ phase = "nuked"
    /\ phase' = "idle"
    /\ jarFull' = (IF superseded THEN FALSE ELSE TRUE)
    /\ superseded' = FALSE

GoodNext == Nuke \/ Supersede \/ RestoreGood

Next == GoodNext \/ (Conflict = "bail" /\ RestoreBail)

Spec == Init /\ [][Next]_vars

\* SAFETY: whenever the engine is at rest, the jar is full -- never left empty
\* for the next activation to capture and persist. Broken by "bail".
Inv_JarRepopulated == (phase = "idle") => jarFull

\* Anti-vacuity witness (expect violated): the nuked (jar-empty, mid-restore)
\* state is reachable, so the invariant constrains a real repopulation.
Reach_Nuked == phase # "nuked"
=============================================================================
