/-!
# A printed action, over any state

What the printer says of an action of `formal/activation.tla`: the variables
it reads (named unprimed) and writes (primed), every other one `UNCHANGED`.
Here an action is that footprint and a step relation it is well formed over,
so a theorem about it holds of every action the printer can print.
-/

namespace Footprint

/-- A value for every variable. -/
abbrev State (Var Val : Type) := Var → Val

variable {Var Val ι : Type}

/-- `s` and `t` agree on every variable of `S`. -/
def Agree (S : Var → Prop) (s t : State Var Val) : Prop :=
  ∀ v, S v → s v = t v

theorem Agree.symm {S : Var → Prop} {s t : State Var Val} (h : Agree S s t) :
    Agree S t s :=
  fun v hv => (h v hv).symm

theorem Agree.trans {S : Var → Prop} {s t u : State Var Val}
    (h₁ : Agree S s t) (h₂ : Agree S t u) : Agree S s u :=
  fun v hv => (h₁ v hv).trans (h₂ v hv)

theorem Agree.mono {S T : Var → Prop} {s t : State Var Val}
    (hST : ∀ v, S v → T v) (h : Agree T s t) : Agree S s t :=
  fun v hv => h v (hST v hv)

/-- No variable is in both. -/
def Disjoint (S T : Var → Prop) : Prop :=
  ∀ v, S v → T v → False

theorem Disjoint.symm {S T : Var → Prop} (h : Disjoint S T) : Disjoint T S :=
  fun v hT hS => h v hS hT

/-- An action with its read set `R` and write set `W`, well formed over them.

`frame`: a step changes nothing off `W`, which is what the printed
`UNCHANGED` says. `locality`: from a state that agrees on `R` there is a
corresponding step, and on each variable of `W` the two steps write the same
value or both leave it as it was. So whether the action is enabled, and what
it writes, depend only on the state restricted to `R`; an action that leaves
a variable of `W` unchanged on one branch (`IF g THEN x' = 1 ELSE UNCHANGED x`)
need not read it, and a footprint may over-approximate either set
(`Action.widen`). -/
structure Action (Var Val : Type) where
  R : Var → Prop
  W : Var → Prop
  step : State Var Val → State Var Val → Prop
  frame : ∀ {s t}, step s t → ∀ v, ¬ W v → t v = s v
  locality : ∀ {s s' t}, Agree R s s' → step s t →
    ∃ t', step s' t' ∧ ∀ v, W v → t v = t' v ∨ (t v = s v ∧ t' v = s' v)

namespace Action

/-- `a` can step from `s`. -/
def Enabled (a : Action Var Val) (s : State Var Val) : Prop :=
  ∃ t, a.step s t

/-- `a` then `b`. -/
def seq (a b : Action Var Val) (s u : State Var Val) : Prop :=
  ∃ t, a.step s t ∧ b.step t u

/-- A step agrees with its source off `W`. -/
theorem agree_off {a : Action Var Val} {S : Var → Prop} {s t : State Var Val}
    (h : Disjoint a.W S) (hs : a.step s t) : Agree S t s :=
  fun v hv => a.frame hs v (fun hw => h v hw hv)

/-- The same steps over a larger read and write set: a footprint that
over-approximates the action's is one it is well formed over. -/
def widen (a : Action Var Val) (R W : Var → Prop)
    (hR : ∀ v, a.R v → R v) (hW : ∀ v, a.W v → W v) : Action Var Val where
  R := R
  W := W
  step := a.step
  frame := fun hs v hv => a.frame hs v (fun h => hv (hW v h))
  locality := by
    intro s s' t hag hs
    obtain ⟨t', hs', hw⟩ := a.locality (hag.mono hR) hs
    refine ⟨t', hs', fun v _ => ?_⟩
    by_cases h : a.W v
    · exact hw v h
    · exact Or.inr ⟨a.frame hs v h, a.frame hs' v h⟩

end Action

/-- An initial condition and the actions indexed by `ι`. A list of actions
is `ι := Fin n`, or the printed `inductive` of their names. -/
structure System (ι Var Val : Type) where
  init : State Var Val → Prop
  act : ι → Action Var Val

namespace System

/-- The states reachable from `init` by the actions `P` holds of: `P` picks
the system's actions, so a world of some of them is the same `System` with
a smaller `P`. -/
inductive Reach (sys : System ι Var Val) (P : ι → Prop) : State Var Val → Prop
  | init {s} : sys.init s → Reach sys P s
  | step {s t} (i : ι) : Reach sys P s → P i → (sys.act i).step s t → Reach sys P t

/-- `I` holds in every state the actions `P` reach. -/
def Holds (sys : System ι Var Val) (P : ι → Prop) (I : State Var Val → Prop) :
    Prop :=
  ∀ s, sys.Reach P s → I s

theorem Reach.mono {sys : System ι Var Val} {P Q : ι → Prop}
    (hPQ : ∀ i, P i → Q i) {s} (h : sys.Reach P s) : sys.Reach Q s := by
  induction h with
  | init hi => exact .init hi
  | step i _ hp hs ih => exact .step i ih (hPQ i hp) hs

/-- A world with fewer actions reaches fewer states, so what holds in the
larger holds in it. -/
theorem Holds.mono {sys : System ι Var Val} {P Q : ι → Prop} {I}
    (hPQ : ∀ i, P i → Q i) (h : sys.Holds Q I) : sys.Holds P I :=
  fun s hs => h s (hs.mono hPQ)

end System

/-- `I` reads only the variables of `D`: states that agree there agree on
`I`. -/
def DependsOn (I : State Var Val → Prop) (D : Var → Prop) : Prop :=
  ∀ s t, Agree D s t → I s → I t

end Footprint
