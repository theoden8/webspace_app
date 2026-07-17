--------------------- MODULE proxy_failclosed_safe ---------------------
(***************************************************************************)
(* TLAPS proof that Inv_NoDirectWhenProxied (a proxied site never egresses   *)
(* directly) holds for the good engine and every reachable state. Directly   *)
(* inductive: a config change clears egress, and a good load sets egress to  *)
(* "proxied"/"none" whenever the type is proxied -- never "direct".          *)
(* Companion of proxy_failclosed.tla.                                        *)
(***************************************************************************)
EXTENDS proxy_failclosed, TLAPS

GoodSpec == Init /\ [][GoodNext]_vars

IndInv == TypeOK /\ Inv_NoDirectWhenProxied

LEMMA InitInd == Init => IndInv
  BY DEF Init, IndInv, TypeOK, Inv_NoDirectWhenProxied

LEMMA StepInd == IndInv /\ [GoodNext]_vars => IndInv'
  <1> SUFFICES ASSUME IndInv, [GoodNext]_vars
               PROVE  IndInv'
    OBVIOUS
  <1> USE DEF IndInv, TypeOK, Inv_NoDirectWhenProxied
  <1>1. CASE GoodNext
    <2>1. CASE SetDefault
      BY <2>1 DEF SetDefault
    <2>2. CASE \E b \in BOOLEAN : SetProxied(b)
      BY <2>2 DEF SetProxied
    <2>3. CASE Load
      BY <2>3 DEF Load
    <2> QED
      BY <1>1, <2>1, <2>2, <2>3 DEF GoodNext
  <1>2. CASE UNCHANGED vars
    BY <1>2 DEF vars
  <1> QED
    BY <1>1, <1>2

THEOREM Safety == GoodSpec => []Inv_NoDirectWhenProxied
  <1>1. Init => IndInv
    BY InitInd
  <1>2. IndInv /\ [GoodNext]_vars => IndInv'
    BY StepInd
  <1>3. IndInv => Inv_NoDirectWhenProxied
    BY DEF IndInv
  <1> QED
    BY <1>1, <1>2, <1>3, PTL DEF GoodSpec
=============================================================================
