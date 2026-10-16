import Footprint.Cone

/-!
# The cone over a printed model, decided

What the printer knows of a model, over finite names: every action's
footprint, what each invariant reads, which invariants each world checks,
which actions its constants leave able to run (`present`: the needs the world
gives) and which its `Next` takes (`inWorld`: present, and an input it
allows). `licensedB` computes an invariant's cone among a world's present
actions and holds it to the world; `Footprints.sound` says what a `true`
buys: the world's TLC result holds for every input its constants allow.

The cone is found by iterating to a fixpoint, which nothing here proves
least or even a fixpoint: `closedB` checks that the set found is closed, and
a closed set contains the cone (`System.InCone.sub`), so a wrong iteration
can only make a check fail.
-/

namespace Footprint

/-- A model's names and what the printer knows of them. -/
structure Footprints (A V Inv World : Type) where
  acts : List A
  vars : List V
  reads : A → List V
  writes : A → List V
  invs : List Inv
  invReads : Inv → List V
  worlds : List World
  checks : World → Inv → Bool
  present : World → A → Bool
  inWorld : World → A → Bool

namespace Footprints

variable {A V Inv World : Type} [DecidableEq A] [DecidableEq V]

/-- What `D` and the actions of `C` read. -/
def seen (fp : Footprints A V Inv World) (D : List V) (C : List A) : List V :=
  fp.vars.filter fun v => D.contains v || C.any fun c => (fp.reads c).contains v

/-- The present actions that write what `D` and `C` read. -/
def grow (fp : Footprints A V Inv World) (w : World) (D : List V) (C : List A) :
    List A :=
  let s := fp.seen D C
  fp.acts.filter fun a => fp.present w a && (fp.writes a).any s.contains

/-- `grow` until it stops growing, at most `n` times. -/
def coneOf (fp : Footprints A V Inv World) (w : World) (D : List V) :
    Nat → List A → List A
  | 0, C => C
  | n + 1, C =>
    let C' := fp.grow w D C
    if C'.length = C.length then C else fp.coneOf w D n C'

/-- Every present action that writes what `D` or `C` reads is in `C`. -/
def closedB (fp : Footprints A V Inv World) (w : World) (D : List V) (C : List A) :
    Bool :=
  let s := fp.seen D C
  fp.acts.all fun a => !(fp.present w a && (fp.writes a).any s.contains) || C.contains a

/-- The cone of invariant `i` among the actions present in `w`. -/
def cone (fp : Footprints A V Inv World) (w : World) (i : Inv) : List A :=
  fp.coneOf w (fp.invReads i) (fp.acts.length + 1) []

/-- `w` takes the whole cone of `i`, and the set found is closed. -/
def licensedB (fp : Footprints A V Inv World) (w : World) (i : Inv) : Bool :=
  fp.closedB w (fp.invReads i) (fp.cone w i) && (fp.cone w i).all (fp.inWorld w)

/-- Every invariant is checked in some world that takes its whole cone. -/
def everyInvariantLicensed (fp : Footprints A V Inv World) : Bool :=
  fp.invs.all fun i => fp.worlds.any fun w => fp.checks w i && fp.licensedB w i

omit [DecidableEq A] in
theorem mem_seen {fp : Footprints A V Inv World} (hvars : ∀ v, v ∈ fp.vars)
    {D : List V} {C : List A} {v : V} (h : v ∈ D ∨ ∃ c, c ∈ C ∧ v ∈ fp.reads c) :
    v ∈ fp.seen D C := by
  refine List.mem_filter.2 ⟨hvars v, ?_⟩
  simp only [Bool.or_eq_true, List.contains_iff_mem, List.any_eq_true]
  exact h

theorem closedB_sound {fp : Footprints A V Inv World} (hvars : ∀ v, v ∈ fp.vars)
    {w : World} {D : List V} {C : List A} (h : fp.closedB w D C = true) {a : A}
    (ha : a ∈ fp.acts) (hp : fp.present w a = true) {v : V} (hw : v ∈ fp.writes a)
    (hv : v ∈ D ∨ ∃ c, c ∈ C ∧ v ∈ fp.reads c) : a ∈ C := by
  have := List.all_eq_true.1 h a ha
  have hany : (fp.writes a).any (fp.seen D C).contains = true :=
    List.any_eq_true.2 ⟨v, hw, List.contains_iff_mem.2 (mem_seen hvars hv)⟩
  simp only [hp, hany, Bool.and_self, Bool.not_true, Bool.false_or] at this
  exact List.contains_iff_mem.1 this

