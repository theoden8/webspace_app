------------------------- MODULE no_lost_update -------------------------
(***************************************************************************)
(* TLAPS proof that Inv_NoLostUpdate (every completed read-modify-write's   *)
(* key stays persisted -- no lost update) holds for the serialised store    *)
(* and ALL N, by the standard inductive-invariant argument. TLC checks only  *)
(* N = 3; this is the unbounded backstop. Companion of store_serial.tla.     *)
(*                                                                          *)
(* Directly inductive: the good engine's write is an atomic add, so both     *)
(* `store` and `done` grow monotonically by the same key and `done` stays a  *)
(* subset of `store`.                                                        *)
(***************************************************************************)
EXTENDS store_serial, TLAPS

ASSUME NAssumption == N \in Nat \ {0}

GoodSpec == Init /\ [][GoodNext]_vars

IndInv == TypeOK /\ Inv_NoLostUpdate

LEMMA InitInd == Init => IndInv
  BY NAssumption DEF Init, IndInv, TypeOK, Inv_NoLostUpdate, Ops

LEMMA StepInd == IndInv /\ [GoodNext]_vars => IndInv'
  <1> SUFFICES ASSUME IndInv, [GoodNext]_vars
               PROVE  IndInv'
    OBVIOUS
  <1> USE DEF IndInv, TypeOK, Inv_NoLostUpdate, Ops
  <1>1. CASE GoodNext
    <2>1. CASE \E o \in Ops : Rmw(o)
      BY <2>1 DEF Rmw
    <2> QED
      BY <1>1, <2>1 DEF GoodNext
  <1>2. CASE UNCHANGED vars
    BY <1>2 DEF vars
  <1> QED
    BY <1>1, <1>2

THEOREM Safety == GoodSpec => []Inv_NoLostUpdate
  <1>1. Init => IndInv
    BY InitInd
  <1>2. IndInv /\ [GoodNext]_vars => IndInv'
    BY StepInd
  <1>3. IndInv => Inv_NoLostUpdate
    BY DEF IndInv
  <1> QED
    BY <1>1, <1>2, <1>3, PTL DEF GoodSpec
=============================================================================
