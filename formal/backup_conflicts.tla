-------------------------- MODULE backup_conflicts -------------------------
(***************************************************************************)
(* Bounded identity collisions during import. Site 1 and folder 10 exist  *)
(* both here and in the backup; current site 3 and backup site 2 do not     *)
(* collide. Choosing site 1 replaces its row, but unchecked content of     *)
(* that row is kept from the current site. A partial import merges folder  *)
(* 10's members and retains its current title; a full import replaces it. *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANT Conflict \* "none" | "discardCurrent" | "overwriteContent" |
                  \* "replaceFolder" | "leakGlobal" | "reuseGlobalId"
CurrentSites == {1, 3}
BackupSites == {1, 2}
Contents == {"scripts", "cookies", "extensions", "globalChoices"}
CurrentMembers == {1, 3}
BackupMembers == {1, 2}

VARIABLES phase, pickedSites, pickedContent, pickedFolder, restoreGlobal,
          restoreExtensions,
          finalSites, contentOfOne, folderPresent, folderMembers,
          folderTitle, globalLibrary, globalId, activeGlobalOnRetained
vars == <<phase, pickedSites, pickedContent, pickedFolder, restoreGlobal,
          restoreExtensions,
          finalSites, contentOfOne, folderPresent, folderMembers,
          folderTitle, globalLibrary, globalId, activeGlobalOnRetained>>

HasScope == pickedSites # {} \/ pickedFolder
Partial == pickedSites # BackupSites
ExpectedSites == IF ~HasScope THEN CurrentSites
                 ELSE IF Partial THEN CurrentSites \cup pickedSites
                 ELSE pickedSites
ExpectedContent == [c \in Contents |->
    IF 1 \notin pickedSites THEN "current"
    ELSE IF c = "globalChoices" THEN
      (IF ~restoreGlobal THEN "current"
       ELSE IF c \in pickedContent THEN "backup" ELSE "empty")
    ELSE IF c = "extensions" /\ ~restoreExtensions THEN "current"
    ELSE IF c = "cookies" /\ c \in pickedContent THEN "secureCurrent+backup"
    ELSE IF c \in pickedContent THEN "backup" ELSE "current"]
ExpectedFolderPresent == ~HasScope \/ Partial \/ pickedFolder
ExpectedMembers == IF ~HasScope \/ ~pickedFolder THEN
    (IF ~HasScope \/ Partial THEN CurrentMembers ELSE {})
    ELSE IF Partial THEN CurrentMembers \cup (BackupMembers \cap pickedSites)
    ELSE BackupMembers \cap pickedSites
ExpectedTitle == IF ~HasScope \/ Partial THEN "current"
                 ELSE IF pickedFolder THEN "backup" ELSE "none"

Init ==
    /\ phase = "review"
    /\ pickedSites \in SUBSET BackupSites
    /\ pickedContent \in SUBSET Contents
    /\ pickedFolder \in BOOLEAN
    /\ restoreGlobal \in BOOLEAN
    /\ restoreExtensions \in BOOLEAN
    /\ finalSites = CurrentSites
    /\ contentOfOne = [c \in Contents |-> "current"]
    /\ folderPresent = TRUE
    /\ folderMembers = CurrentMembers
    /\ folderTitle = "current"
    /\ globalLibrary = "current"
    /\ globalId = "old"
    /\ activeGlobalOnRetained = TRUE

Apply ==
    /\ phase = "review"
    /\ phase' = "applied"
    /\ finalSites' = IF Conflict = "discardCurrent" /\ Partial /\ HasScope
                      THEN pickedSites ELSE ExpectedSites
    /\ contentOfOne' = IF Conflict = "overwriteContent" /\ 1 \in pickedSites
          THEN [c \in Contents |-> "backup"] ELSE ExpectedContent
    /\ folderPresent' = ExpectedFolderPresent
    /\ folderMembers' = IF Conflict = "replaceFolder" /\ Partial /\ pickedFolder
          THEN BackupMembers \cap pickedSites ELSE ExpectedMembers
    /\ folderTitle' = IF Conflict = "replaceFolder" /\ Partial /\ pickedFolder
          THEN "backup" ELSE ExpectedTitle
    /\ globalLibrary' = IF restoreGlobal THEN "backup" ELSE "current"
    /\ globalId' = IF Conflict = "reuseGlobalId" THEN "old"
                    ELSE IF restoreGlobal THEN "fresh" ELSE "old"
    /\ activeGlobalOnRetained' = IF Conflict = "leakGlobal" THEN TRUE
                                  ELSE ~restoreGlobal
    /\ UNCHANGED <<pickedSites, pickedContent, pickedFolder, restoreGlobal,
                   restoreExtensions>>

Next == Apply
Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ phase \in {"review", "applied"}
    /\ finalSites \subseteq CurrentSites \cup BackupSites
    /\ folderMembers \subseteq CurrentSites \cup BackupSites
    /\ folderTitle \in {"current", "backup", "none"}
    /\ globalLibrary \in {"current", "backup"}
    /\ globalId \in {"old", "fresh"}
    /\ activeGlobalOnRetained \in BOOLEAN

Inv_SiteCollision == phase # "applied" \/ finalSites = ExpectedSites
Inv_ContentCollision == phase # "applied" \/ contentOfOne = ExpectedContent
Inv_FolderCollision == phase # "applied" \/
    (folderPresent = ExpectedFolderPresent /\ folderMembers = ExpectedMembers
     /\ folderTitle = ExpectedTitle)
Inv_GlobalLibrary == phase # "applied" \/
    globalLibrary = (IF restoreGlobal THEN "backup" ELSE "current")
Inv_NoGlobalCollision == phase # "applied" \/
    activeGlobalOnRetained = ~restoreGlobal
Inv_FreshGlobalIdentity == phase # "applied" \/
    globalId = (IF restoreGlobal THEN "fresh" ELSE "old")

Reach_KeepCurrent == ~(phase = "applied" /\ pickedSites = {2}
    /\ 1 \in finalSites /\ contentOfOne["scripts"] = "current")
Reach_MergeFolder == ~(phase = "applied" /\ pickedSites = {1}
    /\ pickedFolder /\ folderMembers = {1, 3}
    /\ folderTitle = "current")
Reach_ReplaceAll == ~(phase = "applied" /\ pickedSites = BackupSites
    /\ pickedFolder /\ finalSites = BackupSites
    /\ folderMembers = BackupMembers /\ folderTitle = "backup")
Reach_GlobalDisabled == ~(phase = "applied" /\ restoreGlobal
    /\ 3 \in finalSites /\ ~activeGlobalOnRetained)
Reach_FreshGlobal == ~(phase = "applied" /\ restoreGlobal
    /\ globalId = "fresh")
=============================================================================
