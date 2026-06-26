------------------------ MODULE repaint_liveness ------------------------
(***************************************************************************)
(* The safety backbone of BUG-001's liveness property, proved for the GOOD *)
(* kernel and ALL N. RepaintLiveness == surface="blank" ~> surface="painted"*)
(* rests on two invariants:                                                 *)
(*                                                                         *)
(*   NoFreeze   == ~frozen                 (the repaint chokepoint is never *)
(*                                          wedged in the conflict-free      *)
(*                                          system -- only BackBypass freezes)*)
(*   BlankOwed  == (surface="blank") <=> owed   (a blank surface always has  *)
(*                                          a repaint owed, and vice versa)  *)
(*                                                                         *)
(* Together NoFreeze /\ BlankOwed give: whenever surface="blank", Nudge is   *)
(* ENABLED (owed /\ ~frozen) -- this is THEOREM BlankEnablesNudge below,      *)
(* proved for all N. The full leadsto then follows from this plus            *)
(* WF_vars(Nudge) by the WF1 rule. That last step needs ENABLED-expansion     *)
(* temporal reasoning (TLAPS's PTL backend is propositional only), so it is   *)
(* left as the documented remainder; everything up to BlankEnablesNudge is    *)
(* machine-checked here.                                                      *)
(***************************************************************************)
EXTENDS kernel, TLAPS

ASSUME NAssumption == N \in Nat \ {0}

GoodSpec == Init /\ [][GoodNext]_vars

NoFreeze  == ~frozen
BlankOwed == (surface = "blank") <=> owed

Backbone == TypeOK /\ NoFreeze /\ BlankOwed

LEMMA InitBackbone == Init => Backbone
  <1> SUFFICES ASSUME Init PROVE Backbone
    OBVIOUS
  <1>1. 1 \in Sites
    BY NAssumption DEF Sites
  <1>2. TypeOK
    BY <1>1 DEF Init, TypeOK
  <1>3. NoFreeze /\ BlankOwed
    BY DEF Init, NoFreeze, BlankOwed
  <1> QED
    BY <1>2, <1>3 DEF Backbone

LEMMA StepBackbone == Backbone /\ [GoodNext]_vars => Backbone'
  <1> SUFFICES ASSUME Backbone, [GoodNext]_vars
               PROVE  Backbone'
    OBVIOUS
  <1> USE DEF Backbone, TypeOK, NoFreeze, BlankOwed, Sites
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

THEOREM BackboneInvariant == GoodSpec => []Backbone
  <1>1. Init => Backbone
    BY InitBackbone
  <1>2. Backbone /\ [GoodNext]_vars => Backbone'
    BY StepBackbone
  <1> QED
    BY <1>1, <1>2, PTL DEF GoodSpec

\* Corollary used by the liveness step: a blank surface enables Nudge.
THEOREM BlankEnablesNudge == GoodSpec => [](surface = "blank" => (owed /\ ~frozen))
  <1>1. Backbone => (surface = "blank" => (owed /\ ~frozen))
    BY DEF Backbone, NoFreeze, BlankOwed
  <1> QED
    BY BackboneInvariant, <1>1, PTL
=============================================================================
