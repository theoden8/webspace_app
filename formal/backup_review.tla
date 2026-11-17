--------------------------- MODULE backup_review ---------------------------
(***************************************************************************)
(* Review-screen selection transitions. Folder 10 has sites 1 and 2;     *)
(* folder 11 has sites 2 and 3; folder 12 is empty. A site shared by two   *)
(* selected folders must remain selected when only one folder is removed. *)
(* Individual site toggles can still remove it explicitly.                *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANT Conflict \* "none" | "dropShared"

Sites == {1, 2, 3}
Folders == {10, 11, 12}
Members(w) == CASE w = 10 -> {1, 2}
                [] w = 11 -> {2, 3}
                [] OTHER -> {}

VARIABLES selectedSites, selectedFolders, runScripts, runExtensions,
          lostShared, sharedKept
vars == <<selectedSites, selectedFolders, runScripts, runExtensions,
          lostShared, sharedKept>>
OtherMembers(w) == UNION {Members(f) : f \in selectedFolders \ {w}}

Init ==
    /\ selectedSites = {}
    /\ selectedFolders = {}
    /\ runScripts = {}
    /\ runExtensions = {}
    /\ lostShared = FALSE
    /\ sharedKept = FALSE

SelectFolder(w) ==
    /\ w \in Folders \ selectedFolders
    /\ selectedFolders' = selectedFolders \cup {w}
    /\ selectedSites' = selectedSites \cup Members(w)
    /\ UNCHANGED <<runScripts, runExtensions, lostShared, sharedKept>>

DeselectFolder(w) ==
    /\ w \in selectedFolders
    /\ selectedFolders' = selectedFolders \ {w}
    /\ selectedSites' = IF Conflict = "dropShared"
           THEN selectedSites \ Members(w)
           ELSE selectedSites \ (Members(w) \ OtherMembers(w))
    /\ runScripts' = runScripts \ (selectedSites \ selectedSites')
    /\ runExtensions' = runExtensions \ (selectedSites \ selectedSites')
    /\ lostShared' = (lostShared \/
           (((selectedSites \cap Members(w) \cap OtherMembers(w))
             \ selectedSites') # {}))
    /\ sharedKept' = (sharedKept \/
           ((selectedSites \cap Members(w) \cap OtherMembers(w)) # {}))

SelectSite(s) ==
    /\ s \in Sites \ selectedSites
    /\ selectedSites' = selectedSites \cup {s}
    /\ UNCHANGED <<selectedFolders, runScripts, runExtensions,
                   lostShared, sharedKept>>

DeselectSite(s) ==
    /\ s \in selectedSites
    /\ selectedSites' = selectedSites \ {s}
    /\ runScripts' = runScripts \ {s}
    /\ runExtensions' = runExtensions \ {s}
    /\ UNCHANGED <<selectedFolders, lostShared, sharedKept>>

SelectAll ==
    /\ selectedSites # Sites \/ selectedFolders # Folders
    /\ selectedSites' = Sites
    /\ selectedFolders' = Folders
    /\ UNCHANGED <<runScripts, runExtensions, lostShared, sharedKept>>

ClearAll ==
    /\ selectedSites # {} \/ selectedFolders # {}
    /\ selectedSites' = {}
    /\ selectedFolders' = {}
    /\ runScripts' = {}
    /\ runExtensions' = {}
    /\ UNCHANGED <<lostShared, sharedKept>>

ToggleScript(s) ==
    /\ s \in selectedSites
    /\ runScripts' = IF s \in runScripts THEN runScripts \ {s}
                      ELSE runScripts \cup {s}
    /\ UNCHANGED <<selectedSites, selectedFolders, runExtensions,
                   lostShared, sharedKept>>

ToggleExtension(s) ==
    /\ s \in selectedSites
    /\ runExtensions' = IF s \in runExtensions THEN runExtensions \ {s}
                         ELSE runExtensions \cup {s}
    /\ UNCHANGED <<selectedSites, selectedFolders, runScripts,
                   lostShared, sharedKept>>

Next ==
    \/ \E w \in Folders : SelectFolder(w) \/ DeselectFolder(w)
    \/ \E s \in Sites : SelectSite(s) \/ DeselectSite(s)
                         \/ ToggleScript(s) \/ ToggleExtension(s)
    \/ SelectAll
    \/ ClearAll
Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ selectedSites \subseteq Sites
    /\ selectedFolders \subseteq Folders
    /\ runScripts \subseteq selectedSites
    /\ runExtensions \subseteq selectedSites
    /\ lostShared \in BOOLEAN
    /\ sharedKept \in BOOLEAN

Inv_NoSharedSiteLost == ~lostShared
Inv_RunOnlySelected == runScripts \subseteq selectedSites
                       /\ runExtensions \subseteq selectedSites
Reach_SharedKept == ~sharedKept
Reach_EmptyFolder == ~(selectedFolders = {12} /\ selectedSites = {})
=============================================================================
