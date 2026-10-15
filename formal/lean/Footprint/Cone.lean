import Footprint.Semantics

/-!
# An invariant is checked in full by the actions of its cone

The cone of an invariant over `D`, among the actions `P` of a system, is the
least set of them closed under: an action that writes a variable of `D` is in
it, and so is one that writes a variable an action in it reads. Every action
outside writes nothing the invariant or the cone reads, so it changes nothing
they can see: the invariant holds in every state the whole system reaches iff
it holds in every state the cone reaches, from the same initial condition.

Side conditions, all in the hypotheses: every action is well formed over its
footprint (`Action`; a footprint may over-approximate), with the guard's reads
in `R` (an action whose enabledness reads a variable left out of `R` breaks the
theorem: a removed writer could have been what enabled it); `I` reads only `D`
(`DependsOn`); the cone is closed over every action of the system, not only
those a world takes; and `I` is a state invariant (a liveness property is not
kept: removing actions removes the behaviors it may need). Nothing is asked
of `init`, of finiteness, or of determinism.
-/

namespace Footprint

variable {Var Val ι : Type}

namespace System

/-- The cone of `D` among the actions `P`. -/
inductive InCone (sys : System ι Var Val) (P : ι → Prop) (D : Var → Prop) :
    ι → Prop
  | writesD {i v} : P i → (sys.act i).W v → D v → InCone sys P D i
  | writesRead {i j v} : P i → InCone sys P D j → (sys.act i).W v →
      (sys.act j).R v → InCone sys P D i

/-- What the invariant and its cone read. -/
def Seen (sys : System ι Var Val) (P : ι → Prop) (D : Var → Prop) (v : Var) :
    Prop :=
  D v ∨ ∃ j, sys.InCone P D j ∧ (sys.act j).R v

theorem InCone.mem {sys : System ι Var Val} {P D i} (h : sys.InCone P D i) : P i := by
  cases h with
  | writesD hp _ _ => exact hp
  | writesRead hp _ _ _ => exact hp

/-- An action of `P` outside the cone writes nothing it sees. -/
theorem outside_unseen {sys : System ι Var Val} {P D} {i : ι} (hp : P i)
    (hi : ¬ sys.InCone P D i) : Disjoint (sys.act i).W (sys.Seen P D) := by
  rintro v hw (hd | ⟨j, hj, hr⟩)
  · exact hi (.writesD hp hw hd)
  · exact hi (.writesRead hp hj hw hr)

/-- Every state `P` reaches has a shadow the cone reaches that agrees with
it on everything the cone and the invariant see. -/
theorem shadow (sys : System ι Var Val) (P : ι → Prop) (D : Var → Prop)
    {s} (hs : sys.Reach P s) :
    ∃ s', sys.Reach (sys.InCone P D) s' ∧ Agree (sys.Seen P D) s s' := by
  induction hs with
  | init h => exact ⟨_, .init h, fun _ _ => rfl⟩
  | @step s t i _ hp hst ih =>
    obtain ⟨s', hs', hag⟩ := ih
    by_cases hi : sys.InCone P D i
    · have hR : Agree (sys.act i).R s s' :=
        hag.mono (fun v hv => Or.inr ⟨i, hi, hv⟩)
      obtain ⟨t', ht', hw⟩ := (sys.act i).locality hR hst
      refine ⟨t', .step i hs' hi ht', fun v hv => ?_⟩
      by_cases hW : (sys.act i).W v
      · rcases hw v hW with h | ⟨h₁, h₂⟩
        · exact h
        · rw [h₁, h₂]; exact hag v hv
      · rw [(sys.act i).frame hst v hW, (sys.act i).frame ht' v hW]
        exact hag v hv
    · exact ⟨s', hs', ((sys.act i).agree_off (outside_unseen hp hi) hst).trans hag⟩

end System

/-- `cone`: an invariant over `D` holds in every state the actions `P` reach
iff it holds in every state the cone of `D` among them reaches. -/
theorem cone (sys : System ι Var Val) (P : ι → Prop) {I : State Var Val → Prop}
    {D : Var → Prop} (hI : DependsOn I D) :
    sys.Holds P I ↔ sys.Holds (sys.InCone P D) I := by
  constructor
  · exact System.Holds.mono (fun _ h => h.mem)
  · intro h s hs
    obtain ⟨s', hs', hag⟩ := System.shadow sys P D hs
    exact hI s' s (hag.mono (fun _ hv => Or.inl hv)).symm (h s' hs')

namespace System

/-- A set of actions closed as the cone is contains it, so a closed set
found any way (a fixpoint, a guess) bounds the cone. -/
theorem InCone.sub {sys : System ι Var Val} {P D} {C : ι → Prop}
    (hC : ∀ i, P i → ∀ v, (sys.act i).W v →
      (D v ∨ ∃ j, C j ∧ (sys.act j).R v) → C i) {i} (h : sys.InCone P D i) : C i := by
  induction h with
  | writesD hp hw hd => exact hC _ hp _ hw (Or.inl hd)
  | writesRead hp _ hw hr ih => exact hC _ hp _ hw (Or.inr ⟨_, ih, hr⟩)

/-- Actions never enabled reach nothing: the system reaches what it reaches
without them. -/
theorem Reach.drop_disabled {sys : System ι Var Val} {P Q : ι → Prop}
    (hQ : ∀ i, P i → ¬ Q i → ∀ s, ¬ (sys.act i).Enabled s) {s}
    (h : sys.Reach P s) : sys.Reach (fun i => P i ∧ Q i) s := by
  induction h with
  | init hi => exact .init hi
  | @step s t i _ hp hst ih =>
    by_cases hq : Q i
    · exact .step i ih ⟨hp, hq⟩ hst
    · exact absurd ⟨t, hst⟩ (hQ i hp hq s)

end System

/-- A world that holds the invariant and takes its whole cone licenses it
for every action of `P`. -/
theorem world_licenses (sys : System ι Var Val) {P Q : ι → Prop}
    {I : State Var Val → Prop} {D : Var → Prop} (hI : DependsOn I D)
    (hcone : ∀ i, sys.InCone P D i → Q i) (h : sys.Holds Q I) : sys.Holds P I :=
  (cone sys P hI).2 (h.mono hcone)

end Footprint
