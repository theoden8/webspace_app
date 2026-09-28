----------------------- MODULE containers_disjoint -----------------------
(***************************************************************************)
(* TLAPS proof that per-site container isolation holds for ANY number of   *)
(* sites: Inv_Disjoint (the site → container binding is injective) for the  *)
(* good engine and all N. TLC checks N = 3; this is the unbounded backstop. *)
(*                                                                          *)
(* The inductive strengthening is Inv_Identity (each created site is bound  *)
(* to its own dedicated container, id = its index), which implies           *)
(* injectivity directly.                                                    *)
(*                                                                          *)
(* Inv_PostureMatchesContainer (LIR-018: a hosted slot binds the container  *)
(* of the site whose posture and cookie mirror it applies) rides the same   *)
(* induction, strengthened to Inv_SlotRunsAsCreated: every slot runs as a   *)
(* created site and binds exactly that site's container.                    *)
(***************************************************************************)
EXTENDS containers, TLAPS

ASSUME NAssumption == N \in Nat

GoodSpec == Init /\ [][GoodNext]_vars

\* Each created site is bound to its own dedicated container.
Inv_Identity == \A s \in created : cont[s] = s

\* Each created site's slot runs as a created site and binds its container.
Inv_SlotRunsAsCreated ==
    \A s \in created : posture[s] \in created /\ bound[s] = posture[s]

IndInv == TypeOK /\ Inv_Identity /\ Inv_SlotRunsAsCreated

LEMMA InitInd == Init => IndInv
  BY DEF Init, IndInv, TypeOK, Inv_Identity, Inv_SlotRunsAsCreated

LEMMA StepInd == IndInv /\ [GoodNext]_vars => IndInv'
  <1> SUFFICES ASSUME IndInv, [GoodNext]_vars
               PROVE  IndInv'
    OBVIOUS
  <1> USE DEF IndInv, TypeOK, Inv_Identity, Inv_SlotRunsAsCreated
  <1>1. CASE GoodNext
    <2>1. CASE \E s \in Sites : Create(s)
      BY <2>1 DEF Create
    <2>2. CASE \E s, i \in Sites : Rebind(s, i)
      BY <2>2 DEF Rebind
    <2> QED
      BY <1>1, <2>1, <2>2 DEF GoodNext
  <1>2. CASE UNCHANGED vars
    BY <1>2 DEF vars
  <1> QED
    BY <1>1, <1>2

\* The identity binding implies the disjointness (injectivity) invariant.
LEMMA IdentityImpliesDisjoint == IndInv => Inv_Disjoint
  BY DEF IndInv, Inv_Identity, Inv_Disjoint

LEMMA SlotImpliesPosture == IndInv => Inv_PostureMatchesContainer
  BY DEF IndInv, Inv_Identity, Inv_SlotRunsAsCreated,
         Inv_PostureMatchesContainer

THEOREM Disjoint == GoodSpec => []Inv_Disjoint
  <1>1. Init => IndInv
    BY InitInd
  <1>2. IndInv /\ [GoodNext]_vars => IndInv'
    BY StepInd
  <1>3. IndInv => Inv_Disjoint
    BY IdentityImpliesDisjoint
  <1> QED
    BY <1>1, <1>2, <1>3, PTL DEF GoodSpec
THEOREM PostureMatchesContainer == GoodSpec => []Inv_PostureMatchesContainer
  <1>1. Init => IndInv
    BY InitInd
  <1>2. IndInv /\ [GoodNext]_vars => IndInv'
    BY StepInd
  <1>3. IndInv => Inv_PostureMatchesContainer
    BY SlotImpliesPosture
  <1> QED
    BY <1>1, <1>2, <1>3, PTL DEF GoodSpec
=============================================================================
