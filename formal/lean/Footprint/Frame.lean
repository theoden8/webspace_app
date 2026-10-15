import Footprint.Semantics

/-!
# An action that writes nothing an invariant reads preserves it

So a TLAPS obligation `Inv /\ A => Inv'` for such an `A` need not be
written: the frame discharges it.
-/

namespace Footprint

variable {Var Val ι : Type}

theorem frame_preserves (a : Action Var Val) {I : State Var Val → Prop}
    {D : Var → Prop} (hI : DependsOn I D) (hWD : Disjoint a.W D)
    {s t : State Var Val} (hs : I s) (ht : a.step s t) : I t :=
  hI s t (a.agree_off hWD ht).symm hs

/-- An invariant over variables no action of `P` writes holds wherever the
initial condition gives it. -/
theorem holds_of_unwritten {sys : System ι Var Val} {P : ι → Prop}
    {I : State Var Val → Prop} {D : Var → Prop} (hI : DependsOn I D)
    (hW : ∀ i, P i → Disjoint (sys.act i).W D) (hinit : ∀ s, sys.init s → I s) :
    sys.Holds P I := by
  intro s hs
  induction hs with
  | init h => exact hinit _ h
  | step i _ hp hst ih => exact frame_preserves _ hI (hW i hp) ih hst

end Footprint
