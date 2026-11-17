--------------------------- MODULE backup_import ---------------------------
(***************************************************************************)
(* Bounded import-selection model. Sites 1 and 2 may be in the backup; site  *)
(* 3 is already on the device. The empty-backup branch has no backup sites. *)
(* Folder 10 contains both backup sites when present, folder 11 is empty,  *)
(* and folder 12 is already on the device. Each selector is chosen          *)
(* independently, including stale choices from a deselected site.          *)
(* The Apply step abstracts planSettingsImport and BackupController.import. *)
(* This is a specification of their intended effects, not a refinement    *)
(* proof of Dart code.                                                     *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANT Conflict \* "none" | "runall" | "allfolders" | "emptyReplace"

BackupSites == {1, 2}
CurrentSites == {3}
BackupFolders == {10, 11}
CurrentFolders == {12}

VARIABLES phase, pickedSites, pickedFolders, pickedScripts, pickedCookies,
          pickedExtensions, runScripts, runExtensions, restoreExtensions,
          approveScripts, restoreApp, emptyBackup, finalSites, finalFolders,
          importedFolders, importedMembers, activeScripts, activeExtensions,
          importedCookies, appliedApp

vars == <<phase, pickedSites, pickedFolders, pickedScripts, pickedCookies,
          pickedExtensions, runScripts, runExtensions, restoreExtensions,
          approveScripts, restoreApp, emptyBackup, finalSites, finalFolders,
          importedFolders, importedMembers, activeScripts, activeExtensions,
          importedCookies, appliedApp>>

EffectiveBackupSites == IF emptyBackup THEN {} ELSE BackupSites
Members(w) == IF emptyBackup THEN {} ELSE IF w = 10 THEN {1, 2} ELSE {}
HasSiteScope == pickedSites # {} \/ pickedFolders # {}
Partial == pickedSites # EffectiveBackupSites \/
           (emptyBackup /\ pickedFolders # {})

Init ==
    /\ phase = "review"
    /\ emptyBackup \in BOOLEAN
    /\ pickedSites \in SUBSET EffectiveBackupSites
    /\ pickedFolders \in SUBSET BackupFolders
    /\ pickedScripts \in SUBSET EffectiveBackupSites
    /\ pickedCookies \in SUBSET EffectiveBackupSites
    /\ pickedExtensions \in SUBSET EffectiveBackupSites
    /\ runScripts \in SUBSET EffectiveBackupSites
    /\ runExtensions \in SUBSET EffectiveBackupSites
    /\ restoreExtensions \in BOOLEAN
    /\ approveScripts \in BOOLEAN
    /\ restoreApp \in BOOLEAN
    /\ finalSites = CurrentSites
    /\ finalFolders = CurrentFolders
    /\ importedFolders = {}
    /\ importedMembers = [w \in BackupFolders |-> {}]
    /\ activeScripts = {}
    /\ activeExtensions = {}
    /\ importedCookies = {}
    /\ appliedApp = FALSE

Apply ==
    /\ phase = "review"
    /\ phase' = "applied"
    /\ finalSites' = IF Conflict = "emptyReplace" /\ emptyBackup
                        /\ pickedFolders # {} THEN {}
                     ELSE IF ~HasSiteScope THEN CurrentSites
                     ELSE IF Partial THEN CurrentSites \cup pickedSites
                     ELSE pickedSites
    /\ finalFolders' = IF ~HasSiteScope THEN CurrentFolders
                       ELSE IF Partial THEN CurrentFolders \cup pickedFolders
                       ELSE pickedFolders
    /\ importedFolders' = IF ~HasSiteScope THEN {}
                          ELSE IF Conflict = "allfolders" THEN BackupFolders
                          ELSE pickedFolders
    /\ importedMembers' = [w \in BackupFolders |->
           IF w \in pickedFolders THEN Members(w) \cap pickedSites ELSE {}]
    /\ activeScripts' = IF Conflict = "runall" THEN pickedSites
                        ELSE IF approveScripts
                          THEN pickedSites \cap pickedScripts \cap runScripts
                          ELSE {}
    /\ activeExtensions' = IF restoreExtensions
          THEN pickedSites \cap pickedExtensions \cap runExtensions ELSE {}
    /\ importedCookies' = pickedSites \cap pickedCookies
    /\ appliedApp' = restoreApp
    /\ UNCHANGED <<pickedSites, pickedFolders, pickedScripts, pickedCookies,
                   pickedExtensions, runScripts, runExtensions,
                   restoreExtensions, approveScripts, restoreApp, emptyBackup>>

Next == Apply
Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ phase \in {"review", "applied"}
    /\ finalSites \subseteq BackupSites \cup CurrentSites
    /\ finalFolders \subseteq BackupFolders \cup CurrentFolders
    /\ importedFolders \subseteq BackupFolders
    /\ activeScripts \subseteq BackupSites
    /\ activeExtensions \subseteq BackupSites
    /\ importedCookies \subseteq BackupSites

Inv_SiteScope == phase # "applied" \/
    (finalSites = (IF ~HasSiteScope THEN CurrentSites
                   ELSE IF Partial THEN CurrentSites \cup pickedSites
                   ELSE pickedSites))
Inv_FolderScope == phase # "applied" \/
    ( /\ importedFolders = pickedFolders
      /\ finalFolders = (IF ~HasSiteScope THEN CurrentFolders
                          ELSE IF Partial THEN CurrentFolders \cup pickedFolders
                          ELSE pickedFolders)
      /\ \A w \in BackupFolders :
           importedMembers[w] = (IF w \in pickedFolders
                                  THEN Members(w) \cap pickedSites ELSE {}))
Inv_NoScope == phase # "applied" \/ HasSiteScope \/
    (finalSites = CurrentSites /\ finalFolders = CurrentFolders
     /\ importedFolders = {})
Inv_ScriptConsent == phase # "applied" \/
    activeScripts = (IF approveScripts
                     THEN pickedSites \cap pickedScripts \cap runScripts
                     ELSE {})
Inv_ExtensionConsent == phase # "applied" \/
    activeExtensions = (IF restoreExtensions
       THEN pickedSites \cap pickedExtensions \cap runExtensions ELSE {})
Inv_CookieScope == phase # "applied" \/
    importedCookies = pickedSites \cap pickedCookies
Inv_AppScope == phase # "applied" \/ appliedApp = restoreApp

\* Anti-vacuity: a chosen empty folder can arrive without any backup site;
\* a per-site script can also run after its three opt-ins and confirmation.
Reach_EmptyFolder == ~(phase = "applied" /\ pickedSites = {}
                        /\ pickedFolders = {11} /\ 11 \in finalFolders)
Reach_EnabledScript == ~(phase = "applied" /\ activeScripts = {1})
Reach_EmptyBackupFolder == ~(phase = "applied" /\ emptyBackup
    /\ pickedFolders = {11} /\ finalSites = CurrentSites
    /\ 11 \in finalFolders)
Reach_EmptyBackupNoScope == ~(phase = "applied" /\ emptyBackup
    /\ pickedFolders = {} /\ finalSites = CurrentSites
    /\ finalFolders = CurrentFolders)
=============================================================================
