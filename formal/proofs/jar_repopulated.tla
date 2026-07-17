------------------------- MODULE jar_repopulated -------------------------
(***************************************************************************)
(* TLAPS proof that Inv_JarRepopulated (the shared cookie jar is never left  *)
(* empty when the legacy engine returns to rest) holds for the good engine   *)
(* and every reachable state. Directly inductive: only RestoreGood reaches   *)
(* the rest state, and it sets jarFull; Nuke/Supersede stay off-rest.        *)
(* Companion of jar_nonempty.tla.                                            *)
(***************************************************************************)
EXTENDS jar_nonempty, TLAPS

GoodSpec == Init /\ [][GoodNext]_vars

IndInv == TypeOK /\ Inv_JarRepopulated

LEMMA InitInd == Init => IndInv
  BY DEF Init, IndInv, TypeOK, Inv_JarRepopulated

LEMMA StepInd == IndInv /\ [GoodNext]_vars => IndInv'
  <1> SUFFICES ASSUME IndInv, [GoodNext]_vars
               PROVE  IndInv'
    OBVIOUS
  <1> USE DEF IndInv, TypeOK, Inv_JarRepopulated
  <1>1. CASE GoodNext
    <2>1. CASE Nuke
      BY <2>1 DEF Nuke
    <2>2. CASE Supersede
      BY <2>2 DEF Supersede
    <2>3. CASE RestoreGood
      BY <2>3 DEF RestoreGood
    <2> QED
      BY <1>1, <2>1, <2>2, <2>3 DEF GoodNext
  <1>2. CASE UNCHANGED vars
    BY <1>2 DEF vars
  <1> QED
    BY <1>1, <1>2

THEOREM Safety == GoodSpec => []Inv_JarRepopulated
  <1>1. Init => IndInv
    BY InitInd
  <1>2. IndInv /\ [GoodNext]_vars => IndInv'
    BY StepInd
  <1>3. IndInv => Inv_JarRepopulated
    BY DEF IndInv
  <1> QED
    BY <1>1, <1>2, <1>3, PTL DEF GoodSpec
=============================================================================
