---------------------- MODULE archive_transfer ----------------------
(***************************************************************************)
(* An archive's durable handoff to the regular library. The encrypted slot *)
(* and app-tier store are separate writes. A pending marker stays in the    *)
(* slot until the app-tier write lands; opening after a crash decides which *)
(* copy to keep. Two sites make partial removal reachable. The other slot  *)
(* stands for a second archive that this removal must never change.         *)
(* The slot's save that drops a written site's record can also fail in     *)
(* process (a locked keychain): the journal stays, the archive stays open, *)
(* and the next close or move settles it first (ARCH-011).                  *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Fault, HasCollection
Sites == {"a", "b"}
Collections == IF HasCollection THEN {"c"} ELSE {}
NoSite == "none"

VARIABLES slotSites, appSites, slotCollections, appCollections,
          pendingSite, pendingRemoval, opened, archiveView, slotLive,
          otherSlot, recovery, stalled

vars == <<slotSites, appSites, slotCollections, appCollections,
          pendingSite, pendingRemoval, opened, archiveView, slotLive,
          otherSlot, recovery, stalled>>

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
    /\ stalled \in BOOLEAN

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
    /\ stalled = FALSE

\* What settling a stalled transfer leaves: the written site's record goes.
SettledSlot == IF stalled THEN slotSites \ {pendingSite} ELSE slotSites

\* Whether an operation may start: none is in flight, or a stalled transfer
\* is there to settle first (before #1018 the code refused: refusePending).
MayStart == pendingSite = NoSite \/ (stalled /\ Fault # "refusePending")

BeginSite(s) ==
    /\ opened /\ slotLive /\ MayStart /\ ~pendingRemoval
    /\ s \in slotSites \ appSites
    /\ pendingSite' = s
    /\ slotSites' = IF Fault = "dropSite" THEN SettledSlot \ {s} ELSE SettledSlot
    /\ stalled' = FALSE
    /\ UNCHANGED <<appSites, slotCollections, appCollections,
                   pendingRemoval, opened, archiveView, slotLive, otherSlot,
                   recovery>>

WriteSite(s) ==
    /\ opened /\ pendingSite = s /\ s \notin appSites
    /\ appSites' = appSites \cup {s}
    /\ archiveView' = archiveView \ {s}
    /\ UNCHANGED <<slotSites, slotCollections, appCollections,
                   pendingSite, pendingRemoval, opened, slotLive, otherSlot,
                   recovery, stalled>>

FinishSite(s) ==
    /\ opened /\ pendingSite = s /\ s \in appSites /\ ~stalled
    /\ slotSites' = slotSites \ {s}
    /\ pendingSite' = NoSite
    /\ UNCHANGED <<appSites, slotCollections, appCollections,
                   pendingRemoval, opened, archiveView, slotLive, otherSlot,
                   recovery, stalled>>

\* The same save failing without a crash: the record and the journal stay,
\* the move-out ends, and the archive stays open.
StallSite(s) ==
    /\ opened /\ pendingSite = s /\ s \in appSites /\ ~stalled
    /\ stalled' = TRUE
    /\ UNCHANGED <<slotSites, appSites, slotCollections, appCollections,
                   pendingSite, pendingRemoval, opened, archiveView, slotLive,
                   otherSlot, recovery>>

BeginRemoval ==
    /\ opened /\ slotLive /\ SettledSlot = {} /\ MayStart
    /\ ~pendingRemoval /\ slotCollections # {}
    /\ pendingRemoval' = TRUE
    /\ slotCollections' =
         IF Fault = "dropCollection" THEN {} ELSE slotCollections
    /\ slotSites' = SettledSlot
    /\ pendingSite' = NoSite
    /\ stalled' = FALSE
    /\ UNCHANGED <<appSites, appCollections,
                   opened, archiveView, slotLive, otherSlot, recovery>>

WriteCollections ==
    /\ opened /\ pendingRemoval
    /\ ~(slotCollections \subseteq appCollections)
    /\ appCollections' = appCollections \cup slotCollections
    /\ UNCHANGED <<slotSites, appSites, slotCollections, pendingSite,
                   pendingRemoval, opened, archiveView, slotLive, otherSlot,
                   recovery, stalled>>

WipeRemoval ==
    /\ opened /\ pendingRemoval /\ slotSites = {}
    /\ slotCollections \subseteq appCollections
    /\ slotLive' = FALSE
    /\ slotCollections' = {}
    /\ pendingRemoval' = FALSE
    /\ opened' = FALSE
    /\ archiveView' = {}
    /\ otherSlot' = IF Fault = "touchOther" THEN FALSE ELSE otherSlot
    /\ UNCHANGED <<slotSites, appSites, appCollections, pendingSite, recovery,
                   stalled>>

WipeEmpty ==
    /\ opened /\ slotLive /\ slotSites = {} /\ slotCollections = {}
    /\ pendingSite = NoSite /\ ~pendingRemoval
    /\ slotLive' = FALSE
    /\ opened' = FALSE
    /\ archiveView' = {}
    /\ UNCHANGED <<slotSites, appSites, slotCollections, appCollections,
                   pendingSite, pendingRemoval, otherSlot, recovery, stalled>>

\* A close settles a stalled transfer first; the slot it seals may then be
\* empty, which the next open reclaims.
Close ==
    /\ opened /\ MayStart /\ ~pendingRemoval
    /\ stalled \/ slotSites \cup slotCollections # {}
    /\ slotSites' = SettledSlot
    /\ pendingSite' = NoSite
    /\ stalled' = FALSE
    /\ opened' = FALSE
    /\ archiveView' = {}
    /\ UNCHANGED <<appSites, slotCollections, appCollections,
                   pendingRemoval, slotLive, otherSlot, recovery>>

Crash ==
    /\ opened
    /\ opened' = FALSE
    /\ archiveView' = {}
    /\ stalled' = FALSE
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
                   pendingRemoval, slotLive, otherSlot, stalled>>

ReopenSiteUnwritten ==
    /\ ~opened /\ slotLive /\ pendingSite \in Sites \ appSites
    /\ pendingSite' = NoSite
    /\ archiveView' = slotSites
    /\ opened' = TRUE
    /\ recovery' = "siteBeforeWrite"
    /\ UNCHANGED <<slotSites, appSites, slotCollections, appCollections,
                   pendingRemoval, slotLive, otherSlot, stalled>>

ReopenRemovalWritten ==
    /\ ~opened /\ slotLive /\ pendingRemoval
    /\ slotCollections \subseteq appCollections
    /\ slotLive' = FALSE
    /\ slotCollections' = {}
    /\ pendingRemoval' = FALSE
    /\ recovery' = "removalAfterWrite"
    /\ UNCHANGED <<slotSites, appSites, appCollections, pendingSite,
                   opened, archiveView, otherSlot, stalled>>

ReopenRemovalUnwritten ==
    /\ ~opened /\ slotLive /\ pendingRemoval
    /\ ~(slotCollections \subseteq appCollections)
    /\ pendingRemoval' = FALSE
    /\ opened' = TRUE
    /\ archiveView' = slotSites
    /\ recovery' = "removalBeforeWrite"
    /\ UNCHANGED <<slotSites, appSites, slotCollections, appCollections,
                   pendingSite, slotLive, otherSlot, stalled>>

ReopenPlain ==
    /\ ~opened /\ slotLive /\ pendingSite = NoSite /\ ~pendingRemoval
    /\ slotSites \cup slotCollections # {}
    /\ opened' = TRUE
    /\ archiveView' = slotSites
    /\ UNCHANGED <<slotSites, appSites, slotCollections, appCollections,
                   pendingSite, pendingRemoval, slotLive, otherSlot, recovery, stalled>>

ReclaimOnOpen ==
    /\ ~opened /\ slotLive /\ pendingSite = NoSite /\ ~pendingRemoval
    /\ slotSites = {} /\ slotCollections = {}
    /\ slotLive' = FALSE
    /\ recovery' = "emptyReclaimed"
    /\ UNCHANGED <<slotSites, appSites, slotCollections, appCollections,
                   pendingSite, pendingRemoval, opened, archiveView, otherSlot, stalled>>

Next ==
    \/ \E s \in Sites : (BeginSite(s) \/ WriteSite(s) \/ FinishSite(s)
                         \/ StallSite(s))
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
\* An open archive no operation holds can still be sealed, or wiped when
\* nothing is left in it, so it never stays decrypted for the rest of a run.
\* Crash does not count: ending the run is what the stalled transfer forced.
OpenCanEnd ==
    (opened /\ (pendingSite = NoSite \/ stalled) /\ ~pendingRemoval)
        => ENABLED (Close \/ WipeEmpty)

Reach_Partial == ~(appSites # {} /\ slotSites # {} /\ pendingSite = NoSite)
Reach_SiteRecovery == ~(recovery = "siteAfterWrite")
Reach_SiteBeforeWrite == ~(recovery = "siteBeforeWrite")
Reach_RemovalRecovery == ~(recovery = "removalAfterWrite")
Reach_RemovalBeforeWrite == ~(recovery = "removalBeforeWrite")
Reach_Removed == ~(~slotLive /\ appSites = Sites
                    /\ appCollections = Collections)
Reach_EmptyWiped == ~(~slotLive /\ appSites = Sites /\ recovery = "none")
Reach_EmptyReclaimed == ~(recovery = "emptyReclaimed")
Reach_Stalled == ~stalled
=======================================================================
