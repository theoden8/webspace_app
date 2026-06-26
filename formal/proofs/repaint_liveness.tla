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
(* ENABLED (owed /\ ~frozen). With WF_vars(Nudge) the leadsto follows by the  *)
(* WF1 rule -- THEOREM Liveness below discharges it in full (the three WF1     *)
(* obligations + ExpandENABLED, closed by PTL after unfolding the fairness).  *)
(* So RepaintLiveness is machine-checked for ALL N, not just TLC's N = 3.     *)
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

(***************************************************************************)
(* The liveness property itself, for all N: a blank surface is always      *)
(* eventually repainted. Discharged via the WF1 rule. The three WF1         *)
(* obligations all hold from LiveP (blank /\ owed /\ ~frozen) alone; the    *)
(* backbone invariant is only needed to lift "blank" to LiveP at the end.   *)
(***************************************************************************)

LiveP == surface = "blank" /\ owed /\ ~frozen
LiveQ == surface = "painted"
GoodSpecWF == Init /\ [][GoodNext]_vars /\ WF_vars(Nudge)

THEOREM Liveness == GoodSpecWF => (surface = "blank" ~> surface = "painted")
  \* GoodSpecWF keeps the backbone invariant (drop the WF conjunct → GoodSpec).
  <1>1. GoodSpecWF => []Backbone
    <2>1. GoodSpecWF => GoodSpec
      BY PTL DEF GoodSpecWF, GoodSpec
    <2> QED
      BY <2>1, BackboneInvariant, PTL
  \* WF1 obligations; closed by PTL after DEF GoodSpecWF unfolds WF_vars(Nudge).
  \* The invariant <1>1 supplies the enabling condition (blank ⇒ owed ∧ ¬frozen).
  <1>2. (surface = "blank") /\ [GoodNext]_vars =>
          ((surface = "blank")' \/ (surface = "painted")')
    BY DEF GoodNext, Activate, Resume, ControllerAttach, Nudge, Back, Forward,
           LoadSite, Evict, Attach, vars
  <1>3. (surface = "blank") /\ <<GoodNext /\ Nudge>>_vars => (surface = "painted")'
    BY DEF Nudge, vars
  <1>4. ASSUME Backbone, surface = "blank"
        PROVE  ENABLED <<Nudge>>_vars
    BY <1>4, ExpandENABLED DEF Backbone, TypeOK, NoFreeze, BlankOwed, Nudge, vars
  <1> QED
    BY <1>1, <1>2, <1>3, <1>4, PTL DEF GoodSpecWF
=============================================================================
