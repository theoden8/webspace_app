----------------------- MODULE containers_disjoint -----------------------
(***************************************************************************)
(* TLAPS proof that per-site container isolation holds for ANY number of   *)
(* sites: Inv_Disjoint (the site → container binding is injective) for the  *)
(* good engine and all N. TLC checks N = 3; this is the unbounded backstop. *)
(*                                                                          *)
(* The inductive strengthening is Inv_Identity (each created site is bound  *)
(* to its own dedicated container, id = its index), which implies           *)
(* injectivity directly.                                                    *)
(***************************************************************************)
EXTENDS containers, TLAPS

ASSUME NAssumption == N \in Nat

GoodSpec == Init /\ [][GoodNext]_vars

\* Each created site is bound to its own dedicated container.
Inv_Identity == \A s \in created : cont[s] = s

IndInv == TypeOK /\ Inv_Identity

LEMMA InitInd == Init => IndInv
  BY DEF Init, IndInv, TypeOK, Inv_Identity

LEMMA StepInd == IndInv /\ [GoodNext]_vars => IndInv'
  <1> SUFFICES ASSUME IndInv, [GoodNext]_vars
               PROVE  IndInv'
    OBVIOUS
  <1> USE DEF IndInv, TypeOK, Inv_Identity
  <1>1. CASE GoodNext
    <2>1. PICK s \in Sites : Create(s)
      BY <1>1 DEF GoodNext
    <2> QED
      BY <2>1 DEF Create
  <1>2. CASE UNCHANGED vars
    BY <1>2 DEF vars
  <1> QED
    BY <1>1, <1>2

\* The identity binding implies the disjointness (injectivity) invariant.
LEMMA IdentityImpliesDisjoint == IndInv => Inv_Disjoint
  BY DEF IndInv, Inv_Identity, Inv_Disjoint

THEOREM Disjoint == GoodSpec => []Inv_Disjoint
  <1>1. Init => IndInv
    BY InitInd
  <1>2. IndInv /\ [GoodNext]_vars => IndInv'
    BY StepInd
  <1>3. IndInv => Inv_Disjoint
    BY IdentityImpliesDisjoint
  <1> QED
    BY <1>1, <1>2, <1>3, PTL DEF GoodSpec
=============================================================================