/-- The system with each action's footprint widened to the printed one. -/
def widened {Val : Type} (fp : Footprints A V Inv World) (sys : System A V Val)
    (hR : ∀ a v, (sys.act a).R v → v ∈ fp.reads a)
    (hW : ∀ a v, (sys.act a).W v → v ∈ fp.writes a) : System A V Val where
  init := sys.init
  act a := (sys.act a).widen (· ∈ fp.reads a) (· ∈ fp.writes a) (hR a) (hW a)

omit [DecidableEq A] [DecidableEq V] in
theorem widened_reach {Val : Type} {fp : Footprints A V Inv World}
    {sys : System A V Val} {hR hW} {P : A → Prop} {s} :
    (fp.widened sys hR hW).Reach P s ↔ sys.Reach P s := by
  constructor
  · intro h
    induction h with
    | init hi => exact .init hi
    | step i _ hp hs ih => exact .step i ih hp hs
  · intro h
    induction h with
    | init hi => exact .init hi
    | step i _ hp hs ih => exact .step i ih hp hs

/-- What `licensedB w i = true` buys: for any semantics whose actions the
printed footprints over-approximate, whose actions `w`'s constants leave
absent never run, and whose invariant reads only what is printed for it, the
invariant holding in `w` (TLC's result) holds for every action. -/
theorem sound {Val : Type} (fp : Footprints A V Inv World)
    (hacts : ∀ a, a ∈ fp.acts) (hvars : ∀ v, v ∈ fp.vars)
    {w : World} {i : Inv} (hlic : fp.licensedB w i = true)
    (sys : System A V Val)
    (hR : ∀ a v, (sys.act a).R v → v ∈ fp.reads a)
    (hW : ∀ a v, (sys.act a).W v → v ∈ fp.writes a)
    (hneeds : ∀ a, fp.present w a = false → ∀ s, ¬ (sys.act a).Enabled s)
    {I : State V Val → Prop} (hI : DependsOn I (· ∈ fp.invReads i))
    (htlc : sys.Holds (fun a => fp.inWorld w a = true) I) :
    sys.Holds (fun _ => True) I := by
  simp only [licensedB, Bool.and_eq_true] at hlic
  obtain ⟨hclosed, hin⟩ := hlic
  let sys' := fp.widened sys hR hW
  let P : A → Prop := fun a => fp.present w a = true
  have hcone : ∀ a, sys'.InCone P (· ∈ fp.invReads i) a → fp.inWorld w a = true := by
    intro a ha
    have hC : a ∈ fp.cone w i := by
      refine System.InCone.sub (C := (· ∈ fp.cone w i)) ?_ ha
      intro b hb v hw hv
      exact closedB_sound hvars hclosed (hacts b) hb hw hv
    exact List.all_eq_true.1 hin a hC
  have htlc' : sys'.Holds (fun a => fp.inWorld w a = true) I :=
    fun s hs => htlc s (widened_reach.1 hs)
  have hP : sys'.Holds P I := world_licenses sys' hI hcone htlc'
  intro s hs
  have hs' : sys'.Reach (fun a => True ∧ P a) s := by
    refine System.Reach.drop_disabled (fun a _ hq s hen => ?_) (widened_reach.2 hs)
    exact hneeds a (by simpa [P] using hq) s hen
  exact hP s (hs'.mono fun _ h => h.2)

/-- `everyInvariantLicensed = true`: every invariant is checked in a world
whose result holds for every action its constants allow. -/
theorem every_sound (fp : Footprints A V Inv World) (h : fp.everyInvariantLicensed = true)
    (hacts : ∀ a, a ∈ fp.acts) (hvars : ∀ v, v ∈ fp.vars) :
    ∀ i, i ∈ fp.invs → ∃ w, w ∈ fp.worlds ∧ fp.checks w i = true ∧
      ∀ {Val : Type} (sys : System A V Val)
        (_ : ∀ a v, (sys.act a).R v → v ∈ fp.reads a)
        (_ : ∀ a v, (sys.act a).W v → v ∈ fp.writes a)
        (_ : ∀ a, fp.present w a = false → ∀ s, ¬ (sys.act a).Enabled s)
        (I : State V Val → Prop), DependsOn I (· ∈ fp.invReads i) →
        sys.Holds (fun a => fp.inWorld w a = true) I → sys.Holds (fun _ => True) I := by
  intro i hi
  obtain ⟨w, hw, hwi⟩ := List.any_eq_true.1 (List.all_eq_true.1 h i hi)
  simp only [Bool.and_eq_true] at hwi
  exact ⟨w, hw, hwi.1, fun sys hR hW hn I hI ht =>
    fp.sound hacts hvars hwi.2 sys hR hW hn hI ht⟩

end Footprints

end Footprint
