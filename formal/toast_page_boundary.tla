---------------------- MODULE toast_page_boundary ----------------------
(* A snackbar belongs to the page that issued it. The page key abstracts the
   site, active tab, webspace scope and tab list watched by
   ToastPageBoundary.follow. A1Wide is the same site and active tab with a
   different scope or tab list. A synchronous Follow clears both the current
   snackbar and Flutter's queue before the next frame can draw.

   A background-tab confirmation may finish after its tab flow suspended.
   TabOfferOrigin checks site identity, active tab and activation version at
   that point. This model lets a request, page changes and its reply occur in
   every order. Versions change on site switches, as SiteRuntime does. The
   tab offer may still be relevant after a scope or tab-list change on the
   same site and tab; its message is issued on the page then current.

   This is a safety model of the page snackbar and that one delayed offer.
   Other app-wide toasts and Flutter's animation timing are outside it. *)
EXTENDS Naturals, Sequences

CONSTANT Mode
ASSUME Mode \in {"correct", "keepVisible", "keepQueue", "staleOffer",
                "ignoreTab", "ignoreVersion"}
Pages == {"A1", "A2", "A1Wide", "B1"}
None == "none"
NoMessage == [owner |-> None, serial |-> 0]
NoPending == [page |-> None, version |-> 0]
NoOffer == [from |-> None, at |-> None,
            requestedVersion |-> 0, currentVersion |-> 0]
MaxMessages == 3
MaxSwitches == 3

Site(p) == IF p = "B1" THEN "B" ELSE "A"
Tab(p) == IF p = "A2" THEN "2" ELSE "1"

VARIABLES page, version, switches, visible, queued, pending, issued,
          lastOffer, dropped
vars == <<page, version, switches, visible, queued, pending, issued,
          lastOffer, dropped>>

Message(p, n) == [owner |-> p, serial |-> n]
Messages == [owner : Pages, serial : 1..MaxMessages]

TypeOK ==
    /\ page \in Pages
    /\ version \in 0..MaxSwitches
    /\ switches \in 0..MaxSwitches
    /\ visible \in ({NoMessage} \cup Messages)
    /\ queued \in Seq(Messages)
    /\ pending \in ({NoPending} \cup
                   [page : Pages, version : 0..MaxSwitches])
    /\ issued \in 0..MaxMessages
    /\ lastOffer \in ({NoOffer} \cup
                     [from : Pages, at : Pages,
                      requestedVersion : 0..MaxSwitches,
                      currentVersion : 0..MaxSwitches])
    /\ dropped \in BOOLEAN

Init ==
    /\ page = "A1"
    /\ version = 0
    /\ switches = 0
    /\ visible = NoMessage
    /\ queued = <<>>
    /\ pending = NoPending
    /\ issued = 0
    /\ lastOffer = NoOffer
    /\ dropped = FALSE

(* showSnackBar displays immediately or waits behind the current one. *)
Show ==
    /\ issued < MaxMessages
    /\ LET m == Message(page, issued + 1)
       IN /\ visible' = IF visible = NoMessage /\ Len(queued) = 0
                         THEN m ELSE visible
          /\ queued' = IF visible = NoMessage /\ Len(queued) = 0
                        THEN queued ELSE Append(queued, m)
    /\ issued' = issued + 1
    /\ UNCHANGED <<page, version, switches, pending, lastOffer, dropped>>

(* A timeout or a user action advances Flutter's snackbar queue. *)
Dismiss ==
    /\ visible # NoMessage
    /\ visible' = IF Len(queued) = 0 THEN NoMessage ELSE Head(queued)
    /\ queued' = IF Len(queued) = 0 THEN queued ELSE Tail(queued)
    /\ UNCHANGED <<page, version, switches, pending, issued, lastOffer, dropped>>

(* follow() runs with rebuild after the page fingerprint changes. The three
   bad modes each remove one protection so the invariant must reject them. *)
Follow(q) ==
    /\ q \in Pages
    /\ q # page
    /\ switches < MaxSwitches
    /\ page' = q
    /\ version' = IF Site(q) # Site(page) THEN version + 1 ELSE version
    /\ switches' = switches + 1
    /\ visible' = IF Mode = "keepVisible" THEN visible ELSE NoMessage
    /\ queued' = IF Mode = "keepQueue" THEN queued ELSE <<>>
    /\ UNCHANGED <<pending, issued, lastOffer, dropped>>

RequestOffer ==
    /\ pending = NoPending
    /\ pending' = [page |-> page, version |-> version]
    /\ UNCHANGED <<page, switches, visible, queued, issued, lastOffer,
                  dropped, version>>

OfferAllowed ==
    /\ Site(pending.page) = Site(page)
    /\ Tab(pending.page) = Tab(page)
    /\ pending.version = version

(* The bad offer modes omit all or one TabOfferOrigin.stillVisible check. A
   dropped reply records a witness that an old confirmation was suppressed. *)
FinishOffer ==
    /\ pending # NoPending
    /\ LET take == (Mode = "staleOffer"
                     \/ (Mode = "ignoreTab"
                         /\ Site(pending.page) = Site(page)
                         /\ pending.version = version)
                     \/ (Mode = "ignoreVersion"
                         /\ Site(pending.page) = Site(page)
                         /\ Tab(pending.page) = Tab(page))
                     \/ OfferAllowed)
                    /\ issued < MaxMessages
           m == Message(page, issued + 1)
       IN /\ visible' = IF take /\ visible = NoMessage /\ Len(queued) = 0
                         THEN m ELSE visible
          /\ queued' = IF take /\ (visible # NoMessage \/ Len(queued) > 0)
                        THEN Append(queued, m) ELSE queued
          /\ issued' = IF take THEN issued + 1 ELSE issued
          /\ lastOffer' = IF take
               THEN [from |-> pending.page, at |-> page,
                     requestedVersion |-> pending.version,
                     currentVersion |-> version]
               ELSE lastOffer
          /\ dropped' = (dropped \/ ~take)
    /\ pending' = NoPending
    /\ UNCHANGED <<page, version, switches>>

Next == Show \/ Dismiss \/ RequestOffer \/ FinishOffer
        \/ (\E q \in Pages : Follow(q))
Spec == Init /\ [][Next]_vars

InvOwned ==
    /\ (visible = NoMessage \/ visible.owner = page)
    /\ (\A i \in 1..Len(queued) : queued[i].owner = page)

InvOffer == lastOffer = NoOffer \/
    (Site(lastOffer.from) = Site(lastOffer.at)
     /\ Tab(lastOffer.from) = Tab(lastOffer.at)
     /\ lastOffer.requestedVersion = lastOffer.currentVersion)

Reach_Queued == ~(Len(queued) > 0)
Reach_Dropped == ~dropped
=============================================================================
