------------------------- MODULE activation_turns -------------------------
(***************************************************************************)
(* TLAPS proof that Inv_Places holds for any number of inputs: a flow at   *)
(* one of the jar's places holds the jar's turn, so no two flows are there *)
(* at once (ISO-003; BUG-032 was two restores interleaving there). The     *)
(* tables' actions, Inv_Places and their cases of this proof               *)
(* (TableStepInd) are printed from the step tables of SiteUnloadEngine     *)
(* and CookieIsolationEngine (activation_tables, activation_tables_proof,  *)
(* which formal/verify.sh prints), the invariant from each step's `holds`, *)
(* which the code asserts as a flow moves in. A table that lets a flow     *)
(* into a place without what it needs, or out of one without passing the   *)
(* turn on, fails TableStepInd; a new step is a new case there, with no    *)
(* edit here. TLC checks the same invariant at four inputs.                *)
(***************************************************************************)
EXTENDS activation_tables_proof

LEMMA InitInd == Init => IndInv
  BY DEF Init, WarmInit, ColdInit, IndInv, FlowsOK, Fresh, Inv_Places, NoFlow,
         Flows

LEMMA StepInd == Good /\ IndInv /\ [Next]_vars => IndInv'
  <1> SUFFICES ASSUME Good, IndInv, [Next]_vars
               PROVE  IndInv'
    OBVIOUS
  <1> USE DEF Good, IndInv, FlowsOK, Fresh, Inv_Places, NoFlow, Flows,
              site, sessions, turn, ghosts, Did
  <1>1. CASE InputStep
    <2>1. CASE \E f \in Flows : InputTableStep(f)
      BY <2>1, InputStepInd
    <2>2. CASE \E from, to \in Pos : Move(from, to)
      BY <2>2 DEF Move, Input, Starts
    <2>3. CASE \E s \in Sites : Login(s)
      BY <2>3 DEF Login, Input, Starts
    <2> QED
      BY <1>1, <2>1, <2>2, <2>3 DEF InputStep
  <1>2. CASE \E f \in Flows : FlowStep(f)
    <2> PICK f \in Flows : FlowStep(f)
      BY <1>2
    <2>1. CASE TableStep(f)
      BY <2>1, TableStepInd
    <2> QED
      BY <2>1 DEF FlowStep
  <1>3. CASE ClearJar
    BY <1>3 DEF ClearJar
  <1>5. CASE Done
    BY <1>5 DEF Done, vars
  <1>4. CASE UNCHANGED vars
    BY <1>4 DEF vars
  <1>6. CASE \E s \in Sites : ViewBuilt(s) \/ ViewGone(s)
    BY <1>6 DEF ViewBuilt, ViewGone
  <1>7. CASE \E s \in Sites : Frame(s)
    BY <1>7 DEF Frame
  <1>8. CASE \E s \in Sites : LetGo(s)
    BY <1>8 DEF LetGo
  <1>9. CASE \E s \in Sites : Reframe(s)
    BY <1>9 DEF Reframe
  <1> QED
    BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7, <1>8, <1>9 DEF Next

THEOREM Turns == ASSUME Good PROVE Spec => []Inv_Places
  <1>1. Init => IndInv
    BY InitInd
  <1>2. IndInv /\ [Next]_vars => IndInv'
    BY StepInd
  <1>3. IndInv => Inv_Places
    BY DEF IndInv
  <1> QED
    BY <1>1, <1>2, <1>3, PTL DEF Spec
=============================================================================
