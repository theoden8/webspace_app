------------------------ MODULE retention_safety ------------------------
(***************************************************************************)
(* TLAPS proof that the memory-pressure picker's retention guarantees hold  *)
(* for ANY number of views and ANY tier assignment, for all N:              *)
(*   Inv_CurrentKept  — the visible site is never evicted                   *)
(*   Inv_NotifLast    — a notification site is evicted only after every     *)
(*                      normal non-current site is gone                       *)
(*   Inv_WarmFirst    — an active view is evicted only after every warm tab *)
(*                      is gone (TAB-024)                                    *)
(* TLC checks N = 7; this is the unbounded backstop. Inv_NotifLast is        *)
(* inductive via the eviction guard (a notif site is dropped only when no    *)
(* normal non-current site remains) plus monotonicity (eviction only shrinks *)
(* the loaded set).                                                          *)
(***************************************************************************)
EXTENDS retention, TLAPS

GoodSpec == Init /\ [][GoodNext]_vars

IndInv == TypeOK /\ Inv_CurrentKept /\ Inv_NotifLast /\ Inv_WarmFirst

LEMMA InitInd == Init => IndInv
  BY RetentionTyping
     DEF Init, IndInv, TypeOK, Inv_CurrentKept, Inv_NotifLast, Inv_WarmFirst, Sites

LEMMA StepInd == IndInv /\ [GoodNext]_vars => IndInv'
  <1> SUFFICES ASSUME IndInv, [GoodNext]_vars
               PROVE  IndInv'
    OBVIOUS
  <1> USE DEF IndInv, TypeOK, Inv_CurrentKept, Inv_NotifLast, Inv_WarmFirst, Normal, Warm
  <1>1. CASE GoodNext
    <2>1. PICK s \in Sites : Evict(s)
      BY <1>1 DEF GoodNext
    <2>2. \A m \in Sites : isNotif[m] => warm[m] = "no"
      BY RetentionTyping
    <2>3. \A m \in Sites : Rank(m) \in 1..6
      BY RetentionTyping DEF Rank, WarmKinds
    <2>4. \A m \in Sites : warm[m] # "no" => Rank(m) \in 1..4
      BY RetentionTyping DEF Rank, WarmKinds
    <2>5. \A m \in Sites : warm[m] = "no" => Rank(m) \in 5..6
      BY RetentionTyping DEF Rank, WarmKinds
    <2>6. \A m \in Sites : warm[m] = "no" /\ ~isNotif[m] => Rank(m) = 5
      BY RetentionTyping DEF Rank, WarmKinds
    <2>7. \A m \in Sites : isNotif[m] => Rank(m) = 6
      BY <2>2, RetentionTyping DEF Rank, WarmKinds
    <2> QED
      BY <2>1, <2>3, <2>4, <2>5, <2>6, <2>7, RetentionTyping DEF Evict
  <1>2. CASE UNCHANGED vars
    BY <1>2 DEF vars
  <1> QED
    BY <1>1, <1>2

THEOREM Safety == GoodSpec => [](Inv_CurrentKept /\ Inv_NotifLast /\ Inv_WarmFirst)
  <1>1. Init => IndInv
    BY InitInd
  <1>2. IndInv /\ [GoodNext]_vars => IndInv'
    BY StepInd
  <1>3. IndInv => (Inv_CurrentKept /\ Inv_NotifLast /\ Inv_WarmFirst)
    BY DEF IndInv
  <1> QED
    BY <1>1, <1>2, <1>3, PTL DEF GoodSpec
=============================================================================
