---------------------- MODULE archive_transfer ----------------------
(***************************************************************************)
(* An archive's durable handoff to the regular library. The encrypted slot *)
(* and app-tier store are separate writes. A pending marker stays in the    *)
(* slot until the app-tier write lands; opening after a crash decides which *)
(* copy to keep. Two sites make partial removal reachable. The other slot  *)
(* stands for a second archive that this removal must never change.         *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Fault, HasCollection
Sites == {"a", "b"}
Collections == IF HasCollection THEN {"c"} ELSE {}
NoSite == "none"

VARIABLES slotSites, appSites, slotCollections, appCollections,
          pendingSite, pendingRemoval, opened, archiveView, slotLive,
          otherSlot, recovery

vars == <<slotSites, appSites, slotCollections, appCollections,
          pendingSite, pendingRemoval, opened, archiveView, slotLive,
          otherSlot, recovery>>

TypeOK ==
    /\ slotSites \subseteq Sites
    /\ appSites \subseteq Sites
    /\ slotCollections \subseteq Collections
    /\ appCollections \subseteq Collections
    /\ pendingSite \in Sites \cup {NoSite}
    /\ pendingRemoval \in BOOLEAN
    /\ opened \in BOOLEAN
    /\ archiveView \subseteq Sites
    /\ slotLive \in BOOLEAN
    /\ otherSlot \in BOOLEAN
    /\ recovery \in {"none", "siteBeforeWrite", "siteAfterWrite",
                     "removalBeforeWrite", "removalAfterWrite",
                     "emptyReclaimed"}

Init ==
    /\ slotSites = Sites
    /\ appSites = {}
    /\ slotCollections = Collections
    /\ appCollections = {}
    /\ pendingSite = NoSite
    /\ pendingRemoval = FALSE
    /\ opened = TRUE
    /\ archiveView = Sites
    /\ slotLive = TRUE
    /\ otherSlot = TRUE
    /\ recovery = "none"

BeginSite(s) ==
    /\ opened /\ slotLive /\ pendingSite = NoSite /\ ~pendingRemoval
    /\ s \in slotSites \ appSites
    /\ pendingSite' = s
    /\ slotSites' = IF Fault = "dropSite" THEN slotSites \ {s} ELSE slotSites
    /\ UNCHANGED <<appSites, slotCollections, appCollections,
                   pendingRemoval, opened, archiveView, slotLive, otherSlot,
                   recovery>>

WriteSite(s) ==
    /\ opened /\ pendingSite = s /\ s \notin appSites
    /\ appSites' = appSites \cup {s}
    /\ archiveView' = archiveView \ {s}
    /\ UNCHANGED <<slotSites, slotCollections, appCollections,
                   pendingSite, pendingRemoval, opened, slotLive, otherSlot,
                   recovery>>

FinishSite(s) ==
    /\ opened /\ pendingSite = s /\ s \in appSites
    /\ slotSites' = slotSites \ {s}
    /\ pendingSite' = NoSite
    /\ UNCHANGED <<appSites, slotCollections, appCollections,
                   pendingRemoval, opened, archiveView, slotLive, otherSlot,
                   recovery>>

BeginRemoval ==
    /\ opened /\ slotLive /\ slotSites = {} /\ pendingSite = NoSite
    /\ ~pendingRemoval /\ slotCollections # {}
    /\ pendingRemoval' = TRUE
    /\ slotCollections' =
         IF Fault = "dropCollection" THEN {} ELSE slotCollections
    /\ UNCHANGED <<slotSites, appSites, appCollections, pendingSite,
                   opened, archiveView, slotLive, otherSlot, recovery>>

WriteCollections ==
    /\ opened /\ pendingRemoval
    /\ ~(slotCollections \subseteq appCollections)
    /\ appCollections' = appCollections \cup slotCollections
    /\ UNCHANGED <<slotSites, appSites, slotCollections, pendingSite,
                   pendingRemoval, opened, archiveView, slotLive, otherSlot,
                   recovery>>

WipeRemoval ==
    /\ opened /\ pendingRemoval /\ slotSites = {}
    /\ slotCollections \subseteq appCollections
    /\ slotLive' = FALSE
    /\ slotCollections' = {}
    /\ pendingRemoval' = FALSE
    /\ opened' = FALSE
    /\ archiveView' = {}
    /\ otherSlot' = IF Fault = "touchOther" THEN FALSE ELSE otherSlot
    /\ UNCHANGED <<slotSites, appSites, appCollections, pendingSite, recovery>>

WipeEmpty ==
    /\ opened /\ slotLive /\ slotSites = {} /\ slotCollections = {}
    /\ pendingSite = NoSite /\ ~pendingRemoval
    /\ slotLive' = FALSE
    /\ opened' = FALSE
    /\ archiveView' = {}
    /\ UNCHANGED <<slotSites, appSites, slotCollections, appCollections,
                   pendingSite, pendingRemoval, otherSlot, recovery>>

Close ==
    /\ opened /\ pendingSite = NoSite /\ ~pendingRemoval
    /\ slotSites \cup slotCollections # {}
    /\ opened' = FALSE
    /\ archiveView' = {}
    /\ UNCHANGED <<slotSites, appSites, slotCollections, appCollections,
                   pendingSite, pendingRemoval, slotLive, otherSlot, recovery>>

Crash ==
    /\ opened
    /\ opened' = FALSE
    /\ archiveView' = {}
    /\ UNCHANGED <<slotSites, appSites, slotCollections, appCollections,
                   pendingSite, pendingRemoval, slotLive, otherSlot, recovery>>

ReopenSiteWritten ==
    /\ ~opened /\ slotLive /\ pendingSite \in appSites
    /\ slotSites' = slotSites \ {pendingSite}
    /\ archiveView' = IF Fault = "duplicateReplay"
                       THEN slotSites ELSE slotSites \ {pendingSite}
    /\ pendingSite' = NoSite
    /\ opened' = TRUE
    /\ recovery' = "siteAfterWrite"
    /\ UNCHANGED <<appSites, slotCollections, appCollections,
                   pendingRemoval, slotLive, otherSlot>>

ReopenSiteUnwritten ==
    /\ ~opened /\ slotLive /\ pendingSite \in Sites \ appSites
    /\ pendingSite' = NoSite
    /\ archiveView' = slotSites
    /\ opened' = TRUE
    /\ recovery' = "siteBeforeWrite"
    /\ UNCHANGED <<slotSites, appSites, slotCollections, appCollections,
                   pendingRemoval, slotLive, otherSlot>>

ReopenRemovalWritten ==
    /\ ~opened /\ slotLive /\ pendingRemoval
    /\ slotCollections \subseteq appCollections
    /\ slotLive' = FALSE
    /\ slotCollections' = {}
    /\ pendingRemoval' = FALSE
    /\ recovery' = "removalAfterWrite"
    /\ UNCHANGED <<slotSites, appSites, appCollections, pendingSite,
                   opened, archiveView, otherSlot>>

ReopenRemovalUnwritten ==
    /\ ~opened /\ slotLive /\ pendingRemoval
    /\ ~(slotCollections \subseteq appCollections)
    /\ pendingRemoval' = FALSE
    /\ opened' = TRUE
    /\ archiveView' = slotSites
    /\ recovery' = "removalBeforeWrite"
    /\ UNCHANGED <<slotSites, appSites, slotCollections, appCollections,
                   pendingSite, slotLive, otherSlot>>

ReopenPlain ==
    /\ ~opened /\ slotLive /\ pendingSite = NoSite /\ ~pendingRemoval
    /\ slotSites \cup slotCollections # {}
    /\ opened' = TRUE
    /\ archiveView' = slotSites
    /\ UNCHANGED <<slotSites, appSites, slotCollections, appCollections,
                   pendingSite, pendingRemoval, slotLive, otherSlot, recovery>>

ReclaimOnOpen ==
    /\ ~opened /\ slotLive /\ pendingSite = NoSite /\ ~pendingRemoval
    /\ slotSites = {} /\ slotCollections = {}
    /\ slotLive' = FALSE
    /\ recovery' = "emptyReclaimed"
    /\ UNCHANGED <<slotSites, appSites, slotCollections, appCollections,
                   pendingSite, pendingRemoval, opened, archiveView, otherSlot>>

Next ==
    \/ \E s \in Sites : (BeginSite(s) \/ WriteSite(s) \/ FinishSite(s))
    \/ BeginRemoval \/ WriteCollections \/ WipeRemoval \/ WipeEmpty
    \/ Close \/ Crash \/ ReopenSiteWritten \/ ReopenSiteUnwritten
    \/ ReopenRemovalWritten \/ ReopenRemovalUnwritten
    \/ ReopenPlain \/ ReclaimOnOpen

Spec == Init /\ [][Next]_vars

NoLostSites == Sites \subseteq slotSites \cup appSites
NoLostCollections == Collections \subseteq slotCollections \cup appCollections
NoDuplicateVisible == archiveView \cap appSites = {}
OtherArchiveIntact == otherSlot
NoOpenClearedSlot == opened => slotLive

ReachPartial == ~(appSites # {} /\ slotSites # {} /\ pendingSite = NoSite)
ReachSiteRecovery == ~(recovery = "siteAfterWrite")
ReachSiteBeforeWrite == ~(recovery = "siteBeforeWrite")
ReachRemovalRecovery == ~(recovery = "removalAfterWrite")
ReachRemovalBeforeWrite == ~(recovery = "removalBeforeWrite")
ReachRemoved == ~(~slotLive /\ appSites = Sites
                   /\ appCollections = Collections)
ReachEmptyWiped == ~(~slotLive /\ appSites = Sites /\ recovery = "none")
ReachEmptyReclaimed == ~(recovery = "emptyReclaimed")
=======================================================================
