------------------------ MODULE retention_safety ------------------------
(***************************************************************************)
(* TLAPS proof that the memory-pressure picker's retention guarantees hold  *)
(* for ANY number of sites and ANY tier assignment, for all N:              *)
(*   Inv_CurrentKept  — the visible site is never evicted                   *)
(*   Inv_NotifLast    — a notification site is evicted only after every     *)
(*                      normal non-current site is gone                       *)
(* TLC checks N = 3; this is the unbounded backstop. Inv_NotifLast is        *)
(* inductive via the eviction guard (a notif site is dropped only when no    *)
(* normal non-current site remains) plus monotonicity (eviction only shrinks *)
(* the loaded set).                                                          *)
(***************************************************************************)
EXTENDS retention, TLAPS

GoodSpec == Init /\ [][GoodNext]_vars

IndInv == TypeOK /\ Inv_CurrentKept /\ Inv_NotifLast

LEMMA InitInd == Init => IndInv
  BY RetentionTyping
     DEF Init, IndInv, TypeOK, Inv_CurrentKept, Inv_NotifLast, Sites

LEMMA StepInd == IndInv /\ [GoodNext]_vars => IndInv'
  <1> SUFFICES ASSUME IndInv, [GoodNext]_vars
               PROVE  IndInv'
    OBVIOUS
  <1> USE DEF IndInv, TypeOK, Inv_CurrentKept, Inv_NotifLast, Normal
  <1>1. CASE GoodNext
    <2>1. PICK s \in Sites : Evict(s)
      BY <1>1 DEF GoodNext
    <2> QED
      BY <2>1 DEF Evict
  <1>2. CASE UNCHANGED vars
    BY <1>2 DEF vars
  <1> QED
    BY <1>1, <1>2

THEOREM Safety == GoodSpec => [](Inv_CurrentKept /\ Inv_NotifLast)
  <1>1. Init => IndInv
    BY InitInd
  <1>2. IndInv /\ [GoodNext]_vars => IndInv'
    BY StepInd
  <1>3. IndInv => (Inv_CurrentKept /\ Inv_NotifLast)
    BY DEF IndInv
  <1> QED
    BY <1>1, <1>2, <1>3, PTL DEF GoodSpec
=============================================================================
