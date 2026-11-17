-------------------------- MODULE activation_toast --------------------------
(* Compose snackbar ownership with activation.tla's real Next relation.
   PageKey is the site, active tab and tab set the widget boundary follows.
   The selected webspace is outside activation.tla; the standalone
   toast_page_boundary model covers that extra page-key component.

   A Dart activation step and its synchronous page rebuild are one action:
   when PageKey changes, ToastPageBoundary.follow clears the current and
   queued snackbars before the next frame. Show, timeout, and the reply of a
   suspended background-tab offer may occur in any order between those
   actions. Each toast action leaves the activation world unchanged.
   MaxToastMessages bounds only how many snackbar issues TLC explores. *)
EXTENDS activation

CONSTANTS ToastMistake, MaxToastMessages
ASSUME ToastMistake \in {"none", "keepVisible", "keepQueue", "staleOffer",
                         "ignoreTab", "ignoreVersion"}
ASSUME MaxToastMessages \in Nat \ {0}

NoPage == [site |-> 0, tab |-> 0, tabs |-> {}]
PageKey == [site |-> current,
            tab |-> IF current = 0 THEN 0 ELSE active[current],
            tabs |-> IF current = 0 THEN {} ELSE tabs[current]]
NoToast == [owner |-> NoPage, serial |-> 0]
NoPendingToast == [site |-> 0, tab |-> 0, version |-> 0]
NoOfferToast == [from |-> NoPendingToast, at |-> NoPendingToast]

VARIABLES toastShown, toastQueue, toastPending, toastIssued, toastOffer,
          toastDropped
toastVars == <<toastShown, toastQueue, toastPending, toastIssued, toastOffer,
               toastDropped>>
allVars == <<vars, toastVars>>

ToastInit ==
    /\ Init
    /\ toastShown = NoToast
    /\ toastQueue = <<>>
    /\ toastPending = NoPendingToast
    /\ toastIssued = 0
    /\ toastOffer = NoOfferToast
    /\ toastDropped = FALSE

(* Every step of activation.tla, including tab-list and current changes. *)
ActivationWithToast ==
    /\ Next
    /\ IF PageKey' # PageKey
       THEN /\ toastShown' = IF ToastMistake = "keepVisible"
                               THEN toastShown ELSE NoToast
            /\ toastQueue' = IF ToastMistake = "keepQueue"
                               THEN toastQueue ELSE <<>>
       ELSE UNCHANGED <<toastShown, toastQueue>>
    /\ UNCHANGED <<toastPending, toastIssued, toastOffer, toastDropped>>

ToastMessage(n) == [owner |-> PageKey, serial |-> n]

ToastShow ==
    /\ toastIssued < MaxToastMessages
    /\ LET m == ToastMessage(toastIssued + 1)
       IN /\ toastShown' = IF toastShown = NoToast /\ Len(toastQueue) = 0
                              THEN m ELSE toastShown
          /\ toastQueue' = IF toastShown = NoToast /\ Len(toastQueue) = 0
                              THEN toastQueue ELSE Append(toastQueue, m)
    /\ toastIssued' = toastIssued + 1
    /\ UNCHANGED <<vars, toastPending, toastOffer, toastDropped>>

ToastDismiss ==
    /\ toastShown # NoToast
    /\ toastShown' = IF Len(toastQueue) = 0
                     THEN NoToast ELSE Head(toastQueue)
    /\ toastQueue' = IF Len(toastQueue) = 0
                     THEN toastQueue ELSE Tail(toastQueue)
    /\ UNCHANGED <<vars, toastPending, toastIssued, toastOffer, toastDropped>>

(* TabOfferOrigin captures the site, active tab and activation version before
   its flow suspends. It may finish after any activation or toast event. *)
ToastRequestOffer ==
    /\ toastPending = NoPendingToast
    /\ toastPending' = [site |-> current,
                       tab |-> IF current = 0 THEN 0 ELSE active[current],
                       version |-> version]
    /\ UNCHANGED <<vars, toastShown, toastQueue, toastIssued, toastOffer,
                  toastDropped>>

ToastOfferAllowed ==
    /\ toastPending.site = current
    /\ toastPending.tab = (IF current = 0 THEN 0 ELSE active[current])
    /\ toastPending.version = version

ToastFinishOffer ==
    /\ toastPending # NoPendingToast
    /\ LET take == (ToastMistake = "staleOffer"
                    \/ (ToastMistake = "ignoreTab"
                        /\ toastPending.site = current
                        /\ toastPending.version = version)
                    \/ (ToastMistake = "ignoreVersion"
                        /\ toastPending.site = current
                        /\ toastPending.tab =
                           (IF current = 0 THEN 0 ELSE active[current]))
                    \/ ToastOfferAllowed)
                   /\ toastIssued < MaxToastMessages
           m == ToastMessage(toastIssued + 1)
       IN /\ toastShown' = IF take /\ toastShown = NoToast
                                    /\ Len(toastQueue) = 0
                            THEN m ELSE toastShown
          /\ toastQueue' = IF take /\ (toastShown # NoToast
                                       \/ Len(toastQueue) > 0)
                            THEN Append(toastQueue, m) ELSE toastQueue
          /\ toastIssued' = IF take THEN toastIssued + 1 ELSE toastIssued
          /\ toastOffer' = IF take
               THEN [from |-> toastPending,
                     at |-> [site |-> current,
                             tab |-> IF current = 0 THEN 0 ELSE active[current],
                             version |-> version]]
               ELSE toastOffer
          /\ toastDropped' = (toastDropped \/ ~take)
    /\ toastPending' = NoPendingToast
    /\ UNCHANGED vars

ToastNext == ActivationWithToast \/ ToastShow \/ ToastDismiss
             \/ ToastRequestOffer \/ ToastFinishOffer
ToastSpec == ToastInit /\ [][ToastNext]_allVars

Inv_ToastOwned ==
    /\ (toastShown = NoToast \/ toastShown.owner = PageKey)
    /\ (\A i \in 1..Len(toastQueue) : toastQueue[i].owner = PageKey)

Inv_ToastOffer == toastOffer = NoOfferToast \/
    (toastOffer.from.site = toastOffer.at.site
     /\ toastOffer.from.tab = toastOffer.at.tab
     /\ toastOffer.from.version = toastOffer.at.version)

Reach_ToastQueued == ~(Len(toastQueue) > 0)
Reach_ToastDropped == ~toastDropped
Reach_ToastSiteChange == ~(current # 1)
Reach_ToastTabChange == ~(active[1] # 1)
=============================================================================
