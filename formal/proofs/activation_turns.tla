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

\* Each lemma names the definitions its step needs, so no obligation holds
\* Inv_Places's every place unless it reasons about them: proved with the
\* places in every case's hypotheses, InitInd and the Join case needed the
\* cache to land, and failed cold.
LEMMA InitInd == Init => IndInv
  <1> SUFFICES ASSUME Init PROVE IndInv
    OBVIOUS
  <1>1. fl = [g \in Flows |-> NoFlow] /\ inputs = 0
    BY DEF Init
  <1>2. NoFlow.pc = "done"
    BY DEF NoFlow
  <1> QED
    BY <1>1, <1>2 DEF IndInv, FlowsOK, Fresh, Inv_Places

\* A step that moves no flow and passes no turn keeps IndInv.
LEMMA KeepsTurns ==
    ASSUME IndInv, inputs' \in {inputs, inputs + 1}, fl' = fl,
           holder' = holder, dnsHolder' = dnsHolder
    PROVE  IndInv'
  <1>1. inputs' \in Nat
    BY DEF IndInv
  <1>2. FlowsOK'
    BY DEF IndInv, FlowsOK
  <1>3. Fresh'
    BY DEF IndInv, Fresh, Flows
  <1>4. Inv_Places'
    BY DEF IndInv, Inv_Places
  <1> QED
    BY <1>1, <1>2, <1>3, <1>4 DEF IndInv

LEMMA StepInd == Good /\ IndInv /\ [Next]_vars => IndInv'
  <1> SUFFICES ASSUME Good, IndInv, [Next]_vars
               PROVE  IndInv'
    OBVIOUS
  <1>1. CASE InputStep
    <2>1. CASE \E f \in Flows : InputTableStep(f)
      BY <2>1, InputStepInd
    <2>2. CASE \E from, to \in Pos : Move(from, to)
      <3> PICK from, to \in Pos : Move(from, to)
        BY <2>2
      <3>1. inputs' = inputs + 1 /\ fl' = fl /\ holder' = holder
            /\ dnsHolder' = dnsHolder
        BY DEF Move, Input, Starts, turn
      <3> QED
        BY <3>1, KeepsTurns
    <2>3. CASE \E s \in Sites : Login(s)
      <3> PICK s \in Sites : Login(s)
        BY <2>3
      <3>1. inputs' = inputs + 1 /\ fl' = fl /\ holder' = holder
            /\ dnsHolder' = dnsHolder
        BY DEF Login, Input, Starts, turn
      <3> QED
        BY <3>1, KeepsTurns
    <2>4. CASE \E s \in Sites : Join(s)
      <3> PICK s \in Sites : Join(s)
        BY <2>4
      <3>1. inputs' = inputs + 1 /\ fl' = fl /\ holder' = holder
            /\ dnsHolder' = dnsHolder
        BY DEF Join, Input, Starts, turn
      <3> QED
        BY <3>1, KeepsTurns
    <2> QED
      BY <1>1, <2>1, <2>2, <2>3, <2>4 DEF InputStep
  <1>2. CASE \E f \in Flows : FlowStep(f)
    <2> PICK f \in Flows : FlowStep(f)
      BY <1>2
    <2>1. CASE TableStep(f)
      BY <2>1, TableStepInd
    <2> QED
      BY <2>1 DEF FlowStep
  <1>3. CASE ClearJar
    <2>1. inputs' = inputs /\ fl' = fl /\ holder' = holder
          /\ dnsHolder' = dnsHolder
      BY <1>3 DEF ClearJar
    <2> QED
      BY <2>1, KeepsTurns
  <1>5. CASE Done
    <2>1. inputs' = inputs /\ fl' = fl /\ holder' = holder
          /\ dnsHolder' = dnsHolder
      BY <1>5 DEF Done, vars, turn
    <2> QED
      BY <2>1, KeepsTurns
  <1>4. CASE UNCHANGED vars
    <2>1. inputs' = inputs /\ fl' = fl /\ holder' = holder
          /\ dnsHolder' = dnsHolder
      BY <1>4 DEF vars, turn
    <2> QED
      BY <2>1, KeepsTurns
  <1>6. CASE \E s \in Sites : ViewBuilt(s) \/ ViewGone(s)
    <2> PICK s \in Sites : ViewBuilt(s) \/ ViewGone(s)
      BY <1>6
    <2>1. inputs' = inputs /\ fl' = fl /\ holder' = holder
          /\ dnsHolder' = dnsHolder
      BY DEF ViewBuilt, ViewGone, turn
    <2> QED
      BY <2>1, KeepsTurns
  <1>7. CASE \E s \in Sites : Frame(s)
    <2> PICK s \in Sites : Frame(s)
      BY <1>7
    <2>1. inputs' = inputs /\ fl' = fl /\ holder' = holder
          /\ dnsHolder' = dnsHolder
      BY DEF Frame, turn
    <2> QED
      BY <2>1, KeepsTurns
  <1>8. CASE \E s \in Sites : LetGo(s)
    <2> PICK s \in Sites : LetGo(s)
      BY <1>8
    <2>1. inputs' = inputs /\ fl' = fl /\ holder' = holder
          /\ dnsHolder' = dnsHolder
      BY DEF LetGo, turn
    <2> QED
      BY <2>1, KeepsTurns
  <1>9. CASE \E s \in Sites : Reframe(s)
    <2> PICK s \in Sites : Reframe(s)
      BY <1>9
    <2>1. inputs' = inputs /\ fl' = fl /\ holder' = holder
          /\ dnsHolder' = dnsHolder
      BY DEF Reframe, turn
    <2> QED
      BY <2>1, KeepsTurns
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
