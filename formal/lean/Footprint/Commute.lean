import Footprint.Semantics

/-!
# Actions with disjoint footprints commute

If neither writes what the other reads or writes, `a` then `b` and `b` then
`a` are the same relation, and neither enables or disables the other: their
interleavings need no checking together.
-/

namespace Footprint

variable {Var Val : Type}

namespace Action

/-- A step of `a` leaves `b` exactly as enabled as it was. -/
theorem enabled_preserved (a b : Action Var Val) (hWR : Disjoint a.W b.R)
    {s t : State Var Val} (hs : a.step s t) : b.Enabled s ↔ b.Enabled t := by
  have hag : Agree b.R t s := a.agree_off hWR hs
  constructor
  · rintro ⟨u, hu⟩
    obtain ⟨u', hu', _⟩ := b.locality hag.symm hu
    exact ⟨u', hu'⟩
  · rintro ⟨u, hu⟩
    obtain ⟨u', hu', _⟩ := b.locality hag hu
    exact ⟨u', hu'⟩

theorem seq_swap (a b : Action Var Val) (hWR : Disjoint a.W b.R)
    (hWW : Disjoint a.W b.W) (hRW : Disjoint b.W a.R) {s u : State Var Val}
    (h : a.seq b s u) : b.seq a s u := by
  obtain ⟨t, hat, hbu⟩ := h
  -- b from s, as it went from t: s agrees with t on what b reads.
  obtain ⟨t', hbt', hwb⟩ := b.locality (a.agree_off hWR hat) hbu
  -- a from t', as it went from s: t' agrees with s on what a reads.
  obtain ⟨u', hau', hwa⟩ := a.locality (b.agree_off hRW hbt').symm hat
  refine ⟨t', hbt', ?_⟩
  have : u' = u := by
    funext v
    by_cases ha : a.W v
    · have hb : ¬ b.W v := fun hb => hWW v ha hb
      have hu : u v = t v := b.frame hbu v hb
      rcases hwa v ha with h | ⟨h₁, h₂⟩
      · rw [hu, h]
      · rw [hu, h₂, b.frame hbt' v hb, h₁]
    · have hu' : u' v = t' v := a.frame hau' v ha
      by_cases hb : b.W v
      · rcases hwb v hb with h | ⟨h₁, h₂⟩
        · rw [hu', h]
        · rw [hu', h₂, h₁, a.frame hat v ha]
      · rw [hu', b.frame hbt' v hb, b.frame hbu v hb, a.frame hat v ha]
  exact this ▸ hau'

end Action

/-- `commute`: if `a` writes nothing `b` reads or writes and `b` nothing `a`
reads, then `a ; b` and `b ; a` are one relation, and each action preserves
the other's enabledness. -/
theorem commute (a b : Action Var Val) (hWR : Disjoint a.W b.R)
    (hWW : Disjoint a.W b.W) (hRW : Disjoint b.W a.R) :
    a.seq b = b.seq a ∧
      (∀ s t, a.step s t → (b.Enabled s ↔ b.Enabled t)) ∧
      (∀ s t, b.step s t → (a.Enabled s ↔ a.Enabled t)) := by
  refine ⟨?_, fun _ _ => a.enabled_preserved b hWR, fun _ _ => b.enabled_preserved a hRW⟩
  funext s u
  exact propext ⟨a.seq_swap b hWR hWW hRW, b.seq_swap a hRW hWW.symm hWR⟩

end Footprint
