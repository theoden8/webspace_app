------------------------- MODULE current_loaded -------------------------
(***************************************************************************)
(* TLAPS proof that Inv_CurrentLoaded holds for the GOOD kernel and for    *)
(* ALL N -- unbounded, where TLC only checks N = 3.                        *)
(*                                                                         *)
(* Method: the standard inductive-invariant argument.                      *)
(*   IndInv == TypeOK /\ Inv_CurrentLoaded                                 *)
(*   (1) Init => IndInv                                                     *)
(*   (2) IndInv /\ [GoodNext]_vars => IndInv'                              *)
(*   (3) therefore SpecGood => []Inv_CurrentLoaded                         *)
(*                                                                         *)
(* Proves about GoodNext (the conflict-free composition; the demonstrators *)
(* are deliberately invariant-breaking and excluded). Check with:          *)
(*   tlapm -I <dir-of-kernel.tla> current_loaded.tla                       *)
(* Parse-check (no prover) with SANY:                                       *)
(*   java -DTLA-Library=<dir-of-kernel.tla> -cp tla2tools.jar \            *)
(*        tla2sany.SANY current_loaded.tla                                 *)
(***************************************************************************)
EXTENDS kernel, TLAPS

\* Site 1 must exist (Init puts currentIndex = 1, loaded = {1}); i.e. N >= 1.
ASSUME NAssumption == N \in Nat \ {0}

\* The good, conflict-free system (Conflict demonstrators excluded by design).
SpecGood == Init /\ [][GoodNext]_vars

\* Inductive strengthening: the target plus the type invariant it depends on.
IndInv == TypeOK /\ Inv_CurrentLoaded

LEMMA InitEstablishes == Init => IndInv
  <1> SUFFICES ASSUME Init PROVE IndInv
    OBVIOUS
  <1>1. 1 \in Sites
    BY NAssumption DEF Sites
  <1>2. TypeOK
    BY <1>1 DEF Init, TypeOK
  <1>3. Inv_CurrentLoaded
    BY DEF Init, Inv_CurrentLoaded
  <1> QED
    BY <1>2, <1>3 DEF IndInv

LEMMA InductiveStep == IndInv /\ [GoodNext]_vars => IndInv'
  <1> SUFFICES ASSUME IndInv, [GoodNext]_vars
               PROVE  IndInv'
    OBVIOUS
  <1> USE DEF IndInv, TypeOK, Inv_CurrentLoaded, Sites
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

THEOREM Safety == SpecGood => []Inv_CurrentLoaded
  <1>1. Init => IndInv
    BY InitEstablishes
  <1>2. IndInv /\ [GoodNext]_vars => IndInv'
    BY InductiveStep
  <1>3. IndInv => Inv_CurrentLoaded
    BY DEF IndInv
  <1> QED
    BY <1>1, <1>2, <1>3, PTL DEF SpecGood
=============================================================================
