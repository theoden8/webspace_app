import Footprint.Frame

/-!
# Checking every pair that shares a variable is not enough

`A` sets `x`, `B` sets `y` once `x` is set, `C` sets `z` once `y` is set, and
the invariant says `z` stays unset. `A` and `B` share `x`, `B` and `C` share
`y`, `A` and `C` share nothing; every world of two of them holds the
invariant, and the three together break it. A footprint gate over pairs is
coverage, not soundness; `cone` says which world is enough.
-/

namespace Footprint.Pairwise

inductive V | x | y | z
  deriving DecidableEq

inductive Act | A | B | C
  deriving DecidableEq

/-- `s` with `v` set. -/
def set (s : State V Bool) (v : V) : State V Bool :=
  fun w => if w = v then true else s w

theorem set_other {s : State V Bool} {v w : V} (h : w ≠ v) : set s v w = s w := by
  simp [set, h]

/-- Set `w` once `g` is set (`g := none`: at once), reading `g`, writing `w`. -/
def setter (g : Option V) (w : V) : Action V Bool where
  R := fun v => g = some v
  W := fun v => v = w
  step := fun s t => (∀ u, g = some u → s u = true) ∧ t = set s w
  frame := by
    rintro s t ⟨_, rfl⟩ v hv
    exact set_other hv
  locality := by
    rintro s s' t hag ⟨hg, rfl⟩
    refine ⟨set s' w, ⟨fun u hu => (hag u hu) ▸ hg u hu, rfl⟩, fun v hv => ?_⟩
    subst hv
    simp [set]

def sys : System Act V Bool where
  init := fun s => ∀ v, s v = false
  act
    | .A => setter none .x
    | .B => setter (some .x) .y
    | .C => setter (some .y) .z

def Inv (s : State V Bool) : Prop := s .z = false

/-- `A` and `B` share `x`; `B` and `C` share `y`. -/
def Shares (a b : Action V Bool) : Prop :=
  ∃ v, (a.W v ∧ (b.R v ∨ b.W v)) ∨ (b.W v ∧ a.R v)

theorem dependsOn : DependsOn Inv (· = V.z) := by
  intro s t h hs
  show t .z = false
  rw [← h .z rfl]
  exact hs

/-- Without `C`, nothing writes `z`. Without `B`, `y` stays unset, so `C`
never runs. Without `A`, neither does `B`. -/
theorem holds_without (k : Act) : sys.Holds (· ≠ k) Inv := by
  cases k with
  | C =>
    refine holds_of_unwritten dependsOn ?_ (fun s h => h .z)
    intro i hi v hw hz
    subst hz
    cases i <;> first | exact hi rfl | cases hw
  | B =>
    let J : State V Bool → Prop := fun s => s .y = false ∧ s .z = false
    suffices ∀ s, sys.Reach (· ≠ .B) s → J s from fun s hs => (this s hs).2
    intro s hs
    induction hs with
    | init h => exact ⟨h .y, h .z⟩
    | step i _ hi hst ih =>
      cases i with
      | A => obtain ⟨_, rfl⟩ := hst; exact ⟨ih.1, ih.2⟩
      | B => exact absurd rfl hi
      | C => obtain ⟨hg, _⟩ := hst; exact absurd (hg .y rfl) (by simp [ih.1])
  | A =>
    let J : State V Bool → Prop := fun s => s .x = false ∧ s .y = false ∧ s .z = false
    suffices ∀ s, sys.Reach (· ≠ .A) s → J s from fun s hs => (this s hs).2.2
    intro s hs
    induction hs with
    | init h => exact ⟨h .x, h .y, h .z⟩
    | step i _ hi hst ih =>
      cases i with
      | A => exact absurd rfl hi
      | B => obtain ⟨hg, _⟩ := hst; exact absurd (hg .x rfl) (by simp [ih.1])
      | C => obtain ⟨hg, _⟩ := hst; exact absurd (hg .y rfl) (by simp [ih.2.1])

/-- Every world of two actions holds the invariant: two of three leave one
out. -/
theorem holds_pair (i j : Act) : sys.Holds (fun k => k = i ∨ k = j) Inv := by
  have : ∃ k, k ≠ i ∧ k ≠ j := by
    cases i <;> cases j <;> first
      | exact ⟨.A, by decide, by decide⟩
      | exact ⟨.B, by decide, by decide⟩
      | exact ⟨.C, by decide, by decide⟩
  obtain ⟨k, hki, hkj⟩ := this
  refine (holds_without k).mono ?_
  rintro l (rfl | rfl) rfl
  · exact hki rfl
  · exact hkj rfl

theorem breaks : ¬ sys.Holds (fun _ => True) Inv := by
  intro h
  let s₀ : State V Bool := fun _ => false
  have r₀ : sys.Reach (fun _ => True) s₀ := .init (fun _ => rfl)
  have r₁ : sys.Reach (fun _ => True) (set s₀ .x) :=
    .step Act.A r₀ trivial (show (setter none .x).step _ _ from ⟨by simp, rfl⟩)
  have r₂ : sys.Reach (fun _ => True) (set (set s₀ .x) .y) :=
    .step Act.B r₁ trivial (show (setter (some .x) .y).step _ _ from ⟨by simp [set], rfl⟩)
  have r₃ : sys.Reach (fun _ => True) (set (set (set s₀ .x) .y) .z) :=
    .step Act.C r₂ trivial (show (setter (some .y) .z).step _ _ from ⟨by simp [set], rfl⟩)
  exact absurd (h _ r₃) (by simp [Inv, set])

end Footprint.Pairwise

open Footprint.Pairwise in
/-- `pairwise_unsound`: an invariant can hold in every world made of a pair
of actions that share a variable (in fact of any two) and fail in the whole
system. -/
theorem Footprint.pairwise_unsound :
    ∃ (sys : System Act V Bool) (I : State V Bool → Prop) (D : V → Prop),
      DependsOn I D ∧
      (∀ i j, Shares (sys.act i) (sys.act j) → sys.Holds (fun k => k = i ∨ k = j) I) ∧
      ¬ sys.Holds (fun _ => True) I :=
  ⟨sys, Inv, (· = V.z), dependsOn, fun i j _ => holds_pair i j, breaks⟩
