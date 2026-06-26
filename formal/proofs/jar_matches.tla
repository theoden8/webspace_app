-------------------------- MODULE jar_matches --------------------------
(***************************************************************************)
(* TLAPS proof that Inv_JarMatchesVisible (the shared cookie jar always    *)
(* holds the visible site's cookies -- no cross-site leak) holds for the   *)
(* GOOD kernel and ALL N, by the standard inductive-invariant argument.    *)
(* TLC checks only N = 3; this is the unbounded backstop. Companion of     *)
(* current_loaded.tla.                                                      *)
(***************************************************************************)
EXTENDS kernel, TLAPS

ASSUME NAssumption == N \in Nat \ {0}

SpecGood == Init /\ [][GoodNext]_vars

IndInv == TypeOK /\ Inv_JarMatchesVisible

LEMMA InitEstablishes == Init => IndInv
  <1> SUFFICES ASSUME Init PROVE IndInv
    OBVIOUS
  <1>1. 1 \in Sites
    BY NAssumption DEF Sites
  <1>2. TypeOK
    BY <1>1 DEF Init, TypeOK
  <1>3. Inv_JarMatchesVisible
    BY DEF Init, Inv_JarMatchesVisible
  <1> QED
    BY <1>2, <1>3 DEF IndInv

LEMMA InductiveStep == IndInv /\ [GoodNext]_vars => IndInv'
  <1> SUFFICES ASSUME IndInv, [GoodNext]_vars
               PROVE  IndInv'
    OBVIOUS
  <1> USE DEF IndInv, TypeOK, Inv_JarMatchesVisible, Sites
  <1>1. CASE GoodNext
    <2>1. CASE \E s \in Sites : Activate(s)
      BY <2>1 DEF Activate, Attach
    <2>2. CASE Resume
      BY <2>2 DEF Resume, Attach
    <2>3. CASE ControllerAttach
      BY <2>3 DEF ControllerAttach, Attach
    <2>4. CASE Nudge
      BY <2>4 DEF Nudge
    <2>5. CASE Back
      BY <2>5 DEF Back, Attach
    <2>6. CASE Forward
      BY <2>6 DEF Forward, Attach
    <2>7. CASE \E s \in Sites : LoadSite(s)
      BY <2>7 DEF LoadSite
    <2>8. CASE \E s \in Sites : Evict(s)
      BY <2>8 DEF Evict
    <2> QED
      BY <1>1, <2>1, <2>2, <2>3, <2>4, <2>5, <2>6, <2>7, <2>8 DEF GoodNext
  <1>2. CASE UNCHANGED vars
    BY <1>2 DEF vars
  <1> QED
    BY <1>1, <1>2

THEOREM Safety == SpecGood => []Inv_JarMatchesVisible
  <1>1. Init => IndInv
    BY InitEstablishes
  <1>2. IndInv /\ [GoodNext]_vars => IndInv'
    BY InductiveStep
  <1>3. IndInv => Inv_JarMatchesVisible
    BY DEF IndInv
  <1> QED
    BY <1>1, <1>2, <1>3, PTL DEF SpecGood
=============================================================================
