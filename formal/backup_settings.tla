-------------------------- MODULE backup_settings --------------------------
(***************************************************************************)
(* Independent app-preference and global-script choices during import.     *)
(* The search-default preference is skipped when no sites are restored.    *)
(* A global script can run only on a chosen site whose script content was  *)
(* chosen, after the per-site run choice and final confirmation.            *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANT Conflict \* "none" | "allprefs" | "globalWithoutConsent"
Sites == {1, 2}
PrefKeys == {"general", "search"}

VARIABLES phase, pickedSites, pickedScripts, runScripts, pickedPrefs,
          restoreSites, restoreApp, restoreGlobal, globalAvailable,
          confirmScripts, appliedPrefs, importedGlobalLibrary,
          activeGlobalScripts
vars == <<phase, pickedSites, pickedScripts, runScripts, pickedPrefs,
          restoreSites, restoreApp, restoreGlobal, globalAvailable,
          confirmScripts, appliedPrefs, importedGlobalLibrary,
          activeGlobalScripts>>

ExpectedPrefs == IF restoreApp THEN
    (IF restoreSites THEN pickedPrefs ELSE pickedPrefs \ {"search"}) ELSE {}
ExpectedGlobalRuns == IF restoreGlobal /\ globalAvailable /\ confirmScripts
    THEN pickedSites \cap pickedScripts \cap runScripts ELSE {}

Init ==
    /\ phase = "review"
    /\ pickedSites \in SUBSET Sites
    /\ pickedScripts \in SUBSET Sites
    /\ runScripts \in SUBSET Sites
    /\ pickedPrefs \in SUBSET PrefKeys
    /\ restoreSites \in BOOLEAN
    /\ restoreApp \in BOOLEAN
    /\ restoreGlobal \in BOOLEAN
    /\ globalAvailable \in BOOLEAN
    /\ confirmScripts \in BOOLEAN
    /\ appliedPrefs = {}
    /\ importedGlobalLibrary = FALSE
    /\ activeGlobalScripts = {}

Apply ==
    /\ phase = "review"
    /\ phase' = "applied"
    /\ appliedPrefs' = IF Conflict = "allprefs" THEN pickedPrefs
                        ELSE ExpectedPrefs
    /\ importedGlobalLibrary' = restoreGlobal /\ globalAvailable
    /\ activeGlobalScripts' = IF Conflict = "globalWithoutConsent"
          THEN pickedSites \cap pickedScripts \cap runScripts
          ELSE ExpectedGlobalRuns
    /\ UNCHANGED <<pickedSites, pickedScripts, runScripts, pickedPrefs,
                   restoreSites, restoreApp, restoreGlobal,
                   globalAvailable, confirmScripts>>

Next == Apply
Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ phase \in {"review", "applied"}
    /\ appliedPrefs \subseteq PrefKeys
    /\ activeGlobalScripts \subseteq Sites
    /\ importedGlobalLibrary \in BOOLEAN

Inv_PrefScope == phase # "applied" \/ appliedPrefs = ExpectedPrefs
Inv_GlobalLibraryScope == phase # "applied" \/
    importedGlobalLibrary = (restoreGlobal /\ globalAvailable)
Inv_GlobalRunConsent == phase # "applied" \/
    activeGlobalScripts = ExpectedGlobalRuns

Reach_SearchSkipped == ~(phase = "applied" /\ restoreApp
    /\ ~restoreSites /\ "search" \in pickedPrefs
    /\ "search" \notin appliedPrefs)
Reach_GlobalRuns == ~(phase = "applied" /\ activeGlobalScripts = {1})
=============================================================================
