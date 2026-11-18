-------------------- MODULE backup_extension_conflicts --------------------
(***************************************************************************)
(* An extension's backup id may already name different files here. Link   *)
(* by file fingerprint; if absent, add carried files only after approval, *)
(* under a fresh local id. A linked extension runs on a site only with     *)
(* content and per-site reactivation choices. Invalid files and failed    *)
(* writes are abstracted as hasFiles = FALSE.                             *)
(***************************************************************************)
EXTENDS Naturals

CONSTANT Conflict \* "none" | "linkById" | "autoAdd" | "autoRun" |
                  \* "overwrite"

VARIABLES phase, sameFingerprint, hasFiles, approveAdd, restoreExtensions,
          selectedSite, selectedContent, runOnSite, linked, added, active,
          overwroteExisting
vars == <<phase, sameFingerprint, hasFiles, approveAdd, restoreExtensions,
          selectedSite, selectedContent, runOnSite, linked, added, active,
          overwroteExisting>>

ExpectedAdded == restoreExtensions /\ ~sameFingerprint /\ hasFiles /\ approveAdd
ExpectedLinked == restoreExtensions /\ (sameFingerprint \/ ExpectedAdded)
ExpectedActive == ExpectedLinked /\ selectedSite /\ selectedContent /\ runOnSite

Init ==
    /\ phase = "review"
    /\ sameFingerprint \in BOOLEAN
    /\ hasFiles \in BOOLEAN
    /\ approveAdd \in BOOLEAN
    /\ restoreExtensions \in BOOLEAN
    /\ selectedSite \in BOOLEAN
    /\ selectedContent \in BOOLEAN
    /\ runOnSite \in BOOLEAN
    /\ linked = FALSE
    /\ added = FALSE
    /\ active = FALSE
    /\ overwroteExisting = FALSE

Apply ==
    /\ phase = "review"
    /\ phase' = "applied"
    /\ added' = IF Conflict = "autoAdd" THEN
          restoreExtensions /\ ~sameFingerprint /\ hasFiles
          ELSE ExpectedAdded
    /\ linked' = IF Conflict = "linkById" THEN restoreExtensions
           ELSE restoreExtensions /\ (sameFingerprint \/ added')
    /\ active' = IF Conflict = "autoRun" THEN linked'
           ELSE linked' /\ selectedSite /\ selectedContent /\ runOnSite
    /\ overwroteExisting' = (Conflict = "overwrite" /\ added')
    /\ UNCHANGED <<sameFingerprint, hasFiles, approveAdd, restoreExtensions,
                   selectedSite, selectedContent, runOnSite>>

Next == Apply
Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ phase \in {"review", "applied"}
    /\ linked \in BOOLEAN
    /\ added \in BOOLEAN
    /\ active \in BOOLEAN
    /\ overwroteExisting \in BOOLEAN

Inv_Fingerprint == phase # "applied" \/ linked = ExpectedLinked
Inv_AddConsent == phase # "applied" \/ added = ExpectedAdded
Inv_SiteConsent == phase # "applied" \/ active = ExpectedActive
Inv_NoOverwrite == ~overwroteExisting

Reach_Relink == ~(phase = "applied" /\ sameFingerprint /\ linked /\ ~added)
Reach_Add == ~(phase = "applied" /\ ~sameFingerprint /\ hasFiles
               /\ approveAdd /\ added /\ linked)
Reach_Missing == ~(phase = "applied" /\ ~sameFingerprint /\ ~hasFiles
                   /\ ~linked /\ ~active)
=============================================================================
