------------------------- MODULE proxy_coherent -------------------------
(***************************************************************************)
(* TLAPS proof that proxy mutual exclusion holds for ANY number of sites    *)
(* and ANY proxy assignment: Inv_ProxyCoherent (every loaded site shares    *)
(* the active proxy) for the good engine and all N. TLC checks N = 3 with a  *)
(* fixed assignment; this is the unbounded backstop. The invariant is        *)
(* directly inductive — serialisation rebuilds a proxy-homogeneous loaded     *)
(* set on every activation.                                                   *)
(***************************************************************************)
EXTENDS proxy, TLAPS

ASSUME NAssumption == N \in Nat \ {0}

GoodSpec == Init /\ [][GoodNext]_vars

IndInv == TypeOK /\ Inv_ProxyCoherent

LEMMA InitInd == Init => IndInv
  BY NAssumption DEF Init, IndInv, TypeOK, Inv_ProxyCoherent, ActiveProxy, Sites

LEMMA StepInd == IndInv /\ [GoodNext]_vars => IndInv'
  <1> SUFFICES ASSUME IndInv, [GoodNext]_vars
               PROVE  IndInv'
    OBVIOUS
  <1> USE DEF IndInv, TypeOK, Inv_ProxyCoherent, ActiveProxy
  <1>1. CASE GoodNext
    <2>1. CASE \E s \in Sites : Activate(s)
      BY <2>1 DEF Activate
    <2>2. CASE \E s \in Sites : LoadCompatible(s)
      BY <2>2 DEF LoadCompatible
    <2>3. CASE \E s \in Sites : Unload(s)
      BY <2>3 DEF Unload
    <2> QED
      BY <1>1, <2>1, <2>2, <2>3 DEF GoodNext
  <1>2. CASE UNCHANGED vars
    BY <1>2 DEF vars
  <1> QED
    BY <1>1, <1>2

THEOREM Coherent == GoodSpec => []Inv_ProxyCoherent
  <1>1. Init => IndInv
    BY InitInd
  <1>2. IndInv /\ [GoodNext]_vars => IndInv'
    BY StepInd
  <1>3. IndInv => Inv_ProxyCoherent
    BY DEF IndInv
  <1> QED
    BY <1>1, <1>2, <1>3, PTL DEF GoodSpec
=============================================================================
