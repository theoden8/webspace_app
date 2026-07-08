------------------------- MODULE switch_guarded -------------------------
(***************************************************************************)
(* TLAPS proof that Inv_NoWrongActivation (a guarded site switch never      *)
(* commits against a stale index) holds for the good orchestration and ALL  *)
(* reachable states, by the standard inductive-invariant argument. The      *)
(* model has no size parameter, so this is the deductive companion of        *)
(* switchguard.tla rather than an N-generalisation: it shows `wrong` is      *)
(* never set on any good path (every good action leaves it unchanged),       *)
(* whereas the "noguard" demonstrator latches it. Directly inductive.        *)
(***************************************************************************)
EXTENDS switchguard, TLAPS

GoodSpec == Init /\ [][GoodNext]_vars

IndInv == TypeOK /\ Inv_NoWrongActivation

LEMMA InitInd == Init => IndInv
  BY DEF Init, IndInv, TypeOK, Inv_NoWrongActivation

LEMMA StepInd == IndInv /\ [GoodNext]_vars => IndInv'
  <1> SUFFICES ASSUME IndInv, [GoodNext]_vars
               PROVE  IndInv'
    OBVIOUS
  <1> USE DEF IndInv, TypeOK, Inv_NoWrongActivation
  <1>1. CASE GoodNext
    \* Every good action leaves `wrong` unchanged and keeps `phase` in its
    \* enum, so both conjuncts of IndInv are preserved.
    <2>1. CASE StartSwitch
      BY <2>1 DEF StartSwitch
    <2>2. CASE Mutate
      BY <2>2 DEF Mutate
    <2>3. CASE CommitGood
      BY <2>3 DEF CommitGood
    <2>4. CASE Bail
      BY <2>4 DEF Bail
    <2>5. CASE Reset
      BY <2>5 DEF Reset
    <2> QED
      BY <1>1, <2>1, <2>2, <2>3, <2>4, <2>5 DEF GoodNext
  <1>2. CASE UNCHANGED vars
    BY <1>2 DEF vars
  <1> QED
    BY <1>1, <1>2

THEOREM Safety == GoodSpec => []Inv_NoWrongActivation
  <1>1. Init => IndInv
    BY InitInd
  <1>2. IndInv /\ [GoodNext]_vars => IndInv'
    BY StepInd
  <1>3. IndInv => Inv_NoWrongActivation
    BY DEF IndInv
  <1> QED
    BY <1>1, <1>2, <1>3, PTL DEF GoodSpec
=============================================================================
