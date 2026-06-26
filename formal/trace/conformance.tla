-------------------------- MODULE conformance --------------------------
(***************************************************************************)
(* Trace conformance: validate a recorded LogService trace against the     *)
(* kernel's OBSERVABLE projection (navigation + lazy-loading +             *)
(* cookie-isolation). This is the model<->code bridge: model-checking      *)
(* proves the design is self-consistent; conformance proves the running    *)
(* code stayed inside it.                                                   *)
(*                                                                         *)
(* A trace is a sequence of records [act, cur, loaded, jar]. The kernel's  *)
(* hidden variables (surface/owed/frozen) are NOT observable from logs --  *)
(* that is the whole reason BUG-001 was invisible -- so this validates the *)
(* observable variables only. "surface" stands for any kernel transition   *)
(* with no observable effect (resume/back/forward/controllerAttach).       *)
(*                                                                         *)
(* Pure operators: a generated mc_<name>.tla EXTENDS this, defines Trace,  *)
(* and exposes Conforms/ObsOK as invariants for TLC.                       *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

\* One observable step from record p to record c must be a legal projected
\* kernel transition under the recorded action label.
StepOK(p, c) ==
  \/ c.act = "init"
  \/ /\ c.act = "activate"                       \* Activate(cur): loads cur, jar follows (capture-nuke-restore)
     /\ c.loaded = p.loaded \cup {c.cur}
     /\ c.jar = c.cur
  \/ /\ c.act = "load"                           \* LoadSite: background site added; cur/jar unchanged
     /\ c.cur = p.cur /\ c.jar = p.jar
     /\ p.loaded \subseteq c.loaded
     /\ Cardinality(c.loaded) = Cardinality(p.loaded) + 1
  \/ /\ c.act = "evict"                          \* Evict(non-current): site removed; cur stays loaded
     /\ c.cur = p.cur /\ c.jar = p.jar
     /\ c.loaded \subseteq p.loaded
     /\ c.cur \in c.loaded
  \/ /\ c.act = "surface"                        \* resume/back/forward/controllerAttach: no observable change
     /\ c.cur = p.cur /\ c.loaded = p.loaded /\ c.jar = p.jar

\* Every recorded step is a legal observable transition.
TraceConforms(T) == \A k \in 1..(Len(T) - 1) : StepOK(T[k], T[k + 1])

\* The kernel's observable safety invariants hold at every recorded state.
\* (Inv_CurrentLoaded and Inv_JarMatchesVisible, projected onto the trace.)
ObsInvariants(T) ==
  \A k \in 1..Len(T) :
     /\ T[k].cur \in T[k].loaded
     /\ T[k].jar = T[k].cur
=============================================================================
